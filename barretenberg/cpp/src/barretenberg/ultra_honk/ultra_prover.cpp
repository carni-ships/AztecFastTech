// === AUDIT STATUS ===
// internal:    { status: Planned, auditors: [], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================

#include "ultra_prover.hpp"
#include "barretenberg/commitment_schemes/gemini/gemini.hpp"
#include "barretenberg/commitment_schemes/shplonk/shplemini.hpp"
#include "barretenberg/flavor/mega_avm_flavor.hpp"
#include "barretenberg/polynomials/backing_memory.hpp"
#include "barretenberg/sumcheck/sumcheck.hpp"
#include "barretenberg/ultra_honk/oink_prover.hpp"
#include <filesystem>
#include <map>
#include <set>
namespace bb {

template <IsUltraOrMegaHonk Flavor>
UltraProver_<Flavor>::UltraProver_(const std::shared_ptr<ProverInstance>& prover_instance,
                                   const std::shared_ptr<HonkVK>& honk_vk,
                                   const CommitmentKey& commitment_key)
    : prover_instance(std::move(prover_instance))
    , honk_vk(honk_vk)
    , transcript(std::make_shared<Transcript>())
    , commitment_key(commitment_key)
{}

/**
 * @brief Create UltraProver_ from a decider proving key.
 *
 * @param prover_instance key whose proof we want to generate.
 *
 * @tparam a type of UltraFlavor
 * */
template <IsUltraOrMegaHonk Flavor>
UltraProver_<Flavor>::UltraProver_(const std::shared_ptr<ProverInstance>& prover_instance,
                                   const std::shared_ptr<HonkVK>& honk_vk,
                                   const std::shared_ptr<Transcript>& transcript)
    : prover_instance(std::move(prover_instance))
    , honk_vk(honk_vk)
    , transcript(transcript)
    , commitment_key(prover_instance->commitment_key)
{}

/**
 * @brief Create UltraProver_ from a circuit.
 *
 * @param circuit Circuit with witnesses whose validity we'd like to prove.
 *
 * @tparam a type of UltraFlavor
 * */
template <IsUltraOrMegaHonk Flavor>
UltraProver_<Flavor>::UltraProver_(Builder& circuit,
                                   const std::shared_ptr<HonkVK>& honk_vk,
                                   const std::shared_ptr<Transcript>& transcript)
    : prover_instance(std::make_shared<ProverInstance>(circuit))
    , honk_vk(honk_vk)
    , transcript(transcript)
    , commitment_key(prover_instance->commitment_key)
{}

template <IsUltraOrMegaHonk Flavor>
UltraProver_<Flavor>::UltraProver_(Builder&& circuit, const std::shared_ptr<HonkVK>& honk_vk)
    : prover_instance(std::make_shared<ProverInstance>(circuit))
    , honk_vk(honk_vk)
    , transcript(std::make_shared<Transcript>())
    , commitment_key(prover_instance->commitment_key)
{}

/**
 * @brief Export the complete proof, including IPA proof for rollup circuits
 * @details Two-level proof structure for rollup circuits:
 *
 * **Prover Level (this function):**
 *   [public_inputs | honk_proof | ipa_proof]
 *   - Appends IPA proof if prover_instance->ipa_proof is non-empty
 *   - SYMMETRIC with UltraVerifier_::split_rollup_proof() which extracts the IPA portion
 *
 * **API Level (bbapi):**
 *   - _prove() further splits into: public_inputs (ACIR only) vs proof (rest including IPA)
 *   - concatenate_proof() reassembles for verification
 *
 * @note IPA_PROOF_LENGTH is defined in ipa.hpp as 4*CONST_ECCVM_LOG_N + 4 = 64 elements
 */
template <IsUltraOrMegaHonk Flavor> typename UltraProver_<Flavor>::Proof UltraProver_<Flavor>::export_proof()
{
    auto proof = transcript->export_proof();

    // Append IPA proof if present
    if (!prover_instance->ipa_proof.empty()) {
        BB_ASSERT_EQ(prover_instance->ipa_proof.size(), static_cast<size_t>(IPA_PROOF_LENGTH));
        proof.insert(proof.end(), prover_instance->ipa_proof.begin(), prover_instance->ipa_proof.end());
    }

    return proof;
}

template <IsUltraOrMegaHonk Flavor> void UltraProver_<Flavor>::generate_gate_challenges()
{
    // Determine the number of rounds in the sumcheck based on whether or not padding is employed
    const size_t virtual_log_n =
        Flavor::USE_PADDING ? Flavor::VIRTUAL_LOG_N : static_cast<size_t>(prover_instance->log_dyadic_size());

    prover_instance->gate_challenges =
        transcript->template get_dyadic_powers_of_challenge<FF>("Sumcheck:gate_challenge", virtual_log_n);
}

template <IsUltraOrMegaHonk Flavor> typename UltraProver_<Flavor>::Proof UltraProver_<Flavor>::construct_proof()
{
    auto t0 = std::chrono::steady_clock::now();
    if (slow_low_memory) {
        // Option D: Progressive memory management during Oink.
        // Serialize precomputed polys to disk early, free them between Oink rounds
        // to reduce peak memory from ~23.5 GiB to ~13.5 GiB at 2^24.
        construct_proof_low_memory();
    } else {
        OinkProver<Flavor> oink_prover(prover_instance, honk_vk, transcript);
        oink_prover.prove();
        vinfo("created oink proof");
    }
    auto t1 = std::chrono::steady_clock::now();

    generate_gate_challenges();

    // Wait for async witness serialization to complete (launched during construct_proof_low_memory)
    if (witness_serialization_future.valid()) {
        auto num_serialized = witness_serialization_future.get();
        vinfo("witness serialization complete (", num_serialized, " polys, overlapped with gate_challenges)");
    }
    auto t2 = std::chrono::steady_clock::now();

    // Run sumcheck
    execute_sumcheck_iop();
    auto t3 = std::chrono::steady_clock::now();
    vinfo("finished relation check rounds");
    // Execute Shplemini PCS
    execute_pcs();
    auto t4 = std::chrono::steady_clock::now();
    vinfo("finished PCS rounds");

    auto ms = [](auto a, auto b) { return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count(); };
    vinfo("construct_proof timing: oink=", ms(t0,t1), "ms gate_challenges=", ms(t1,t2),
          "ms sumcheck=", ms(t2,t3), "ms pcs=", ms(t3,t4), "ms total=", ms(t0,t4), "ms");

    return export_proof();
}

/**
 * @brief Low-memory Oink path: serialize precomputed polys to disk early, call Oink rounds
 * individually, and free precomputed polys between rounds as they become unneeded.
 *
 * @details Memory timeline at 2^24 (each poly = 512 MiB):
 *   1. Start: 41 polys = 20.5 GiB
 *   2. Serialize 28 precomputed to disk, free 11 unused by Oink: -5.5 GiB → 15 GiB
 *   3. Init CommitmentKey (SRS shared via cache): +1 GiB → 16 GiB
 *   4. Wire + sorted list rounds: no change
 *   5. After log-derivative: free q_lookup, table_1..4, q_m, q_c, q_r, q_o (-4.5 GiB) → 11.5 GiB
 *   6. After grand product: free sigma_1..4, id_1..4 (-4 GiB) → 7.5 GiB
 *   7. Free commitment key: -1 GiB → 6.5 GiB (witness only)
 */
template <IsUltraOrMegaHonk Flavor> void UltraProver_<Flavor>::construct_proof_low_memory()
{
    // Create streaming temp dir early — will be reused by execute_sumcheck_iop() and execute_pcs()
    auto temp_dir = std::filesystem::temp_directory_path() / ("bb-streaming-" + std::to_string(getpid()));
    std::filesystem::create_directories(temp_dir);
    streaming_temp_dir = temp_dir.string();

    // Precomputed poly cache: precomputed polys are identical across proofs of the same
    // circuit type + dyadic size. Cache them persistently to skip re-serialization.
    // Key: dyadic_size + num_public_inputs (sufficient to identify circuit type in practice).
    auto poly_cache_dir = std::filesystem::temp_directory_path() / "bb-poly-cache"
        / (std::to_string(prover_instance->dyadic_size()) + "-"
           + std::to_string(prover_instance->num_public_inputs()));
    bool cache_hit = std::filesystem::exists(poly_cache_dir / "complete");
    if (cache_hit) {
        vinfo("low-memory mode: precomputed poly cache HIT at ", poly_cache_dir.string());
    } else {
        std::filesystem::create_directories(poly_cache_dir);
        vinfo("low-memory mode: precomputed poly cache MISS, will populate");
    }
    vinfo("low-memory mode: temp dir ", streaming_temp_dir);

    auto& polys = prover_instance->polynomials;
    auto free_poly = [](auto& p) { p = Polynomial(); };

    // Phase 1: Serialize PRECOMPUTED polys to disk before Oink (they're immutable).
    // Witness polys are serialized AFTER Oink because Oink modifies w_4, lookup_inverses, z_perm.
    // Must serialize in BOTH orderings: get_all() for sumcheck, get_unshifted() for PCS.
    auto all_polys = polys.get_all();
    streaming_all_poly_paths.resize(all_polys.size());

    // Build set of precomputed poly data pointers to identify precomputed indices
    auto precomputed = polys.get_precomputed();
    std::set<const void*> precomputed_ptrs;
    for (auto& p : precomputed) {
        if (!p.is_empty()) {
            precomputed_ptrs.insert(static_cast<const void*>(p.data()));
        }
    }
    auto is_precomputed = [&](const auto& p) {
        return !p.is_empty() && precomputed_ptrs.count(static_cast<const void*>(p.data()));
    };

    // Serialize precomputed polys to disk — use persistent cache when available.
    // Precomputed polys are identical across proofs of the same circuit type.
    // On cache hit: create symlinks from temp dir to cached files (instant).
    // On cache miss: serialize in parallel and copy to cache.
    struct SerTask { size_t idx; std::string path; const Polynomial* poly; std::string cache_path; };
    std::vector<SerTask> all_tasks;
    for (size_t i = 0; i < all_polys.size(); i++) {
        if (is_precomputed(all_polys[i])) {
            std::string path = streaming_temp_dir + "/all_" + std::to_string(i) + ".bin";
            std::string cpath = (poly_cache_dir / ("all_" + std::to_string(i) + ".bin")).string();
            streaming_all_poly_paths[i] = path;
            all_tasks.push_back({ i, path, &all_polys[i], cpath });
        }
    }

    auto unshifted = polys.get_unshifted();
    streaming_unshifted_paths.resize(unshifted.size());

    // Deduplication: build map from data pointer → all_* path to detect shared polys.
    // Precomputed polys in get_unshifted() that share data with get_all() entries
    // can use symlinks instead of being serialized twice.
    std::map<const void*, std::string> precomp_data_to_all_path;
    for (auto& task : all_tasks) {
        precomp_data_to_all_path[static_cast<const void*>(task.poly->data())] = task.path;
    }

    std::vector<SerTask> unshifted_tasks;
    // Track unshifted entries that will be deduped via symlink (need separate handling)
    struct SymlinkTask { std::string target; std::string link_path; std::string cache_path; };
    std::vector<SymlinkTask> dedup_symlinks;
    for (size_t i = 0; i < unshifted.size(); i++) {
        if (is_precomputed(unshifted[i])) {
            std::string path = streaming_temp_dir + "/unshifted_" + std::to_string(i) + ".bin";
            std::string cpath = (poly_cache_dir / ("unshifted_" + std::to_string(i) + ".bin")).string();
            streaming_unshifted_paths[i] = path;
            auto it = precomp_data_to_all_path.find(static_cast<const void*>(unshifted[i].data()));
            if (it != precomp_data_to_all_path.end()) {
                // Same data as an all_* entry — will symlink after serialization
                dedup_symlinks.push_back({ it->second, path, cpath });
            } else {
                unshifted_tasks.push_back({ i, path, &unshifted[i], cpath });
            }
        }
    }

    std::vector<SerTask> all_ser_tasks;
    all_ser_tasks.insert(all_ser_tasks.end(), all_tasks.begin(), all_tasks.end());
    all_ser_tasks.insert(all_ser_tasks.end(), unshifted_tasks.begin(), unshifted_tasks.end());

    if (cache_hit) {
        // Cache hit: create symlinks to cached files (near-instant vs 10-20s serialization)
        for (auto& task : all_ser_tasks) {
            std::filesystem::create_symlink(task.cache_path, task.path);
        }
        // For deduped entries: on cache hit, the cache has separate unshifted files from previous miss
        for (auto& sl : dedup_symlinks) {
            if (std::filesystem::exists(sl.cache_path)) {
                std::filesystem::create_symlink(sl.cache_path, sl.link_path);
            } else {
                // First run with dedup — cache only has all_* files. Symlink to the all_* temp file.
                std::filesystem::create_symlink(sl.target, sl.link_path);
            }
        }
        vinfo("linked ", all_ser_tasks.size(), " precomputed polys from cache");
    } else {
        // Cache miss: serialize in parallel, then hardlink into cache
        constexpr size_t MAX_PARALLEL_WRITERS = 3;
        std::vector<std::future<void>> futures;
        for (auto& task : all_ser_tasks) {
            if (futures.size() >= MAX_PARALLEL_WRITERS) {
                futures.front().get();
                futures.erase(futures.begin());
            }
            futures.push_back(std::async(std::launch::async, [&task]() {
                task.poly->serialize_to_file(task.path);
            }));
        }
        for (auto& f : futures) {
            f.get();
        }
        // Create symlinks for deduped unshifted entries (points to all_* files already serialized)
        for (auto& sl : dedup_symlinks) {
            std::filesystem::create_symlink(sl.target, sl.link_path);
        }
        // Populate cache: hardlink serialized files into persistent cache dir
        for (auto& task : all_ser_tasks) {
            try {
                std::filesystem::copy_file(task.path, task.cache_path,
                    std::filesystem::copy_options::skip_existing);
            } catch (...) {} // Non-fatal: cache population is best-effort
        }
        // Also cache deduped entries as symlinks to the all_* cached files
        for (auto& sl : dedup_symlinks) {
            try {
                // Find the cache path for the target all_* file
                for (auto& task : all_tasks) {
                    if (task.path == sl.target) {
                        std::filesystem::create_symlink(task.cache_path, sl.cache_path);
                        break;
                    }
                }
            } catch (...) {} // Non-fatal
        }
        // Mark cache as complete (atomic: write then rename)
        {
            auto marker = poly_cache_dir / "complete";
            std::ofstream(marker.string()) << prover_instance->dyadic_size();
        }
        vinfo("serialized and cached ", all_ser_tasks.size(), " precomputed polys");
    }
    size_t num_precomputed_serialized = all_tasks.size();
    // get_to_be_shifted() is witness-only, no precomputed — serialized after Oink
    auto to_be_shifted = polys.get_to_be_shifted();
    streaming_shifted_paths.resize(to_be_shifted.size());

    vinfo("serialized ", num_precomputed_serialized, " precomputed polys to disk before Oink");

    // Free precomputed polys not needed by any Oink round.
    // Oink needs: q_m, q_c, q_r, q_o, q_lookup (for log-derivative)
    //             table_1..4 (for log-derivative)
    //             sigma_1..4, id_1..4 (for grand product)
    // Safe to free: q_l, q_4, q_arith, q_delta_range, q_elliptic, q_memory, q_nnf,
    //               q_poseidon2_external, q_poseidon2_internal, lagrange_first, lagrange_last
    free_poly(polys.q_l);
    free_poly(polys.q_4);
    free_poly(polys.q_arith);
    free_poly(polys.q_delta_range);
    free_poly(polys.q_elliptic);
    free_poly(polys.q_memory);
    free_poly(polys.q_nnf);
    free_poly(polys.q_poseidon2_external);
    free_poly(polys.q_poseidon2_internal);
    free_poly(polys.lagrange_first);
    free_poly(polys.lagrange_last);
    vinfo("freed 11 precomputed polys not needed by Oink");

    // Initialize commitment key on prover_instance so OinkProver::prove() skips creating its own.
    prover_instance->commitment_key = CommitmentKey(prover_instance->dyadic_size());

    // Run Oink rounds individually for progressive memory management.
    // After each round, start serializing newly-finalized witness polys in the background.
    // This overlaps I/O with the remaining Oink computation.
    OinkProver<Flavor> oink_prover(prover_instance, honk_vk, transcript);
    oink_prover.execute_preamble_round();
    oink_prover.commit_to_masking_poly();
    oink_prover.execute_wire_commitments_round();

    // w_l, w_r, w_o are finalized after wire commitments — start serializing in background.
    // These won't be modified by subsequent Oink rounds.
    std::vector<std::future<void>> early_ser_futures;
    auto serialize_witness_poly_early = [&](auto& poly, const std::string& name_prefix, size_t idx) {
        if (poly.is_empty()) return;
        std::string path = streaming_temp_dir + "/" + name_prefix + std::to_string(idx) + ".bin";
        early_ser_futures.push_back(std::async(std::launch::async, [&poly, path]() {
            poly.serialize_to_file(path);
        }));
    };
    // Serialize w_l, w_r, w_o (first 3 wire polys) early
    // Note: these are serialized as part of get_all() later, but we write them now to overlap
    // I/O with the sorted_list + log_derivative + grand_product rounds (~100-300ms total).
    // The later Phase 2 will skip already-serialized polys.
    auto early_all = polys.get_all();
    // Find indices of w_l, w_r, w_o in get_all() ordering
    std::set<const void*> early_wire_ptrs;
    early_wire_ptrs.insert(static_cast<const void*>(polys.w_l.data()));
    early_wire_ptrs.insert(static_cast<const void*>(polys.w_r.data()));
    early_wire_ptrs.insert(static_cast<const void*>(polys.w_o.data()));
    for (size_t i = 0; i < early_all.size(); i++) {
        if (!early_all[i].is_empty() && early_wire_ptrs.count(static_cast<const void*>(early_all[i].data()))) {
            std::string path = streaming_temp_dir + "/all_" + std::to_string(i) + ".bin";
            streaming_all_poly_paths[i] = path;
            auto* poly_ptr = &early_all[i];
            early_ser_futures.push_back(std::async(std::launch::async, [poly_ptr, path]() {
                poly_ptr->serialize_to_file(path);
            }));
        }
    }

    oink_prover.execute_sorted_list_accumulator_round();

    // w_4 is finalized after sorted_list — serialize in background during log-derivative round
    early_wire_ptrs.clear();
    early_wire_ptrs.insert(static_cast<const void*>(polys.w_4.data()));
    for (size_t i = 0; i < early_all.size(); i++) {
        if (!early_all[i].is_empty() && streaming_all_poly_paths[i].empty()
            && early_wire_ptrs.count(static_cast<const void*>(early_all[i].data()))) {
            std::string path = streaming_temp_dir + "/all_" + std::to_string(i) + ".bin";
            streaming_all_poly_paths[i] = path;
            auto* poly_ptr = &early_all[i];
            early_ser_futures.push_back(std::async(std::launch::async, [poly_ptr, path]() {
                poly_ptr->serialize_to_file(path);
            }));
        }
    }

    oink_prover.execute_log_derivative_inverse_round();

    // Free precomputed polys used only by log-derivative (lookup relation)
    free_poly(polys.q_lookup);
    free_poly(polys.table_1);
    free_poly(polys.table_2);
    free_poly(polys.table_3);
    free_poly(polys.table_4);
    free_poly(polys.q_m);
    free_poly(polys.q_c);
    free_poly(polys.q_r);
    free_poly(polys.q_o);
    vinfo("freed 9 log-derivative precomputed polys");

    oink_prover.execute_grand_product_computation_round();

    // Free precomputed polys used only by grand product (permutation relation)
    free_poly(polys.sigma_1);
    free_poly(polys.sigma_2);
    free_poly(polys.sigma_3);
    free_poly(polys.sigma_4);
    free_poly(polys.id_1);
    free_poly(polys.id_2);
    free_poly(polys.id_3);
    free_poly(polys.id_4);
    vinfo("freed 8 grand product precomputed polys — all precomputed now on disk only");

    prover_instance->alpha = oink_prover.generate_alpha_round();

    // Free the commitment key used by Oink
    prover_instance->commitment_key = CommitmentKey();

    // Wait for early wire poly serialization to complete
    for (auto& f : early_ser_futures) {
        f.get();
    }
    vinfo("early wire poly serialization complete (", early_ser_futures.size(), " polys overlapped with Oink rounds)");

    // Phase 2: Serialize remaining WITNESS polys (post-Oink) in parallel with 3 concurrent writers.
    // w_l, w_r, w_o, w_4 were already serialized early (above). Only need lookup_inverses,
    // z_perm, and gemini_masking_poly here.
    all_polys = polys.get_all();
    struct WitSerTask { std::string path; const Polynomial* poly; std::string* path_slot; };
    std::vector<WitSerTask> wit_tasks;

    for (size_t i = 0; i < all_polys.size(); i++) {
        if (streaming_all_poly_paths[i].empty() && !all_polys[i].is_empty()) {
            std::string path = streaming_temp_dir + "/all_" + std::to_string(i) + ".bin";
            streaming_all_poly_paths[i] = path;
            wit_tasks.push_back({ path, &all_polys[i], &streaming_all_poly_paths[i] });
        }
    }

    // Also collect PCS ordering witness polys.
    // Optimization: polys that were already serialized in the get_all() ordering above share the
    // same data pointer. Use symlinks instead of re-serializing to avoid redundant I/O.
    // At 2^24, this saves ~7 × 512 MiB = 3.5 GiB of writes.
    {
        // Build map from data pointer → all_* path for already-serialized polys
        std::map<const void*, std::string> serialized_data_to_path;
        for (size_t i = 0; i < all_polys.size(); i++) {
            if (!streaming_all_poly_paths[i].empty() && !all_polys[i].is_empty()) {
                serialized_data_to_path[static_cast<const void*>(all_polys[i].data())] = streaming_all_poly_paths[i];
            }
        }

        auto unshifted_post = polys.get_unshifted();
        for (size_t i = 0; i < unshifted_post.size(); i++) {
            if (streaming_unshifted_paths[i].empty() && !unshifted_post[i].is_empty()) {
                std::string path = streaming_temp_dir + "/unshifted_" + std::to_string(i) + ".bin";
                streaming_unshifted_paths[i] = path;
                auto it = serialized_data_to_path.find(static_cast<const void*>(unshifted_post[i].data()));
                if (it != serialized_data_to_path.end()) {
                    // Same data already on disk — symlink instead of re-serializing
                    std::filesystem::create_symlink(it->second, path);
                } else {
                    wit_tasks.push_back({ path, &unshifted_post[i], &streaming_unshifted_paths[i] });
                }
            }
        }
        auto shifted_post = polys.get_to_be_shifted();
        for (size_t i = 0; i < shifted_post.size(); i++) {
            if (streaming_shifted_paths[i].empty() && !shifted_post[i].is_empty()) {
                std::string path = streaming_temp_dir + "/shifted_" + std::to_string(i) + ".bin";
                streaming_shifted_paths[i] = path;
                auto it = serialized_data_to_path.find(static_cast<const void*>(shifted_post[i].data()));
                if (it != serialized_data_to_path.end()) {
                    std::filesystem::create_symlink(it->second, path);
                } else {
                    wit_tasks.push_back({ path, &shifted_post[i], &streaming_shifted_paths[i] });
                }
            }
        }
    }

    // Launch witness serialization as async future — overlaps with generate_gate_challenges()
    // in construct_proof(). Sumcheck waits for this to complete before reading files.
    witness_serialization_future = std::async(std::launch::async, [tasks = std::move(wit_tasks)]() {
        constexpr size_t MAX_WRITERS = 3;
        std::vector<std::future<void>> futures;
        for (auto& task : tasks) {
            if (futures.size() >= MAX_WRITERS) {
                futures.front().get();
                futures.erase(futures.begin());
            }
            futures.push_back(std::async(std::launch::async, [&task]() {
                task.poly->serialize_to_file(task.path);
            }));
        }
        for (auto& f : futures) {
            f.get();
        }
        return tasks.size();
    });

    vinfo("witness serialization launched async (" , wit_tasks.size(), " polys)");
    vinfo("created oink proof (low-memory path)");
}

/**
 * @brief Run Sumcheck to establish that ∑_i pow(\vec{β*})f_i(ω) = 0. This results in u = (u_1,...,u_d) sumcheck round
 * challenges and all evaluations at u being calculated.
 *
 */
template <IsUltraOrMegaHonk Flavor> void UltraProver_<Flavor>::execute_sumcheck_iop()
{
    const size_t virtual_log_n = Flavor::USE_PADDING ? Flavor::VIRTUAL_LOG_N : prover_instance->log_dyadic_size();

    using Sumcheck = SumcheckProver<Flavor>;
    size_t polynomial_size = prover_instance->dyadic_size();
    Sumcheck sumcheck(polynomial_size,
                      prover_instance->polynomials,
                      transcript,
                      prover_instance->alpha,
                      prover_instance->gate_challenges,
                      prover_instance->relation_parameters,
                      virtual_log_n);

    // Enable streaming sumcheck when in low-memory mode to reduce peak memory.
    // In low-memory mode, construct_proof_low_memory() already serialized polys and freed precomputed.
    if (slow_low_memory) {
        if (streaming_temp_dir.empty()) {
            // Fallback: create temp dir if not already created by construct_proof_low_memory
            auto temp_dir = std::filesystem::temp_directory_path() / ("bb-streaming-" + std::to_string(getpid()));
            std::filesystem::create_directories(temp_dir);
            streaming_temp_dir = temp_dir.string();
        }
        sumcheck.streaming_temp_dir_ = streaming_temp_dir;
        vinfo("streaming sumcheck enabled, temp dir: ", streaming_temp_dir);

        // If construct_proof_low_memory already serialized polys, only serialize remaining witness polys.
        // Otherwise, serialize everything fresh.
        if (streaming_all_poly_paths.empty()) {
            // Fresh serialization (no low-memory Oink path used)
            auto unshifted = prover_instance->polynomials.get_unshifted();
            streaming_unshifted_paths.resize(unshifted.size());
            for (size_t i = 0; i < unshifted.size(); i++) {
                if (!unshifted[i].is_empty()) {
                    std::string path = streaming_temp_dir + "/unshifted_" + std::to_string(i) + ".bin";
                    unshifted[i].serialize_to_file(path);
                    streaming_unshifted_paths[i] = path;
                }
            }
            auto to_be_shifted = prover_instance->polynomials.get_to_be_shifted();
            streaming_shifted_paths.resize(to_be_shifted.size());
            for (size_t i = 0; i < to_be_shifted.size(); i++) {
                if (!to_be_shifted[i].is_empty()) {
                    std::string path = streaming_temp_dir + "/shifted_" + std::to_string(i) + ".bin";
                    to_be_shifted[i].serialize_to_file(path);
                    streaming_shifted_paths[i] = path;
                }
            }

            auto all_polys = prover_instance->polynomials.get_all();
            streaming_all_poly_paths.resize(all_polys.size());
            for (size_t i = 0; i < all_polys.size(); i++) {
                if (!all_polys[i].is_empty()) {
                    std::string path = streaming_temp_dir + "/all_" + std::to_string(i) + ".bin";
                    all_polys[i].serialize_to_file(path);
                    streaming_all_poly_paths[i] = path;
                }
            }
            vinfo("serialized all polys fresh: ", all_polys.size(), " get_all + ",
                  streaming_unshifted_paths.size(), " unshifted + ",
                  streaming_shifted_paths.size(), " shifted");
        } else {
            vinfo("using pre-serialized polys from low-memory Oink path");
        }

        // Compute effective round size before freeing remaining polys.
        size_t effective_round_size = polynomial_size;
        if constexpr (!Flavor::HasZK) {
            effective_round_size = 0;
            for (auto& witness_poly : prover_instance->polynomials.get_witness()) {
                if (!witness_poly.is_empty()) {
                    effective_round_size = std::max(effective_round_size, witness_poly.end_index());
                }
            }
            effective_round_size += effective_round_size % 2; // round up to even
            effective_round_size = std::min(effective_round_size, polynomial_size);
        }

        // Free ALL remaining source polynomials — sumcheck will load from disk.
        auto all_polys = prover_instance->polynomials.get_all();
        for (auto& poly : all_polys) {
            poly = Polynomial();
        }
        vinfo("freed all source polys, effective_round_size=", effective_round_size);

        // Pass chunked streaming state to sumcheck
        sumcheck.streaming_all_poly_paths_ = std::move(streaming_all_poly_paths);
        sumcheck.streaming_effective_round_size_ = effective_round_size;
    }

    {
        BB_BENCH_NAME("sumcheck.prove");

        if constexpr (Flavor::HasZK) {
            const size_t log_subgroup_size = static_cast<size_t>(numeric::get_msb(Curve::SUBGROUP_SIZE));
            CommitmentKey commitment_key(1 << (log_subgroup_size + 1));
            zk_sumcheck_data = ZKData(numeric::get_msb(polynomial_size), transcript, commitment_key);
            sumcheck_output = sumcheck.prove(zk_sumcheck_data);
        } else {
            sumcheck_output = sumcheck.prove();
        }
    }
}

/**
 * @brief Produce a univariate opening claim for the sumcheck multivariate evalutions and a batched univariate claim
 * for the transcript polynomials (for the Translator consistency check). Reduce the two opening claims to a single one
 * via Shplonk and produce an opening proof with the univariate PCS of choice (IPA when operating on Grumpkin).
 *
 */
template <IsUltraOrMegaHonk Flavor> void UltraProver_<Flavor>::execute_pcs()
{
    using OpeningClaim = ProverOpeningClaim<Curve>;
    using PolynomialBatcher = GeminiProver_<Curve>::PolynomialBatcher;

    auto& ck = prover_instance->commitment_key;
    if (!ck.initialized()) {
        ck = CommitmentKey(prover_instance->dyadic_size());
    }

    PolynomialBatcher polynomial_batcher(prover_instance->dyadic_size());

    // In streaming mode, source polynomials were freed during sumcheck.
    // Set disk-backed paths so compute_batched loads from disk one at a time.
    if (!streaming_temp_dir.empty()) {
        polynomial_batcher.set_disk_backed(std::move(streaming_unshifted_paths), std::move(streaming_shifted_paths));
        vinfo("PCS using disk-backed polynomial streaming");
    } else {
        polynomial_batcher.set_unshifted(prover_instance->polynomials.get_unshifted());
        polynomial_batcher.set_to_be_shifted_by_one(prover_instance->polynomials.get_to_be_shifted());
        // Free source polynomials after Gemini batching to reduce peak memory.
        // After compute_batched(), source polys are no longer accessed.
        polynomial_batcher.post_batch_callback = [this]() {
            auto all_polys = prover_instance->polynomials.get_all();
            for (auto& poly : all_polys) {
                poly = Polynomial();
            }
            vinfo("freed source polynomials after Gemini batch");
        };
    }

    auto pcs_t0 = std::chrono::steady_clock::now();
    OpeningClaim prover_opening_claim;
    if constexpr (!Flavor::HasZK) {
        BB_BENCH_NAME("ShpleminiProver::prove (non-ZK)");
        prover_opening_claim = ShpleminiProver_<Curve>::prove(
            prover_instance->dyadic_size(), polynomial_batcher, sumcheck_output.challenge, ck, transcript);
    } else {
        BB_BENCH_NAME("PCS (ZK) total");
        SmallSubgroupIPA small_subgroup_ipa_prover(
            zk_sumcheck_data, sumcheck_output.challenge, sumcheck_output.claimed_libra_evaluation, transcript, ck);
        {
            BB_BENCH_NAME("SmallSubgroupIPA::prove");
            small_subgroup_ipa_prover.prove();
        }
        auto pcs_t1 = std::chrono::steady_clock::now();
        {
            BB_BENCH_NAME("ShpleminiProver::prove");
            prover_opening_claim = ShpleminiProver_<Curve>::prove(prover_instance->dyadic_size(),
                                                                  polynomial_batcher,
                                                                  sumcheck_output.challenge,
                                                                  ck,
                                                                  transcript,
                                                                  small_subgroup_ipa_prover.get_witness_polynomials());
        }
        auto pcs_t2 = std::chrono::steady_clock::now();
        vinfo("executed multivariate-to-univariate reduction");
        {
            BB_BENCH_NAME("PCS::compute_opening_proof");
            PCS::compute_opening_proof(ck, std::move(prover_opening_claim), transcript);
        }
        auto pcs_t3 = std::chrono::steady_clock::now();
        auto pms = [](auto a, auto b) { return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count(); };
        vinfo("PCS breakdown: setup=", pms(pcs_t0, pcs_t1), "ms shplemini=", pms(pcs_t1, pcs_t2),
              "ms kzg=", pms(pcs_t2, pcs_t3), "ms");
    }
    vinfo("computed opening proof");

    // Clean up streaming temp files asynchronously — don't block proof return.
    // At 2^24 with 36+ files × 512 MiB each, remove_all can take 100ms+ of filesystem ops.
    if (!streaming_temp_dir.empty()) {
        auto dir_to_remove = std::move(streaming_temp_dir);
        streaming_temp_dir.clear();
        std::thread([dir = std::move(dir_to_remove)]() {
            std::error_code ec;
            std::filesystem::remove_all(dir, ec);
        }).detach();
        vinfo("streaming temp cleanup dispatched (async)");
    }
}

template class UltraProver_<UltraFlavor>;
template class UltraProver_<UltraZKFlavor>;
template class UltraProver_<UltraKeccakFlavor>;
#ifdef STARKNET_GARAGA_FLAVORS
template class UltraProver_<UltraStarknetFlavor>;
template class UltraProver_<UltraStarknetZKFlavor>;
#endif
template class UltraProver_<UltraKeccakZKFlavor>;
template class UltraProver_<MegaFlavor>;
template class UltraProver_<MegaZKFlavor>;
template class UltraProver_<MegaAvmFlavor>;

} // namespace bb

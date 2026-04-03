// === AUDIT STATUS ===
// internal:    { status: Complete, auditors: [Khashayar], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================

#pragma once

#include "barretenberg/commitment_schemes/claim.hpp"
#include "barretenberg/commitment_schemes/claim_batcher.hpp"
#include "barretenberg/common/bb_bench.hpp"
#include "barretenberg/common/thread.hpp"
#include "barretenberg/polynomials/polynomial.hpp"
#include "barretenberg/transcript/transcript.hpp"
#include <functional>

/**
 * @brief Protocol for opening several multi-linear polynomials at the same point.
 *
 *
 * m = number of variables
 * n = 2ᵐ
 * u = (u₀,...,uₘ₋₁)
 * f₀, …, fₖ₋₁ = multilinear polynomials,
 * g₀, …, gₕ₋₁ = shifted multilinear polynomial,
 *  Each gⱼ is the left-shift of some f↺ᵢ, and gⱼ points to the same memory location as fᵢ.
 * v₀, …, vₖ₋₁, v↺₀, …, v↺ₕ₋₁ = multilinear evalutions s.t. fⱼ(u) = vⱼ, and gⱼ(u) = f↺ⱼ(u) = v↺ⱼ
 *
 * We use a challenge ρ to create a random linear combination of all fⱼ,
 * and actually define A₀ = F + G↺, where
 *   F  = ∑ⱼ ρʲ fⱼ
 *   G  = ∑ⱼ ρᵏ⁺ʲ gⱼ,
 *   G↺ = is the shift of G
 * where fⱼ is normal, and gⱼ is shifted.
 * The evaluations are also batched, and
 *   v  = ∑ ρʲ⋅vⱼ + ∑ ρᵏ⁺ʲ⋅v↺ⱼ = F(u) + G↺(u)
 *
 * The prover then creates the folded polynomials A₀, ..., Aₘ₋₁,
 * and opens them at different points, as univariates.
 *
 * We open A₀ as univariate at r and -r.
 * Since A₀ = F + G↺, but the verifier only has commitments to the gⱼs,
 * we need to partially evaluate A₀ at both evaluation points.
 * As univariate, we have
 *  A₀(X) = F(X) + G↺(X) = F(X) + G(X)/X
 * So we define
 *  - A₀₊(X) = F(X) + G(X)/r
 *  - A₀₋(X) = F(X) − G(X)/r
 * So that A₀₊(r) = A₀(r) and A₀₋(-r) = A₀(-r).
 * The verifier is able to compute the simulated commitments to A₀₊(X) and A₀₋(X)
 * since they are linear-combinations of the commitments [fⱼ] and [gⱼ].
 */
namespace bb {

/**
 * @brief Prover output (evaluation pair, witness) that can be passed on to Shplonk batch opening.
 * @details Evaluation pairs {r, A₀₊(r)}, {-r, A₀₋(-r)}, {r^{2^j}, Aⱼ(r^{2^j)}, {-r^{2^j}, Aⱼ(-r^{2^j)}, j = [1,
 * ..., m-1] and witness (Fold) polynomials
 * [
 *   A₀₊(X) = F(X) + r⁻¹⋅G(X)
 *   A₀₋(X) = F(X) - r⁻¹⋅G(X)
 *   A₁(X) = (1-u₀)⋅even(A₀)(X) + u₀⋅odd(A₀)(X)
 *   ...
 *   Aₘ₋₁(X) = (1-uₘ₋₂)⋅even(Aₘ₋₂)(X) + uₘ₋₂⋅odd(Aₘ₋₂)(X)
 * ]
 * @tparam Curve CommitmentScheme parameters
 */

namespace gemini {
/**
 * @brief Compute powers of challenge ρ
 *
 * @tparam Fr
 * @param rho
 * @param num_powers
 * @return std::vector<Fr>
 */
template <class Fr> inline std::vector<Fr> powers_of_rho(const Fr& rho, const size_t num_powers)
{
    std::vector<Fr> rhos = { Fr(1), rho };
    rhos.reserve(num_powers);
    for (size_t j = 2; j < num_powers; j++) {
        rhos.emplace_back(rhos[j - 1] * rho);
    }
    return rhos;
};

/**
 * @brief Compute squares of folding challenge r
 *
 * @param r
 * @param num_squares The number of foldings
 * @return std::vector<typename Curve::ScalarField>
 */
template <class Fr> inline std::vector<Fr> powers_of_evaluation_challenge(const Fr& r, const size_t num_squares)
{
    std::vector<Fr> squares = { r };
    squares.reserve(num_squares);
    for (size_t j = 1; j < num_squares; j++) {
        squares.emplace_back(squares[j - 1].sqr());
    }
    return squares;
};
} // namespace gemini

template <typename Curve> class GeminiProver_ {
    using Fr = typename Curve::ScalarField;
    using Commitment = typename Curve::AffineElement;
    using Polynomial = bb::Polynomial<Fr>;
    using Claim = ProverOpeningClaim<Curve>;

  public:
    /**
     * @brief Class responsible for computation of the batched multilinear polynomials required by the Gemini
     * protocol
     * @details Opening multivariate polynomials using Gemini requires the computation of batched polynomials.
     * The first, here denoted A₀, is a linear combination of all polynomials to be opened. If we denote the linear
     * combinations (based on challenge rho) of the unshifted and to-be-shifted-by-1 polynomials by F and G
     * respectively, then A₀ = F + G/X. This polynomial is "folded" in Gemini to produce d-1 univariate polynomials
     * Fold_i, i = 1, ..., d-1. The second and third are the partially evaluated batched polynomials
     * A₀₊ = F + G/r, and A₀₋ = F - G/r. These are required in order to prove the opening of shifted polynomials
     * G_i/X from the commitments to their unshifted counterparts G_i.
     * @note TODO(https://github.com/AztecProtocol/barretenberg/issues/1223): There are certain operations herein
     * that could be made more efficient by e.g. reusing already initialized polynomials, possibly at the expense of
     * clarity.
     */
    class PolynomialBatcher {

        size_t full_batched_size = 0; // size of the full batched polynomial (generally the circuit size)

        Polynomial batched_unshifted;            // linear combination of unshifted polynomials
        Polynomial batched_to_be_shifted_by_one; // linear combination of to-be-shifted polynomials
        Polynomial batched_interleaved;          // linear combination of interleaved polynomials
        // linear combination of the groups to be interleaved where polynomial i in the batched group is obtained by
        // linearly combining the i-th polynomial in each group
        std::vector<Polynomial> batched_group;

      public:
        RefVector<Polynomial> unshifted;                             // set of unshifted polynomials
        RefVector<Polynomial> to_be_shifted_by_one;                  // set of polynomials to be left shifted by 1
        RefVector<Polynomial> interleaved;                           // the interleaved polynomials used in Translator
        std::vector<RefVector<Polynomial>> groups_to_be_interleaved; // groups of polynomials to be interleaved

        PolynomialBatcher(const size_t full_batched_size)
            : full_batched_size(full_batched_size)
            , batched_unshifted(full_batched_size)
            , batched_to_be_shifted_by_one(Polynomial::shiftable(full_batched_size))
        {}

        bool has_unshifted() const { return unshifted.size() > 0 || !disk_unshifted_paths.empty(); }
        bool has_to_be_shifted_by_one() const
        {
            return to_be_shifted_by_one.size() > 0 || !disk_shifted_paths.empty();
        }
        bool has_interleaved() const { return interleaved.size() > 0; }

        // Disk-backed paths for streaming mode (when set, compute_batched loads from disk instead of RefVector)
        std::vector<std::string> disk_unshifted_paths;
        std::vector<std::string> disk_shifted_paths;

        // Optional callback invoked after compute_batched completes, before any other operation.
        // Used to free source polynomials and reduce peak memory.
        std::function<void()> post_batch_callback;

        // Set references to the polynomials to be batched
        void set_unshifted(RefVector<Polynomial> polynomials) { unshifted = polynomials; }
        void set_to_be_shifted_by_one(RefVector<Polynomial> polynomials) { to_be_shifted_by_one = polynomials; }

        // Set disk-backed paths for streaming mode
        void set_disk_backed(std::vector<std::string> unshifted_paths, std::vector<std::string> shifted_paths)
        {
            disk_unshifted_paths = std::move(unshifted_paths);
            disk_shifted_paths = std::move(shifted_paths);
        }

        bool is_disk_backed() const { return !disk_unshifted_paths.empty(); }

        void set_interleaved(RefVector<Polynomial> results, std::vector<RefVector<Polynomial>> groups)
        {
            // Ensure the Gemini subprotocol for interleaved polynomials operates correctly
            if (groups[0].size() % 2 != 0) {
                throw_or_abort("Group size must be even ");
            }
            interleaved = results;
            groups_to_be_interleaved = groups;
        }

        /**
         * @brief Compute batched polynomial A₀ = F + G/X as the linear combination of all polynomials to be opened,
         * where F is the linear combination of the unshifted polynomials and G is the linear combination of the
         * to-be-shifted-by-1 polynomials.
         *
         * @param challenge batching challenge
         * @return Polynomial A₀
         */
        Polynomial compute_batched(const Fr& challenge)
        {
            // If disk-backed paths are set, use streaming mode
            if (is_disk_backed()) {
                return compute_batched_from_disk(challenge, disk_unshifted_paths, disk_shifted_paths);
            }

            BB_BENCH_NAME("compute_batched");

            // Precompute all batching scalars (powers of challenge)
            Fr running_scalar(1);
            std::vector<Fr> unshifted_scalars;
            std::vector<Fr> shifted_scalars;
            unshifted_scalars.reserve(unshifted.size());
            for (size_t i = 0; i < unshifted.size(); ++i) {
                unshifted_scalars.push_back(running_scalar);
                running_scalar *= challenge;
            }
            shifted_scalars.reserve(to_be_shifted_by_one.size());
            for (size_t i = 0; i < to_be_shifted_by_one.size(); ++i) {
                shifted_scalars.push_back(running_scalar);
                running_scalar *= challenge;
            }

            Polynomial full_batched(full_batched_size);

            // Fused batching: single parallel_for accumulates both unshifted and shifted polys
            // per thread chunk, then a second pass combines F + G/X into full_batched.
            {
                const bool do_unshifted = has_unshifted();
                const bool do_shifted = has_to_be_shifted_by_one();
                if (do_unshifted || do_shifted) {
                    // L1-cache-tiled accumulation: process elements in tiles so the accumulator
                    // stays hot in L1 (128KB) across all polynomial iterations. Without tiling,
                    // the accumulator (11 MB per thread chunk at 2^22) is evicted between each of
                    // the 36+ polynomial passes, causing redundant L2/L3 round-trips.
                    constexpr size_t TILE_ELEMS = 2048; // 64KB of Fr data — fits in 128KB L1 of M3 P-cores
                    parallel_for([&](const ThreadChunk& chunk) {
                        auto range = chunk.range(full_batched_size);
                        size_t chunk_start = *range.begin();
                        size_t chunk_end = chunk_start + static_cast<size_t>(std::ranges::distance(range));
                        if (do_unshifted) {
                            for (size_t tile = chunk_start; tile < chunk_end; tile += TILE_ELEMS) {
                                size_t tile_end = std::min(tile + TILE_ELEMS, chunk_end);
                                for (size_t k = 0; k < unshifted.size(); ++k) {
                                    const auto& poly = unshifted[k];
                                    size_t loop_start = std::max(tile, poly.start_index());
                                    size_t loop_end = std::min(tile_end, poly.end_index());
                                    const Fr& scalar = unshifted_scalars[k];
                                    for (size_t idx = loop_start; idx < loop_end; ++idx) {
                                        batched_unshifted.at(idx) += scalar * poly.at(idx);
                                    }
                                }
                            }
                        }
                        if (do_shifted) {
                            for (size_t tile = chunk_start; tile < chunk_end; tile += TILE_ELEMS) {
                                size_t tile_end = std::min(tile + TILE_ELEMS, chunk_end);
                                for (size_t k = 0; k < to_be_shifted_by_one.size(); ++k) {
                                    const auto& poly = to_be_shifted_by_one[k];
                                    size_t loop_start = std::max(tile, poly.start_index());
                                    size_t loop_end = std::min(tile_end, poly.end_index());
                                    const Fr& scalar = shifted_scalars[k];
                                    for (size_t idx = loop_start; idx < loop_end; ++idx) {
                                        batched_to_be_shifted_by_one.at(idx) += scalar * poly.at(idx);
                                    }
                                }
                            }
                        }
                    });
                }
                // Compute A₀ = F + G/X (barrier-separated: shifted read at(i+1) crosses chunk boundaries)
                if (do_unshifted && do_shifted) {
                    parallel_for([&](const ThreadChunk& chunk) {
                        for (size_t i : chunk.range(full_batched_size)) {
                            full_batched.at(i) = batched_unshifted.at(i) + batched_to_be_shifted_by_one.at(i + 1);
                        }
                    });
                } else if (do_unshifted) {
                    full_batched += batched_unshifted;
                } else if (do_shifted) {
                    full_batched += batched_to_be_shifted_by_one.shifted();
                }
            }

            // compute the linear combination of the interleaved polynomials and groups
            if (has_interleaved()) {
                batched_interleaved = Polynomial(full_batched_size);
                for (size_t i = 0; i < groups_to_be_interleaved[0].size(); ++i) {
                    batched_group.push_back(Polynomial(full_batched_size));
                }

                for (size_t i = 0; i < groups_to_be_interleaved.size(); ++i) {
                    batched_interleaved.add_scaled(interleaved[i], running_scalar);
                    // Use parallel chunking for the batching operations
                    parallel_for([this, running_scalar, i](const ThreadChunk& chunk) {
                        for (size_t j = 0; j < groups_to_be_interleaved[0].size(); ++j) {
                            batched_group[j].add_scaled_chunk(chunk, groups_to_be_interleaved[i][j], running_scalar);
                        }
                    });
                    running_scalar *= challenge;
                }

                full_batched += batched_interleaved;
            }

            // After batching, source polynomial references are no longer needed.
            // Invoke callback to allow caller to free source memory.
            if (post_batch_callback) {
                post_batch_callback();
            }

            return full_batched;
        }

        /**
         * @brief Memory-efficient version of compute_batched that loads polynomials one at a time from disk.
         * @details Used by streaming sumcheck to avoid holding all original polynomials in memory during PCS.
         * Each polynomial is loaded from a serialized file, accumulated into the batch, then freed.
         * Peak memory: 1 polynomial + 2 accumulators + result ≈ 2 GiB for 2^24 circuits.
         *
         * @param challenge The batching challenge rho
         * @param unshifted_paths Paths to serialized unshifted polynomial files (in get_unshifted() order)
         * @param shifted_paths Paths to serialized to-be-shifted polynomial files (in get_to_be_shifted() order)
         */
        Polynomial compute_batched_from_disk(const Fr& challenge,
                                             const std::vector<std::string>& unshifted_paths,
                                             const std::vector<std::string>& shifted_paths)
        {
            Fr running_scalar(1);
            BB_BENCH_NAME("compute_batched_from_disk");

            Polynomial full_batched(full_batched_size);

            // Process unshifted polynomials: mmap from disk one at a time (zero-copy read)
            for (const auto& path : unshifted_paths) {
                if (path.empty()) {
                    running_scalar *= challenge;
                    continue;
                }
                auto poly = Polynomial::mmap_from_file(path);
                batched_unshifted.add_scaled(poly, running_scalar);
                running_scalar *= challenge;
                // poly goes out of scope here, munmap frees virtual mapping
            }
            full_batched += batched_unshifted;

            // Process to-be-shifted polynomials: mmap from disk one at a time
            for (const auto& path : shifted_paths) {
                if (path.empty()) {
                    running_scalar *= challenge;
                    continue;
                }
                auto poly = Polynomial::mmap_from_file(path);
                batched_to_be_shifted_by_one.add_scaled(poly, running_scalar);
                running_scalar *= challenge;
            }
            full_batched += batched_to_be_shifted_by_one.shifted();

            return full_batched;
        }

        /**
         * @brief Compute partially evaluated batched polynomials A₀(X, r) = A₀₊ = F + G/r, A₀(X, -r) = A₀₋ = F - G/r
         *
         * @param r_challenge partial evaluation challenge
         * @return std::pair<Polynomial, Polynomial> {A₀₊, A₀₋}
         */
        std::pair<Polynomial, Polynomial> compute_partially_evaluated_batch_polynomials(const Fr& r_challenge)
        {
            const bool has_F = has_unshifted();
            const bool has_G = has_to_be_shifted_by_one();

            // Fused single-pass: compute A₀₊ = F + G/r and A₀₋ = F - G/r simultaneously,
            // avoiding intermediate copies and reducing memory passes from 5 to 1.
            Polynomial A_0_pos(full_batched_size, full_batched_size, /*start_index=*/0,
                               Polynomial::DontZeroMemory::FLAG);
            Polynomial A_0_neg(full_batched_size, full_batched_size, /*start_index=*/0,
                               Polynomial::DontZeroMemory::FLAG);

            if (has_F && has_G) {
                const Fr r_inv = r_challenge.invert();
                Fr* pos_data = A_0_pos.data();
                Fr* neg_data = A_0_neg.data();

                constexpr size_t COST =
                    thread_heuristics::FF_MULTIPLICATION_COST + (2 * thread_heuristics::FF_ADDITION_COST);
                parallel_for_heuristic(
                    full_batched_size,
                    [&](size_t start, size_t end, BB_UNUSED size_t chunk_idx) {
                        for (size_t i = start; i < end; i++) {
                            // operator[] handles virtual zeros for indices outside [start_index, end_index)
                            Fr F_i = batched_unshifted[i];
                            Fr G_scaled = batched_to_be_shifted_by_one[i] * r_inv;
                            pos_data[i] = F_i + G_scaled;
                            neg_data[i] = F_i - G_scaled;
                        }
                    },
                    COST);
            } else if (has_F) {
                // A₀₊ = A₀₋ = F
                const Fr* F_data = batched_unshifted.data();
                Fr* pos_data = A_0_pos.data();
                Fr* neg_data = A_0_neg.data();
                const size_t F_end = batched_unshifted.end_index();
                parallel_for_heuristic(
                    full_batched_size,
                    [&](size_t start, size_t end, BB_UNUSED size_t chunk_idx) {
                        for (size_t i = start; i < end; i++) {
                            Fr val = (i < F_end) ? F_data[i] : Fr::zero();
                            pos_data[i] = val;
                            neg_data[i] = val;
                        }
                    },
                    thread_heuristics::FF_COPY_COST);
            } else {
                // No F, no G — zero polynomials
                Fr* pos_data = A_0_pos.data();
                Fr* neg_data = A_0_neg.data();
                parallel_for_heuristic(
                    full_batched_size,
                    [&](size_t start, size_t end, BB_UNUSED size_t chunk_idx) {
                        for (size_t i = start; i < end; i++) {
                            pos_data[i] = Fr::zero();
                            neg_data[i] = Fr::zero();
                        }
                    },
                    thread_heuristics::FF_COPY_COST);
            }

            return { std::move(A_0_pos), std::move(A_0_neg) };
        };
        /**
         * @brief Compute the partially evaluated polynomials P₊(X, r) and P₋(X, -r)
         *
         * @details If the interleaved polynomials are set, the full partially evaluated identites A₀(r) and  A₀(-r)
         * contain the contributions of P₊(r^s) and  P₋(r^s) respectively where s is the size of the interleaved
         * group assumed even. This function computes P₊(X) = ∑ r^i Pᵢ(X) and P₋(X) = ∑ (-r)^i Pᵢ(X) where Pᵢ(X) is
         * the i-th polynomial in the batched group.
         * @param r_challenge partial evaluation challenge
         * @return std::pair<Polynomial, Polynomial> {P₊, P₋}
         */

        std::pair<Polynomial, Polynomial> compute_partially_evaluated_interleaved_polynomial(const Fr& r_challenge)
        {
            Polynomial P_pos(batched_group[0]);
            Polynomial P_neg(batched_group[0]);

            Fr current_r_shift_pos = r_challenge;
            Fr current_r_shift_neg = -r_challenge;
            for (size_t i = 1; i < batched_group.size(); i++) {
                // Add r^i * Pᵢ(X) to P₊(X)
                P_pos.add_scaled(batched_group[i], current_r_shift_pos);
                // Add (-r)^i * Pᵢ(X) to P₋(X)
                P_neg.add_scaled(batched_group[i], current_r_shift_neg);
                // Update the current power of r
                current_r_shift_pos *= r_challenge;
                current_r_shift_neg *= -r_challenge;
            }

            return { P_pos, P_neg };
        }

        size_t get_group_size() { return batched_group.size(); }
    };

    static std::vector<Polynomial> compute_fold_polynomials(const size_t log_n,
                                                            std::span<const Fr> multilinear_challenge,
                                                            const Polynomial& A_0,
                                                            const bool& has_zk = false);

    static std::pair<Polynomial, Polynomial> compute_partially_evaluated_batch_polynomials(
        const size_t log_n,
        PolynomialBatcher& polynomial_batcher,
        const Fr& r_challenge,
        const std::vector<Polynomial>& batched_groups_to_be_concatenated = {});

    static std::vector<Claim> construct_univariate_opening_claims(const size_t log_n,
                                                                  Polynomial&& A_0_pos,
                                                                  Polynomial&& A_0_neg,
                                                                  std::vector<Polynomial>&& fold_polynomials,
                                                                  const Fr& r_challenge);

    template <typename Transcript>
    static std::vector<Claim> prove(size_t circuit_size,
                                    PolynomialBatcher& polynomial_batcher,
                                    std::span<Fr> multilinear_challenge,
                                    const CommitmentKey<Curve>& commitment_key,
                                    const std::shared_ptr<Transcript>& transcript,
                                    bool has_zk = false);

}; // namespace bb

/**
 * @brief Gemini Verifier utility methods used by ShpleminiVerifier
 */
template <typename Curve> class GeminiVerifier_ {
    using Fr = typename Curve::ScalarField;
    using Commitment = typename Curve::AffineElement;

  public:
    /**
     * @brief Receive the fold commitments from the prover. This method is used by Shplemini where padding may be
     * enabled, i.e. the verifier receives the same number of commitments independent of the actual circuit size.
     *
     * @param virtual_log_n An integer >= log_n
     * @param transcript
     * @return A vector of fold commitments \f$ [A_i] \f$ for \f$ i = 1, \ldots, \text{virtual_log_n}-1\f$.
     */
    static std::vector<Commitment> get_fold_commitments(const size_t virtual_log_n, auto& transcript)
    {
        std::vector<Commitment> fold_commitments;
        fold_commitments.reserve(virtual_log_n - 1);
        for (size_t i = 1; i < virtual_log_n; ++i) {
            const Commitment commitment =
                transcript->template receive_from_prover<Commitment>("Gemini:FOLD_" + std::to_string(i));
            fold_commitments.emplace_back(commitment);
        }
        return fold_commitments;
    }

    /**
     * @brief Receive the fold evaluations from the prover. This method is used by Shplemini where padding may be
     * enabled, i.e. the verifier receives the same number of commitments independent of the actual circuit size.
     *
     * @param virtual_log_n An integer >= log_n
     * @param transcript
     * @return A vector of claimed negative fold evaluation \f$ A_i(-r^{2^i}) \f$  for \f$ i = 0, \ldots,
     * \text{virtual_log_n}-1\f$.
     */
    static std::vector<Fr> get_gemini_evaluations(const size_t virtual_log_n, auto& transcript)
    {
        std::vector<Fr> gemini_evaluations;
        gemini_evaluations.reserve(virtual_log_n);

        for (size_t i = 1; i <= virtual_log_n; ++i) {
            const Fr evaluation = transcript->template receive_from_prover<Fr>("Gemini:a_" + std::to_string(i));
            gemini_evaluations.emplace_back(evaluation);
        }
        return gemini_evaluations;
    }

    /**
     * @brief Compute \f$ A_0(r), A_1(r^2), \ldots, A_{d-1}(r^{2^{d-1}})\f$
     *
     * Recall that \f$ A_0(r) = \sum \rho^i \cdot f_i + \frac{1}{r} \cdot \sum \rho^{i+k} g_i \f$, where \f$
     * k \f$ is the number of "unshifted" commitments. \f$ f_i \f$ are the unshifted polynomials and \f$ g_i \f$ are the
     * to-be-shifted-by-1 polynomials.
     *
     * @details Initialize `a_pos` = \f$ A_{d}(r) \f$ with the batched evaluation \f$ \sum \rho^i f_i(\vec{u}) +
     * \sum
     * \rho^{i+k} g_i(\vec{u}) \f$. The verifier recovers \f$ A_{l-1}(r^{2^{l-1}}) \f$ from the "negative" value \f$
     * A_{l-1}\left(-r^{2^{l-1}}\right) \f$ received from the prover and the value \f$ A_{l}\left(r^{2^{l}}\right)
     * \f$ computed at the previous step. Namely, the verifier computes
     * \f{align}{ A_{l-1}\left(r^{2^{l-1}}\right) =
     * \frac{2 \cdot r^{2^{l-1}} \cdot A_{l}\left(r^{2^l}\right) - A_{l-1}\left( -r^{2^{l-1}} \right)\cdot
     * \left(r^{2^{l-1}} (1-u_{l-1}) - u_{l-1}\right)} {r^{2^{l-1}} (1- u_{l-1}) + u_{l-1}}. \f}
     *
     * In the case of interleaving, the first "negative" evaluation has to be corrected by the contribution from \f$
     * P_{-}(-r^s)\f$, where \f$ s \f$ is the size of the group to be interleaved.
     *
     * This method uses `padding_indicator_array`, whose i-th entry is FF{1} if i < log_n and 0 otherwise.
     * We use these entries to either assign `eval_pos_prev` the value `eval_pos` computed in the current iteration
     * of the loop, or to propagate the batched evaluation of the multilinear polynomials to the next iteration.
     * This ensures the correctnes of the computation of the required positive evaluations.
     *
     * To ensure that dummy evaluations cannot be used to tamper with the final batch_mul result, we multiply dummy
     * positive evaluations by the entries of `padding_indicator_array`.
     *
     * @param padding_indicator_array An array with first log_n entries equal to 1, and the remaining entries are 0.
     * @param batched_evaluation The evaluation of the batched polynomial at \f$ (u_0, \ldots, u_{d-1})\f$.
     * @param evaluation_point Evaluation point \f$ (u_0, \ldots, u_{d-1}) \f$. Depending on the context, might be
     * padded to `virtual_log_n` size.
     * @param challenge_powers Powers of \f$ r \f$, \f$ r^2 ,\dots, r^{2^{d-1}} \f$.
     * @param fold_neg_evals  Evaluations \f$ A_{i-1}(-r^{2^{i-1}}) \f$.
     * @return \f$ A_{i}(r^{2^{i}})\f$ for \f$ i = 0, \ldots, \text{virtual_log_n} - 1 \f$.
     */
    static std::vector<Fr> compute_fold_pos_evaluations(std::span<const Fr> padding_indicator_array,
                                                        const Fr& batched_evaluation,
                                                        std::span<const Fr> evaluation_point, // size = virtual_log_n
                                                        std::span<const Fr> challenge_powers, // size = virtual_log_n
                                                        std::span<const Fr> fold_neg_evals,   // size = virtual_log_n
                                                        Fr p_neg = Fr(0))
    {
        const size_t virtual_log_n = evaluation_point.size();

        std::vector<Fr> evals(fold_neg_evals.begin(), fold_neg_evals.end());

        Fr eval_pos_prev = batched_evaluation;

        std::vector<Fr> fold_pos_evaluations;
        fold_pos_evaluations.reserve(virtual_log_n);

        // Add the contribution of P-((-r)ˢ) to get A_0(-r), which is 0 if there are no interleaved polynomials
        evals[0] += p_neg;
        // Solve the sequence of linear equations
        for (size_t l = virtual_log_n; l != 0; --l) {
            // Get r²⁽ˡ⁻¹⁾
            const Fr& challenge_power = challenge_powers[l - 1];
            // Get uₗ₋₁
            const Fr& u = evaluation_point[l - 1];
            // Get A₍ₗ₋₁₎(−r²⁽ˡ⁻¹⁾)
            const Fr& eval_neg = evals[l - 1];
            // Compute the numerator
            Fr eval_pos = ((challenge_power * eval_pos_prev * 2) - eval_neg * (challenge_power * (Fr(1) - u) - u));
            // Divide by the denominator
            eval_pos *= (challenge_power * (Fr(1) - u) + u).invert();

            // If current index is bigger than log_n, we propagate `batched_evaluation` to the next
            // round.  Otherwise, current `eval_pos` A₍ₗ₋₁₎(r²⁽ˡ⁻¹⁾) becomes `eval_pos_prev` in the round l-2.
            eval_pos_prev =
                padding_indicator_array[l - 1] * eval_pos + (Fr{ 1 } - padding_indicator_array[l - 1]) * eval_pos_prev;
            // If current index is bigger than log_n, we emplace 0, which is later multiplied against
            // Commitment::one().
            fold_pos_evaluations.emplace_back(padding_indicator_array[l - 1] * eval_pos_prev);
        }

        std::reverse(fold_pos_evaluations.begin(), fold_pos_evaluations.end());

        return fold_pos_evaluations;
    }
};

} // namespace bb

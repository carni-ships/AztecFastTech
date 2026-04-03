// === AUDIT STATUS ===
// internal:    { status: Complete, auditors: [Khashayar], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================

#pragma once
#include "barretenberg/commitment_schemes/claim.hpp"
#include "barretenberg/commitment_schemes/commitment_key.hpp"
#include "barretenberg/commitment_schemes/verification_key.hpp"
#include "barretenberg/common/assert.hpp"
#include "barretenberg/stdlib/primitives/curves/bn254.hpp"
#include "barretenberg/transcript/transcript.hpp"

/**
 * @brief Reduces multiple claims about commitments, each opened at a single point
 *  into a single claim for a single polynomial opened at a single point.
 *
 * We use the following terminology:
 * - Bₖ(X) is a random linear combination of all polynomials opened at Ωₖ
 *   we refer to it a 'merged_polynomial'.
 * - Tₖ(X) is the polynomial that interpolates Bₖ(X) over Ωₖ,
 * - zₖ(X) is the product of all (X-x), for x ∈ Ωₖ
 * - ẑₖ(X) = 1/zₖ(X)
 *
 * The challenges are ρ (batching) and r (random evaluation).
 *
 */
namespace bb {

/**
 * @brief Shplonk Prover
 *
 * @tparam Curve EC parameters
 */
template <typename Curve> class ShplonkProver_ {
    using Fr = typename Curve::ScalarField;
    using Polynomial = bb::Polynomial<Fr>;

  public:
    // Minimum polynomial size to use parallel scan (below this, sequential is faster due to overhead)
    static constexpr size_t PARALLEL_QUOTIENT_THRESHOLD = 65536;

    /**
     * @brief Fused quotient computation and accumulation: computes (p(X) - v) / (X - r) and adds it
     *        scaled by nu directly to Q, without allocating a temporary polynomial.
     * @details For large polynomials, uses a parallel scan to exploit multiple cores:
     *          1. Each thread computes its chunk independently (assuming prev=0 at chunk start)
     *          2. Sequential scan of chunk boundary values determines corrections
     *          3. Each thread applies its correction in parallel
     *          The recurrence q[i] = (p[i] - q[i-1]) * a propagates errors as (-a)^k * boundary_error.
     */
    static void fused_quotient_accumulate(Polynomial& Q,
                                          const Polynomial& poly,
                                          const Fr& eval,
                                          const Fr& root,
                                          const Fr& nu)
    {
        const Fr neg_root_inv = (-root).invert();
        const size_t si = poly.start_index();
        const size_t ei = poly.end_index();
        if (ei <= si + 1) {
            return;
        }
        const size_t n = ei - 1 - si; // number of quotient coefficients

        if (n < PARALLEL_QUOTIENT_THRESHOLD) {
            // Sequential path for small polynomials
            Fr prev = (poly.at(si) - eval) * neg_root_inv;
            Q.at(si) += nu * prev;
            for (size_t i = si + 1; i < ei - 1; ++i) {
                prev = (poly.at(i) - prev) * neg_root_inv;
                Q.at(i) += nu * prev;
            }
            return;
        }

        // Parallel scan for large polynomials
        const size_t num_threads = get_num_cpus();
        const size_t chunk_size = (n + num_threads - 1) / num_threads;
        const Fr neg_a = -neg_root_inv; // = 1/root, the recurrence coefficient for error propagation

        // Phase 1: Each thread computes its chunk independently, storing the last q value
        std::vector<Fr> chunk_last_q(num_threads, Fr::zero());

        parallel_for_heuristic(
            n,
            [&](size_t start, size_t end, size_t chunk_idx) {
                const size_t abs_start = si + start;
                const size_t abs_end = si + end;
                Fr prev = Fr::zero();
                // First element of chunk: subtract eval only for the very first chunk
                if (start == 0) {
                    prev = (poly.at(abs_start) - eval) * neg_root_inv;
                } else {
                    prev = poly.at(abs_start) * neg_root_inv;
                }
                Q.at(abs_start) += nu * prev;
                for (size_t i = abs_start + 1; i < abs_end && i < ei - 1; ++i) {
                    prev = (poly.at(i) - prev) * neg_root_inv;
                    Q.at(i) += nu * prev;
                }
                chunk_last_q[chunk_idx] = prev;
            },
            thread_heuristics::FF_MULTIPLICATION_COST * 2 + thread_heuristics::FF_ADDITION_COST);

        // Phase 2: Sequential boundary correction propagation
        // The error in chunk c's boundary assumption propagates as (-a)^chunk_size through subsequent chunks.
        // Precompute (-a)^chunk_size using fast exponentiation (O(log n) instead of O(n))
        const Fr neg_a_pow_standard = neg_a.pow(chunk_size);

        // corrections[c] = true q value at end of chunk c-1 (the boundary for chunk c)
        std::vector<Fr> corrections(num_threads, Fr::zero());
        for (size_t c = 1; c < num_threads; ++c) {
            size_t prev_chunk_actual = std::min(chunk_size, n - (c - 1) * chunk_size);
            // Use standard power for full-size chunks, compute for last chunk if different
            Fr neg_a_pow = (prev_chunk_actual == chunk_size) ? neg_a_pow_standard : neg_a.pow(prev_chunk_actual);
            corrections[c] = chunk_last_q[c - 1] + neg_a_pow * corrections[c - 1];
        }

        // Phase 3: Apply corrections to Q in parallel
        // For each element at absolute position (si + start + k) in chunk c:
        // Q_correction = nu * corrections[c] * (-a)^(k+1)
        parallel_for_heuristic(
            n,
            [&](size_t start, size_t end, size_t chunk_idx) {
                if (chunk_idx == 0) {
                    return; // First chunk has no correction
                }
                const Fr boundary_err = corrections[chunk_idx];
                if (boundary_err.is_zero()) {
                    return;
                }
                const Fr nu_err = nu * boundary_err; // Hoist multiplication out of inner loop
                Fr power = neg_a; // (-a)^1 for k=0 within chunk
                for (size_t i = si + start; i < si + end && i < ei - 1; ++i) {
                    Q.at(i) += nu_err * power;
                    power *= neg_a;
                }
            },
            thread_heuristics::FF_MULTIPLICATION_COST * 2 + thread_heuristics::FF_ADDITION_COST);
    }

    /**
     * @brief Dual-point fused quotient: computes two quotients for the same polynomial at different
     *        evaluation points in a single pass, halving memory reads for Gemini fold claims.
     * @details For fold polynomials opened at both r^{2^l} and -r^{2^l}, this reads poly[i] once
     *          and runs both recurrences simultaneously. Uses parallel scan for large polynomials.
     */
    static void fused_dual_quotient_accumulate(Polynomial& Q,
                                               const Polynomial& poly,
                                               const Fr& eval_a,
                                               const Fr& root_a,
                                               const Fr& nu_a,
                                               const Fr& eval_b,
                                               const Fr& root_b,
                                               const Fr& nu_b)
    {
        const Fr neg_root_inv_a = (-root_a).invert();
        const Fr neg_root_inv_b = (-root_b).invert();
        const size_t si = poly.start_index();
        const size_t ei = poly.end_index();
        if (ei <= si + 1) {
            return;
        }
        const size_t n = ei - 1 - si;

        if (n < PARALLEL_QUOTIENT_THRESHOLD) {
            // Sequential path
            Fr p_si = poly.at(si);
            Fr prev_a = (p_si - eval_a) * neg_root_inv_a;
            Fr prev_b = (p_si - eval_b) * neg_root_inv_b;
            Q.at(si) += nu_a * prev_a + nu_b * prev_b;
            for (size_t i = si + 1; i < ei - 1; ++i) {
                Fr p_i = poly.at(i);
                prev_a = (p_i - prev_a) * neg_root_inv_a;
                prev_b = (p_i - prev_b) * neg_root_inv_b;
                Q.at(i) += nu_a * prev_a + nu_b * prev_b;
            }
            return;
        }

        // Parallel scan for large polynomials (dual recurrences)
        const size_t num_threads = get_num_cpus();
        const size_t chunk_size = (n + num_threads - 1) / num_threads;
        const Fr neg_a_a = -neg_root_inv_a;
        const Fr neg_a_b = -neg_root_inv_b;

        struct ChunkBoundary {
            Fr last_q_a;
            Fr last_q_b;
        };
        std::vector<ChunkBoundary> chunk_boundaries(num_threads);

        // Phase 1: Independent chunk computation
        parallel_for_heuristic(
            n,
            [&](size_t start, size_t end, size_t chunk_idx) {
                const size_t abs_start = si + start;
                Fr prev_a_local = Fr::zero();
                Fr prev_b_local = Fr::zero();
                Fr p_first = poly.at(abs_start);
                if (start == 0) {
                    prev_a_local = (p_first - eval_a) * neg_root_inv_a;
                    prev_b_local = (p_first - eval_b) * neg_root_inv_b;
                } else {
                    prev_a_local = p_first * neg_root_inv_a;
                    prev_b_local = p_first * neg_root_inv_b;
                }
                Q.at(abs_start) += nu_a * prev_a_local + nu_b * prev_b_local;
                for (size_t i = abs_start + 1; i < si + end && i < ei - 1; ++i) {
                    Fr p_i = poly.at(i);
                    prev_a_local = (p_i - prev_a_local) * neg_root_inv_a;
                    prev_b_local = (p_i - prev_b_local) * neg_root_inv_b;
                    Q.at(i) += nu_a * prev_a_local + nu_b * prev_b_local;
                }
                chunk_boundaries[chunk_idx] = { prev_a_local, prev_b_local };
            },
            thread_heuristics::FF_MULTIPLICATION_COST * 4 + thread_heuristics::FF_ADDITION_COST * 2);

        // Phase 2: Sequential boundary correction propagation (O(num_threads) work)
        const Fr neg_a_pow_std_a = neg_a_a.pow(chunk_size);
        const Fr neg_a_pow_std_b = neg_a_b.pow(chunk_size);
        std::vector<ChunkBoundary> corrections(num_threads, { Fr::zero(), Fr::zero() });
        for (size_t c = 1; c < num_threads; ++c) {
            size_t prev_chunk_actual = std::min(chunk_size, n - (c - 1) * chunk_size);
            Fr neg_a_pow_a = (prev_chunk_actual == chunk_size) ? neg_a_pow_std_a : neg_a_a.pow(prev_chunk_actual);
            Fr neg_a_pow_b = (prev_chunk_actual == chunk_size) ? neg_a_pow_std_b : neg_a_b.pow(prev_chunk_actual);
            corrections[c].last_q_a = chunk_boundaries[c - 1].last_q_a + neg_a_pow_a * corrections[c - 1].last_q_a;
            corrections[c].last_q_b = chunk_boundaries[c - 1].last_q_b + neg_a_pow_b * corrections[c - 1].last_q_b;
        }

        // Phase 3: Apply corrections in parallel
        parallel_for_heuristic(
            n,
            [&](size_t start, size_t end, size_t chunk_idx) {
                if (chunk_idx == 0) {
                    return;
                }
                const Fr& err_a = corrections[chunk_idx].last_q_a;
                const Fr& err_b = corrections[chunk_idx].last_q_b;
                if (err_a.is_zero() && err_b.is_zero()) {
                    return;
                }
                const Fr nu_err_a = nu_a * err_a; // Hoist multiplications out of inner loop
                const Fr nu_err_b = nu_b * err_b;
                Fr pow_a = neg_a_a;
                Fr pow_b = neg_a_b;
                for (size_t i = si + start; i < si + end && i < ei - 1; ++i) {
                    Q.at(i) += nu_err_a * pow_a + nu_err_b * pow_b;
                    pow_a *= neg_a_a;
                    pow_b *= neg_a_b;
                }
            },
            thread_heuristics::FF_MULTIPLICATION_COST * 4 + thread_heuristics::FF_ADDITION_COST * 2);
    }

    /**
     * @brief Compute batched quotient polynomial Q(X) = ∑ⱼ νʲ ⋅ ( fⱼ(X) − vⱼ) / ( X − xⱼ )
     *
     * @param opening_claims list of prover opening claims {fⱼ(X), (xⱼ, vⱼ)} for a witness polynomial fⱼ(X), s.t. fⱼ(xⱼ)
     * = vⱼ.
     * @param nu batching challenge
     * @return Polynomial Q(X)
     */
    static Polynomial compute_batched_quotient(const size_t virtual_log_n,
                                               std::span<const ProverOpeningClaim<Curve>> opening_claims,
                                               const Fr& nu,
                                               std::span<Fr> gemini_fold_pos_evaluations,
                                               std::span<const ProverOpeningClaim<Curve>> libra_opening_claims,
                                               std::span<const ProverOpeningClaim<Curve>> sumcheck_round_claims)
    {
        // Find the maximum polynomial size among all claims to determine the dyadic size of the batched polynomial.
        size_t max_poly_size{ 0 };

        for (const auto& claim_set : { opening_claims, libra_opening_claims, sumcheck_round_claims }) {
            for (const auto& claim : claim_set) {
                max_poly_size = std::max(max_poly_size, claim.polynomial.size());
            }
        }
        // The polynomials in Sumcheck Round claims and Libra opening claims are generally not dyadic,
        // so we round up to the next power of 2.
        max_poly_size = numeric::round_up_power_2(max_poly_size);

        // Q(X) = ∑ⱼ νʲ ⋅ ( fⱼ(X) − vⱼ) / ( X − xⱼ )
        Polynomial Q(max_poly_size);

        Fr current_nu = Fr::one();

        size_t fold_idx = 0;
        for (const auto& claim : opening_claims) {

            // Gemini Fold Polynomials have to be opened at -r^{2^j} and r^{2^j}.
            // Use dual-point fusion to read the polynomial once for both quotients.
            if (claim.gemini_fold) {
                Fr nu_pos = current_nu;
                current_nu *= nu;
                Fr nu_neg = current_nu;
                current_nu *= nu;
                fused_dual_quotient_accumulate(
                    Q,
                    claim.polynomial,
                    gemini_fold_pos_evaluations[fold_idx++],
                    -claim.opening_pair.challenge,
                    nu_pos,
                    claim.opening_pair.evaluation,
                    claim.opening_pair.challenge,
                    nu_neg);
            } else {
                // Non-fold claim: single quotient
                fused_quotient_accumulate(
                    Q, claim.polynomial, claim.opening_pair.evaluation, claim.opening_pair.challenge, current_nu);
                current_nu *= nu;
            }
        }
        // We use the same batching challenge for Gemini and Libra opening claims. The number of the claims
        // batched before adding Libra commitments and evaluations is bounded by 2 * `virtual_log_n` + 2, where
        // 2 * `virtual_log_n` is the number of fold claims including the dummy ones, and +2 is reserved for
        // interleaving.
        if (!libra_opening_claims.empty()) {
            current_nu = nu.pow(2 * virtual_log_n + NUM_INTERLEAVING_CLAIMS);
        }

        for (const auto& claim : libra_opening_claims) {
            fused_quotient_accumulate(
                Q, claim.polynomial, claim.opening_pair.evaluation, claim.opening_pair.challenge, current_nu);
            current_nu *= nu;
        }

        for (const auto& claim : sumcheck_round_claims) {
            fused_quotient_accumulate(
                Q, claim.polynomial, claim.opening_pair.evaluation, claim.opening_pair.challenge, current_nu);
            current_nu *= nu;
        }
        // Return batched quotient polynomial Q(X)
        return Q;
    };

    /**
     * @brief Compute partially evaluated batched quotient polynomial difference Q(X) - Q_z(X)
     *
     * @param opening_pairs list of opening pairs (xⱼ, vⱼ) for a witness polynomial fⱼ(X), s.t. fⱼ(xⱼ) = vⱼ.
     * @param witness_polynomials list of polynomials fⱼ(X).
     * @param batched_quotient_Q Q(X) = ∑ⱼ νʲ ⋅ ( fⱼ(X) − vⱼ) / ( X − xⱼ )
     * @param nu_challenge
     * @param z_challenge
     * @return Output{OpeningPair, Polynomial}
     */
    static ProverOpeningClaim<Curve> compute_partially_evaluated_batched_quotient(
        const size_t virtual_log_n,
        std::span<ProverOpeningClaim<Curve>> opening_claims,
        Polynomial& batched_quotient_Q,
        const Fr& nu_challenge,
        const Fr& z_challenge,
        std::span<Fr> gemini_fold_pos_evaluations,
        std::span<ProverOpeningClaim<Curve>> libra_opening_claims = {},
        std::span<ProverOpeningClaim<Curve>> sumcheck_opening_claims = {})
    {
        // Our main use case is the opening of Gemini fold polynomials and each Gemini fold is opened at 2 points.
        const size_t num_gemini_opening_claims = 2 * opening_claims.size();
        const size_t num_opening_claims =
            num_gemini_opening_claims + libra_opening_claims.size() + sumcheck_opening_claims.size();

        // {ẑⱼ(z)}ⱼ , where ẑⱼ(r) = 1/zⱼ(z) = 1/(z - xⱼ)
        std::vector<Fr> inverse_vanishing_evals;
        inverse_vanishing_evals.reserve(num_opening_claims);
        for (const auto& claim : opening_claims) {
            if (claim.gemini_fold) {
                inverse_vanishing_evals.emplace_back(z_challenge + claim.opening_pair.challenge);
            }
            inverse_vanishing_evals.emplace_back(z_challenge - claim.opening_pair.challenge);
        }

        // Add the terms (z - uₖ) for k = 0, …, d−1 where d is the number of rounds in Sumcheck
        for (const auto& claim : libra_opening_claims) {
            inverse_vanishing_evals.emplace_back(z_challenge - claim.opening_pair.challenge);
        }

        for (const auto& claim : sumcheck_opening_claims) {
            inverse_vanishing_evals.emplace_back(z_challenge - claim.opening_pair.challenge);
        }

        Fr::batch_invert(inverse_vanishing_evals);

        // G(X) = Q(X) - Q_z(X) = Q(X) - ∑ⱼ νʲ ⋅ ( fⱼ(X) − vⱼ) / ( z − xⱼ ),
        // s.t. G(r) = 0
        Polynomial G(std::move(batched_quotient_Q)); // G(X) = Q(X)

        Fr current_nu = Fr::one();
        size_t idx = 0;

        size_t fold_idx = 0;
        for (auto& claim : opening_claims) {

            if (claim.gemini_fold) {
                // Fused dual-point opening: combine the two add_scaled passes (positive and negative
                // evaluation points) into a single pass over the polynomial, eliminating the copy.
                // Positive point: G -= s_pos * (f - eval_pos)  →  G[i] -= s_pos * f[i], G[0] += s_pos * eval_pos
                // Negative point: G -= s_neg * (f - eval_neg)  →  G[i] -= s_neg * f[i], G[0] += s_neg * eval_neg
                // Combined: G[i] -= (s_pos + s_neg) * f[i], G[0] += s_pos * eval_pos + s_neg * eval_neg
                Fr scaling_factor_pos = current_nu * inverse_vanishing_evals[idx++];
                current_nu *= nu_challenge;
                Fr scaling_factor_neg = current_nu * inverse_vanishing_evals[idx++];

                Fr combined_scale = scaling_factor_pos + scaling_factor_neg;
                G.add_scaled(claim.polynomial, -combined_scale);
                G.at(0) += scaling_factor_pos * gemini_fold_pos_evaluations[fold_idx++] +
                           scaling_factor_neg * claim.opening_pair.evaluation;

                current_nu *= nu_challenge;
            } else {
                Fr scaling_factor = current_nu * inverse_vanishing_evals[idx++];
                // G -= νʲ ⋅ ( fⱼ(X) − vⱼ) / ( z − xⱼ )
                G.add_scaled(claim.polynomial, -scaling_factor);
                G.at(0) += scaling_factor * claim.opening_pair.evaluation;

                current_nu *= nu_challenge;
            }
        }

        // Take into account the constant proof size in Gemini
        if (!libra_opening_claims.empty()) {
            current_nu = nu_challenge.pow(2 * virtual_log_n + NUM_INTERLEAVING_CLAIMS);
        }

        for (auto& claim : libra_opening_claims) {
            Fr scaling_factor = current_nu * inverse_vanishing_evals[idx++];
            G.add_scaled(claim.polynomial, -scaling_factor);
            G.at(0) += scaling_factor * claim.opening_pair.evaluation;
            current_nu *= nu_challenge;
        }

        for (auto& claim : sumcheck_opening_claims) {
            Fr scaling_factor = current_nu * inverse_vanishing_evals[idx++];
            G.add_scaled(claim.polynomial, -scaling_factor);
            G.at(0) += scaling_factor * claim.opening_pair.evaluation;
            current_nu *= nu_challenge;
        }
        // Return opening pair (z, 0) and polynomial G(X) = Q(X) - Q_z(X)
        return { .polynomial = G, .opening_pair = { .challenge = z_challenge, .evaluation = Fr::zero() } };
    };
    /**
     * @brief Compute evaluations of fold polynomials Fold_i at r^{2^i} for i>0.
     * TODO(https://github.com/AztecProtocol/barretenberg/issues/1223): Reconsider minor performance/memory
     * optimizations in Gemini.
     * @param opening_claims
     * @return std::vector<Fr>
     */
    static std::vector<Fr> compute_gemini_fold_pos_evaluations(
        std::span<const ProverOpeningClaim<Curve>> opening_claims)
    {
        std::vector<Fr> gemini_fold_pos_evaluations;
        gemini_fold_pos_evaluations.reserve(opening_claims.size());

        for (const auto& claim : opening_claims) {
            if (claim.gemini_fold) {
                // -r^{2^i} is stored in the claim
                const Fr evaluation_point = -claim.opening_pair.challenge;
                // Compute Fold_i(r^{2^i})
                const Fr evaluation = claim.polynomial.evaluate(evaluation_point);
                gemini_fold_pos_evaluations.emplace_back(evaluation);
            }
        }
        return gemini_fold_pos_evaluations;
    }

    /**
     * @brief Returns a batched opening claim equivalent to a set of opening claims consisting of polynomials, each
     * opened at a single point.
     *
     * @param commitment_key
     * @param opening_claims
     * @param transcript
     * @return ProverOpeningClaim<Curve>
     */
    template <typename Transcript>
    static ProverOpeningClaim<Curve> prove(const CommitmentKey<Curve>& commitment_key,
                                           std::span<ProverOpeningClaim<Curve>> opening_claims,
                                           const std::shared_ptr<Transcript>& transcript,
                                           std::span<ProverOpeningClaim<Curve>> libra_opening_claims = {},
                                           std::span<ProverOpeningClaim<Curve>> sumcheck_round_claims = {},
                                           const size_t virtual_log_n = 0)
    {
        auto shp_prove_t0 = std::chrono::steady_clock::now();
        const Fr nu = transcript->template get_challenge<Fr>("Shplonk:nu");

        // Extract precomputed positive fold evaluations from Gemini claims
        // (computed in parallel during Gemini::construct_univariate_opening_claims).
        std::vector<Fr> gemini_fold_pos_evaluations;
        {
            BB_BENCH_NAME("Shplonk::fold_pos_evals");
            gemini_fold_pos_evaluations.reserve(opening_claims.size());
            for (const auto& claim : opening_claims) {
                if (claim.gemini_fold) {
                    gemini_fold_pos_evaluations.emplace_back(claim.fold_pos_evaluation);
                }
            }
        }

        Polynomial batched_quotient;
        {
            BB_BENCH_NAME("Shplonk::compute_batched_quotient");
            batched_quotient = compute_batched_quotient(virtual_log_n,
                                                        opening_claims,
                                                        nu,
                                                        gemini_fold_pos_evaluations,
                                                        libra_opening_claims,
                                                        sumcheck_round_claims);
        }
        auto shp_prove_t1 = std::chrono::steady_clock::now();
        {
            BB_BENCH_NAME("Shplonk::Q_commit");
            auto batched_quotient_commitment = commitment_key.commit(batched_quotient);
            transcript->send_to_verifier("Shplonk:Q", batched_quotient_commitment);
        }
        auto shp_prove_t2 = std::chrono::steady_clock::now();
        const Fr z = transcript->template get_challenge<Fr>("Shplonk:z");

        ProverOpeningClaim<Curve> result;
        {
            BB_BENCH_NAME("Shplonk::partial_eval_quotient");
            result = compute_partially_evaluated_batched_quotient(virtual_log_n,
                                                                  opening_claims,
                                                                  batched_quotient,
                                                                  nu,
                                                                  z,
                                                                  gemini_fold_pos_evaluations,
                                                                  libra_opening_claims,
                                                                  sumcheck_round_claims);
        }
        auto shp_prove_t3 = std::chrono::steady_clock::now();
        {
            auto sms = [](auto a, auto b) { return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count(); };
            vinfo("shplonk prove: quotient=", sms(shp_prove_t0, shp_prove_t1), "ms Q_commit=",
                  sms(shp_prove_t1, shp_prove_t2), "ms partial_eval=", sms(shp_prove_t2, shp_prove_t3), "ms");
        }
        return result;
    }
};

/**
 * @brief Shplonk Verifier
 *
 *
 * @details Given commitments to polynomials \f$[p_1], \dots, [p_m]\f$ and couples of challenge/evaluation
 * \f$(x_i, v_i)\f$, the Shplonk verifier computes the following commitment:
 * \f[
 *      [G] := [Q] - \sum_{i=1}^m \frac{\nu^{i-1} [p_i]}{(z - x_i)} + \sum_{i=1}^m \frac{\nu^{i-1} v_i}{(z - x_i)} [1]
 * \f]
 * where \f$\nu\f$ is a random batching challenge, \f$[Q]\f$ is the commiment to the quotient polymomial
 * \f[
 *      \sum_{i=1}^m \nu^{i-1} \frac{(p_i - v_i)}{(x - x_i)}
 * \f]
 * and \f$z\f$ is the evaluation challenge.
 *
 * When the polynomials \f$p_1, \dots, p_m\f$ are linearly dependent, and the verifier which calls the Shplonk
 * verifier needs to compute the commitments \f$[p_1], \dots, [p_m]\f$ starting from the linearly independent factors,
 * computing the commitments and then executing the Shplonk verifier is not the most efficient way to execute the
 * Shplonk verifier algorithm.
 *
 * Consider the case \f$m = 2\f$, and take \f$p_2 = a p_1\f$ for some constant \f$a \in \mathbb{F}\f$. Then, the
 * most efficient way to execute the Shplonk verifier algorithm is to compute the following MSM
 * \f[
 *      [Q] - \left( \frac{1}{(z - x_1)} \
 *                  + \frac{a \nu}{(z - x_2)} \right) [p_1]  \
 *                      + \left( \frac{v_1}{(z - x_1)} + \frac{v_2 \nu}{(z - x_2)} \right) [1]
 * \f]
 *
 * The Shplonk verifier api is designed to allow the execution of the Shplonk verifier algorithm in its most efficient
 * form. To achieve this, the Shplonk verifier maintains an internal state depending of the following variables:
 *  - \f$[f_1], \dots, [f_n]\f$ (`commitments` in code) the commitments to the linearly independent polynomials such
 * that for each polynomial \f$p_i\f$ we wish to open it holds \f$p_i = \sum_{i=1}^n p_{i,j} f_j\f$ for some \f$p_j
 * \in \mathbb{F}\f$.
 *  - \f$\nu\f$ (`nu` in code) the challenge used to batch the polynomial commitments.
 *  - \f$\nu^{i}\f$ (`current_nu` in code), which is the power of the batching challenge used to batch the
 *      \f$i\f$-th polynomial \f$ p_i \f$ in the Shplonk verifier algorithm.
 *  - \f$[Q]\f$ (`quotient` in code).
 *  - \f$z\f$ (`z_challenge` in code), the partial evaluation challenge.
 *  - \f$(s_1, \dots, s_n)\f$ (`scalars` in code), the coefficient of \f$[f_i]\f$ in the Shplonk verifier MSM.
 *  - \f$\theta\f$ (`identity_scalar_coefficient` in code), the coefficient of \f$[1]\f$ in the Shplonk verifier MSM.
 *  - `evaluation`, the claimed evaluation at \f$z\f$ of the commitment produced by the Shplonk verifier, always equal
 *      to \f$0\f$.
 */
template <typename Curve> class ShplonkVerifier_ {
    using Fr = typename Curve::ScalarField;
    using GroupElement = typename Curve::Element;
    using Commitment = typename Curve::AffineElement;
    using VK = VerifierCommitmentKey<Curve>;

    // Random challenges
    std::vector<Fr> pows_of_nu;
    // Commitment to quotient polynomial
    Commitment quotient;
    // Partial evaluation challenge
    Fr z_challenge;
    // Commitments \f$[f_1], \dots, [f_n]\f$
    std::vector<Commitment> commitments;
    // Scalar coefficients of \f$[f_1], \dots, [f_n]\f$ in the MSM needed to compute the commitment to the partially
    // evaluated quotient
    std::vector<Fr> scalars;
    // Coefficient of the identity in partially evaluated quotient
    Fr identity_scalar_coefficient = Fr(0);
    // Target evaluation
    Fr evaluation = Fr(0);

  public:
    template <typename Transcript>
    ShplonkVerifier_(std::vector<Commitment>& polynomial_commitments,
                     std::shared_ptr<Transcript>& transcript,
                     const size_t num_claims)
        : pows_of_nu({ Fr(1), transcript->template get_challenge<Fr>("Shplonk:nu") })
        , quotient(transcript->template receive_from_prover<Commitment>("Shplonk:Q"))
        , z_challenge(transcript->template get_challenge<Fr>("Shplonk:z"))
        , commitments({ quotient })
        , scalars{ Fr{ 1 } }
    {
        BB_ASSERT_GT(num_claims, 1U, "Using Shplonk with just one claim. Should use batch reduction.");
        const size_t num_commitments = commitments.size();
        commitments.reserve(num_commitments);
        scalars.reserve(num_commitments);
        pows_of_nu.reserve(num_claims);

        commitments.insert(commitments.end(), polynomial_commitments.begin(), polynomial_commitments.end());
        scalars.insert(scalars.end(), commitments.size() - 1, Fr(0)); // Initialized as circuit constants
        // The first two powers of nu have already been initialized, we need another `num_claims - 2` powers to batch
        // all the claims
        for (size_t idx = 0; idx < num_claims - 2; idx++) {
            pows_of_nu.emplace_back(pows_of_nu.back() * pows_of_nu[1]);
        }

        if constexpr (Curve::is_stdlib_type) {
            evaluation.convert_constant_to_fixed_witness(pows_of_nu[1].get_context());
        }
    }

    /**
     * @brief Finalize the Shplonk verification and return the KZG opening claim
     *
     * @details Compute the commitment:
     *      \f[ [Q] - \sum_i s_i * [f_i] + \theta * [1] \f]
     * @param g1_identity
     * @return OpeningClaim<Curve>
     */
    OpeningClaim<Curve> finalize(const Commitment& g1_identity)
    {
        commitments.emplace_back(g1_identity);
        scalars.emplace_back(identity_scalar_coefficient);
        GroupElement result = GroupElement::batch_mul(commitments, scalars);

        return { { z_challenge, evaluation }, result };
    }

    /**
     * @brief Export a BatchOpeningClaim instead of performing final batch_mul
     *
     * @details Append g1_identity to `commitments`, `identity_scalar_factor` to scalars, and export the resulting
     * vectors. This method is useful when we perform KZG verification of the Shplonk claim right after Shplonk (because
     * we can add the last commitment \f$[W]\f$ and scalar factor (0 in this case) to the list and then execute a single
     * batch mul.
     *
     * @note This function modifies the `commitments` and `scalars` attribute of the class instance on which it is
     * called.
     *
     * @param g1_identity
     * @return BatchOpeningClaim<Curve>
     */
    // TODO(https://github.com/AztecProtocol/barretenberg/issues/1475): Compute g1_identity inside the function body
    BatchOpeningClaim<Curve> export_batch_opening_claim(const Commitment& g1_identity)
    {
        commitments.emplace_back(g1_identity);
        scalars.emplace_back(identity_scalar_coefficient);

        return { commitments, scalars, z_challenge };
    }

    /**
     * @brief Instantiate a Shplonk verifier and update its state with the provided claims.
     *
     * @param claims List of opening claims \f$(C_j, x_j, v_j)\f$ for a witness polynomial \f$f_j(X)\f$, s.t.
     * \f$f_j(x_j) = v_j\f$.
     * @param transcript
     */
    template <typename Transcript>
    static ShplonkVerifier_<Curve> reduce_verification_no_finalize(std::span<const OpeningClaim<Curve>> claims,
                                                                   std::shared_ptr<Transcript>& transcript)
    {
        // Initialize Shplonk verifier
        const size_t num_claims = claims.size();
        std::vector<Commitment> polynomial_commiments;
        polynomial_commiments.reserve(num_claims);
        for (const auto& claim : claims) {
            polynomial_commiments.emplace_back(claim.commitment);
        }
        ShplonkVerifier_<Curve> verifier(polynomial_commiments, transcript, num_claims);

        // Compute { 1 / (z - x_i) }
        std::vector<Fr> inverse_vanishing_evals;
        inverse_vanishing_evals.reserve(num_claims);
        if constexpr (Curve::is_stdlib_type) {
            for (const auto& claim : claims) {
                inverse_vanishing_evals.emplace_back((verifier.z_challenge - claim.opening_pair.challenge).invert());
            }
        } else {
            for (const auto& claim : claims) {
                inverse_vanishing_evals.emplace_back(verifier.z_challenge - claim.opening_pair.challenge);
            }
            Fr::batch_invert(inverse_vanishing_evals);
        }

        // Update the Shplonk verifier state with each claim
        // For each claim: s_i -= ν^i / (z - x_i) and θ += ν^i * v_i / (z - x_i)
        for (size_t idx = 0; idx < claims.size(); idx++) {
            // Compute ν^i / (z - x_i)
            auto scalar_factor = verifier.pows_of_nu[idx] * inverse_vanishing_evals[idx];
            // s_i -= ν^i / (z - x_i)
            verifier.scalars[idx + 1] -= scalar_factor;
            // θ += ν^i * v_i / (z - x_i)
            verifier.identity_scalar_coefficient += scalar_factor * claims[idx].opening_pair.evaluation;
        }

        return verifier;
    };

    /**
     * @brief Recomputes the new claim commitment [G] given the proof and
     * the challenge r. No verification happens so this function always succeeds.
     *
     * @param g1_identity the identity element for the Curve
     * @param claims list of opening claims \f$(C_j, x_j, v_j)\f$ for a witness polynomial \f$f_j(X)\f$, s.t.
     * \f$f_j(x_j) = v_j\f$.
     * @param transcript
     * @return OpeningClaim
     */
    template <typename Transcript>
    static OpeningClaim<Curve> reduce_verification(Commitment g1_identity,
                                                   std::span<const OpeningClaim<Curve>> claims,
                                                   std::shared_ptr<Transcript>& transcript)
    {
        auto verifier = ShplonkVerifier_::reduce_verification_no_finalize(claims, transcript);
        return verifier.finalize(g1_identity);
    };

    /**
     * @brief Computes \f$ \frac{1}{z - r}, \frac{1}{z + r}, \ldots, \frac{1}{z - r^{2^{d-1}}}, \frac{1}{z +
     * r^{2^{d-1}}} \f$.
     *
     * @param shplonk_eval_challenge \f$ z \f$
     * @param gemini_eval_challenge_powers \f$ (r , r^2, \ldots, r^{2^{d-1}}) \f$
     * @return \f[ \left( \frac{1}{z - r}, \frac{1}{z + r},  \ldots, \frac{1}{z - r^{2^{d-1}}}, \frac{1}{z +
     * r^{2^{d-1}}} \right) \f]
     */
    static std::vector<Fr> compute_inverted_gemini_denominators(const Fr& shplonk_eval_challenge,
                                                                const std::vector<Fr>& gemini_eval_challenge_powers)
    {
        std::vector<Fr> denominators;
        const size_t virtual_log_n = gemini_eval_challenge_powers.size();
        const size_t num_gemini_claims = 2 * virtual_log_n;
        denominators.reserve(num_gemini_claims);

        for (const auto& gemini_eval_challenge_power : gemini_eval_challenge_powers) {
            // Place 1/(z - r ^ {2^j})
            denominators.emplace_back(shplonk_eval_challenge - gemini_eval_challenge_power);
            // Place 1/(z + r ^ {2^j})
            denominators.emplace_back(shplonk_eval_challenge + gemini_eval_challenge_power);
        }

        if constexpr (!Curve::is_stdlib_type) {
            Fr::batch_invert(denominators);
        } else {
            for (auto& denominator : denominators) {
                denominator = denominator.invert();
            }
        }
        return denominators;
    }
};

/**
 * @brief A helper used by Shplemini Verifier. Precomputes a vector of the powers of \f$ \nu \f$ needed to batch all
 * univariate claims.
 *
 */
template <typename Fr>
static std::vector<Fr> compute_shplonk_batching_challenge_powers(const Fr& shplonk_batching_challenge,
                                                                 const size_t virtual_log_n,
                                                                 bool has_zk = false,
                                                                 bool committed_sumcheck = false)
{
    // Minimum size of `denominators`
    // Note that when the claim batch has no interleaving this will create one power more than it is used, so the
    // circuit will have a witness appearing only in one gate. Getting rid of this extra power is complicated because of
    // how Gemini and interleaving are coupled. This is not a security issue, we just compute a value that we never use.
    size_t num_powers = 2 * virtual_log_n + NUM_INTERLEAVING_CLAIMS;
    // Each round univariate is opened at 0, 1, and a round challenge.
    static constexpr size_t NUM_COMMITTED_SUMCHECK_CLAIMS_PER_ROUND = 3;

    // Shplonk evaluation and batching challenges are re-used in SmallSubgroupIPA.
    if (has_zk) {
        num_powers += NUM_SMALL_IPA_EVALUATIONS;
    }

    // Commited sumcheck adds 3 claims per round.
    if (committed_sumcheck) {
        num_powers += NUM_COMMITTED_SUMCHECK_CLAIMS_PER_ROUND * virtual_log_n;
    }

    std::vector<Fr> result;
    result.reserve(num_powers);
    result.emplace_back(Fr{ 1 });
    for (size_t idx = 1; idx < num_powers; idx++) {
        result.emplace_back(result[idx - 1] * shplonk_batching_challenge);
    }
    return result;
}
} // namespace bb

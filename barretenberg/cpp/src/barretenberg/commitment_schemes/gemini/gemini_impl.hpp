// === AUDIT STATUS ===
// internal:    { status: Planned, auditors: [Khashayar], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================

#pragma once
#include "barretenberg/common/bb_bench.hpp"
#include "barretenberg/common/thread.hpp"
#include "barretenberg/ecc/scalar_multiplication/scalar_multiplication.hpp"
#include "gemini.hpp"
#include <chrono>
#include <future>

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
 * v₀, …, vₖ₋₁, v↺₀, …, v↺ₕ₋₁ = multilinear evalutions  s.t. fⱼ(u) = vⱼ, and gⱼ(u) = f↺ⱼ(u) = v↺ⱼ
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
 * The verifier is able to computed the simulated commitments to A₀₊(X) and A₀₋(X)
 * since they are linear-combinations of the commitments [fⱼ] and [gⱼ].
 */
namespace bb {
template <typename Curve>
template <typename Transcript>
std::vector<typename GeminiProver_<Curve>::Claim> GeminiProver_<Curve>::prove(
    size_t circuit_size,
    PolynomialBatcher& polynomial_batcher,
    std::span<Fr> multilinear_challenge,
    const CommitmentKey<Curve>& commitment_key,
    const std::shared_ptr<Transcript>& transcript,
    bool has_zk)
{
    // To achieve fixed proof size in Ultra and Mega, the multilinear opening challenge is be padded to a fixed size.
    const size_t virtual_log_n = multilinear_challenge.size();
    const size_t log_n = numeric::get_msb(circuit_size);

    auto gem_t0 = std::chrono::steady_clock::now();
    // Get the batching challenge
    const Fr rho = transcript->template get_challenge<Fr>("rho");

    Polynomial A_0 = polynomial_batcher.compute_batched(rho);
    auto gem_t1 = std::chrono::steady_clock::now();

    // Construct the d-1 Gemini foldings of A₀(X)
    std::vector<Polynomial> fold_polynomials = compute_fold_polynomials(log_n, multilinear_challenge, A_0, has_zk);
    auto gem_t2 = std::chrono::steady_clock::now();

    // Commit fold polynomials. Large ones use GPU individually; small ones are batched
    // into a single CPU batch_multi_scalar_mul to avoid per-dispatch overhead.
    // Fold polynomials halve in size each round (2^21, 2^20, ..., 2^1, 1).
    {
        BB_BENCH_NAME("Gemini::fold_commits");
        constexpr size_t GPU_FOLD_THRESHOLD = 1 << 18; // 256K: below this, batch CPU MSM is faster

        // Partition into large (GPU) and small (CPU batch) groups
        std::vector<typename Curve::AffineElement> large_commitments; // indexed by position in fold_polynomials
        std::vector<size_t> large_indices;
        std::vector<std::span<const typename Curve::AffineElement>> small_points_spans;
        std::vector<std::span<Fr>> small_scalar_spans;
        std::vector<size_t> small_indices;

        auto point_table = commitment_key.get_monomial_points();
        for (size_t l = 0; l < virtual_log_n - 1; l++) {
            if (fold_polynomials[l].size() >= GPU_FOLD_THRESHOLD) {
                large_indices.push_back(l);
            } else if (fold_polynomials[l].size() > 0) {
                small_points_spans.emplace_back(point_table.subspan(
                    fold_polynomials[l].start_index(), fold_polynomials[l].size()));
                small_scalar_spans.emplace_back(fold_polynomials[l].coeffs());
                small_indices.push_back(l);
            }
        }

        // Launch CPU batch MSM asynchronously so it overlaps with GPU fold commits.
        // GPU and CPU are independent compute resources — no contention during Metal waitUntilCompleted.
        std::future<std::vector<typename Curve::AffineElement>> small_future;
        if (!small_scalar_spans.empty()) {
            small_future = std::async(std::launch::async, [&]() {
                return scalar_multiplication::MSM<Curve>::batch_multi_scalar_mul(
                    small_points_spans, small_scalar_spans, false);
            });
        }

        // Commit large fold polynomials individually on GPU (overlaps with CPU batch MSM above)
        for (size_t l : large_indices) {
            large_commitments.push_back(commitment_key.commit(fold_polynomials[l], /*prefer_gpu=*/true));
        }

        // Collect CPU batch MSM results
        std::vector<typename Curve::AffineElement> small_commitments;
        if (small_future.valid()) {
            auto batch_results = small_future.get();
            for (const auto& result : batch_results) {
                small_commitments.push_back(result);
            }
        }

        // Send commitments to transcript in the correct order
        size_t large_idx = 0;
        size_t small_idx = 0;
        for (size_t l = 0; l < virtual_log_n - 1; l++) {
            std::string label = "Gemini:FOLD_" + std::to_string(l + 1);
            if (large_idx < large_indices.size() && large_indices[large_idx] == l) {
                transcript->send_to_verifier(label, large_commitments[large_idx]);
                large_idx++;
            } else if (small_idx < small_indices.size() && small_indices[small_idx] == l) {
                transcript->send_to_verifier(label, small_commitments[small_idx]);
                small_idx++;
            } else {
                // Size 0 polynomial: commit to identity (point at infinity)
                transcript->send_to_verifier(label, Curve::AffineElement::infinity());
            }
        }
    }
    auto gem_t3 = std::chrono::steady_clock::now();
    const Fr r_challenge = transcript->template get_challenge<Fr>("Gemini:r");

    const bool gemini_challenge_in_small_subgroup = (has_zk) && (r_challenge.pow(Curve::SUBGROUP_SIZE) == Fr(1));

    // If Gemini evaluation challenge lands in the multiplicative subgroup used by SmallSubgroupIPA protocol, the
    // evaluations of prover polynomials at this challenge would leak witness data.
    // TODO(https://github.com/AztecProtocol/barretenberg/issues/1194). Handle edge cases in PCS
    if (gemini_challenge_in_small_subgroup) {
        throw_or_abort("Gemini evaluation challenge is in the SmallSubgroup.");
    }

    // Compute polynomials A₀₊(X) = F(X) + G(X)/r and A₀₋(X) = F(X) - G(X)/r
    std::pair<Polynomial, Polynomial> partial_eval_result;
    {
        BB_BENCH_NAME("Gemini::compute_partial_eval_batch");
        partial_eval_result = polynomial_batcher.compute_partially_evaluated_batch_polynomials(r_challenge);
    }
    auto& [A_0_pos, A_0_neg] = partial_eval_result;
    // Construct claims for the d + 1 univariate evaluations A₀₊(r), A₀₋(-r), and Foldₗ(−r^{2ˡ}), l = 1, ..., d-1
    std::vector<Claim> claims;
    {
        BB_BENCH_NAME("Gemini::construct_opening_claims");
        claims = construct_univariate_opening_claims(
            virtual_log_n, std::move(A_0_pos), std::move(A_0_neg), std::move(fold_polynomials), r_challenge);
    }

    auto gem_t4 = std::chrono::steady_clock::now();
    {
        auto gms = [](auto a, auto b) { return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count(); };
        vinfo("gemini breakdown: batch=", gms(gem_t0, gem_t1), "ms fold=", gms(gem_t1, gem_t2),
              "ms commits=", gms(gem_t2, gem_t3), "ms eval+claims=", gms(gem_t3, gem_t4), "ms");
    }
    for (size_t l = 1; l <= virtual_log_n; l++) {
        std::string label = "Gemini:a_" + std::to_string(l);
        transcript->send_to_verifier(label, claims[l].opening_pair.evaluation);
    }

    // If running Gemini for the Translator VM polynomials, A₀(r) = A₀₊(r) + P₊(rˢ) and A₀(-r) = A₀₋(-r) + P₋(rˢ)
    // where s is the size of the interleaved group assumed even. The prover sends P₊(rˢ) and P₋(rˢ) to the verifier
    // so it can reconstruct the evaluation of A₀(r) and A₀(-r) respectively
    // TODO(https://github.com/AztecProtocol/barretenberg/issues/1282)
    if (polynomial_batcher.has_interleaved()) {
        auto [P_pos, P_neg] = polynomial_batcher.compute_partially_evaluated_interleaved_polynomial(r_challenge);
        Fr r_pow = r_challenge.pow(polynomial_batcher.get_group_size());
        Fr P_pos_eval = P_pos.evaluate(r_pow);
        Fr P_neg_eval = P_neg.evaluate(r_pow);
        claims.emplace_back(Claim{ std::move(P_pos), { r_pow, P_pos_eval } });
        transcript->send_to_verifier("Gemini:P_pos", P_pos_eval);
        claims.emplace_back(Claim{ std::move(P_neg), { r_pow, P_neg_eval } });
        transcript->send_to_verifier("Gemini:P_neg", P_neg_eval);
    }

    return claims;
};

/**
 * @brief Computes d-1 fold polynomials Fold_i, i = 1, ..., d-1
 *
 * @param multilinear_challenge multilinear opening point 'u'
 * @param A_0 = F(X) + G↺(X) = F(X) + G(X)/X
 * @return std::vector<Polynomial>
 */
template <typename Curve>
std::vector<typename GeminiProver_<Curve>::Polynomial> GeminiProver_<Curve>::compute_fold_polynomials(
    const size_t log_n, std::span<const Fr> multilinear_challenge, const Polynomial& A_0, const bool& has_zk)
{
    BB_BENCH_NAME("Gemini::compute_fold_polynomials");
    const size_t virtual_log_n = multilinear_challenge.size();

    // Cost per iteration: 1 subtraction + 1 multiplication + 1 addition
    constexpr size_t fold_iteration_cost =
        (2 * thread_heuristics::FF_ADDITION_COST) + thread_heuristics::FF_MULTIPLICATION_COST;

    // Reserve and allocate space for m-1 Fold polynomials, the foldings of the full batched polynomial A₀
    std::vector<Polynomial> fold_polynomials;
    fold_polynomials.reserve(virtual_log_n - 1);
    for (size_t l = 0; l < log_n - 1; ++l) {
        // size of the previous polynomial/2
        const size_t n_l = 1 << (log_n - l - 1);

        // A_l_fold = Aₗ₊₁(X) = (1-uₗ)⋅even(Aₗ)(X) + uₗ⋅odd(Aₗ)(X)
        // DontZeroMemory: every element is overwritten by the fold computation below
        fold_polynomials.emplace_back(Polynomial(n_l, Polynomial::DontZeroMemory::FLAG));
    }

    // A_l = Aₗ(X) is the polynomial being folded
    // in the first iteration, we take the batched polynomial
    // in the next iteration, it is the previously folded one
    auto A_l = A_0.data();
    for (size_t l = 0; l < log_n - 1; ++l) {
        // size of the previous polynomial/2
        const size_t n_l = 1 << (log_n - l - 1);

        // Opening point is the same for all
        const Fr u_l = multilinear_challenge[l];

        // A_l_fold = Aₗ₊₁(X) = (1-uₗ)⋅even(Aₗ)(X) + uₗ⋅odd(Aₗ)(X)
        auto A_l_fold = fold_polynomials[l].data();

        parallel_for_heuristic(
            n_l,
            [&](size_t j) {
                // fold(Aₗ)[j] = (1-uₗ)⋅even(Aₗ)[j] + uₗ⋅odd(Aₗ)[j]
                //            = (1-uₗ)⋅Aₗ[2j]      + uₗ⋅Aₗ[2j+1]
                //            = Aₗ₊₁[j]
                A_l_fold[j] = A_l[j << 1] + u_l * (A_l[(j << 1) + 1] - A_l[j << 1]);
            },
            fold_iteration_cost);
        // set Aₗ₊₁ = Aₗ for the next iteration
        A_l = A_l_fold;
    }

    // Perform virtual rounds.
    // After the first `log_n - 1` rounds, the prover's `fold` univariates stabilize. With ZK, the verifier multiplies
    // the evaluations by 0, otherwise, when `virtual_log_n > log_n`, the prover honestly computes and sends the
    // constant folds.
    const auto& last = fold_polynomials.back();
    const Fr u_last = multilinear_challenge[log_n - 1];
    const Fr final_eval = last.at(0) + u_last * (last.at(1) - last.at(0));
    Polynomial const_fold(1);
    // Temporary fix: when we're running a zk proof, the verifier uses a `padding_indicator_array`. So the evals in
    // rounds past `log_n - 1` will be ignored. Hence the prover also needs to ignore them, otherwise Shplonk will fail.
    const_fold.at(0) = final_eval * Fr(static_cast<int>(!has_zk));
    fold_polynomials.emplace_back(const_fold);

    // FOLD_{log_n+1}, ..., FOLD_{d_v-1}
    Fr tail = Fr(1);
    for (size_t k = log_n; k < virtual_log_n - 1; ++k) {
        tail *= (Fr(1) - multilinear_challenge[k]); // multiply by (1 - u_k)
        Polynomial next_const(1);
        next_const.at(0) = final_eval * tail * Fr(static_cast<int>(!has_zk));
        fold_polynomials.emplace_back(next_const);
    }

    return fold_polynomials;
};

/**

 *
 * @param mle_opening_point u = (u₀,...,uₘ₋₁) is the MLE opening point
 * @param fold_polynomials vector of polynomials whose first two elements are F(X) = ∑ⱼ ρʲfⱼ(X)
 * and G(X) = ∑ⱼ ρᵏ⁺ʲ gⱼ(X), and the next d-1 elements are Fold_i, i = 1, ..., d-1.
 * @param r_challenge univariate opening challenge
 */

/**
 * @brief Computes/aggragates d+1 univariate polynomial opening claims of the form {polynomial, (challenge, evaluation)}
 *
 * @details The d+1 evaluations are A₀₊(r), A₀₋(-r), and Aₗ(−r^{2ˡ}) for l = 1, ..., d-1, where the Aₗ are the fold
 * polynomials.
 *
 * @param A_0_pos A₀₊
 * @param A_0_neg A₀₋
 * @param fold_polynomials Aₗ, l = 1, ..., d-1
 * @param r_challenge
 * @return std::vector<typename GeminiProver_<Curve>::Claim> d+1 univariate opening claims
 */
template <typename Curve>
std::vector<typename GeminiProver_<Curve>::Claim> GeminiProver_<Curve>::construct_univariate_opening_claims(
    const size_t log_n,
    Polynomial&& A_0_pos,
    Polynomial&& A_0_neg,
    std::vector<Polynomial>&& fold_polynomials,
    const Fr& r_challenge)
{
    std::vector<Claim> claims;

    // Evaluate A₀₊(r) and A₀₋(-r) in parallel — both are O(2^log_n) Horner evaluations
    // and are fully independent.
    auto neg_r = -r_challenge;
    auto fut_neg = std::async(std::launch::async, [&]() { return A_0_neg.evaluate(neg_r); });
    Fr a_0_pos = A_0_pos.evaluate(r_challenge);
    Fr a_0_neg = fut_neg.get();
    claims.emplace_back(Claim{ std::move(A_0_pos), { r_challenge, a_0_pos } });
    claims.emplace_back(Claim{ std::move(A_0_neg), { neg_r, a_0_neg } });

    // Compute univariate opening queries rₗ = r^{2ˡ} for l = 0, 1, ..., m-1
    std::vector<Fr> r_squares = gemini::powers_of_evaluation_challenge(r_challenge, log_n);

    // Each fold polynomial Aₗ has to be opened at −r^{2ˡ} and r^{2ˡ}. To avoid storing two copies of Aₗ for l = 1,...,
    // m-1, we use a flag that is processed by ShplonkProver.
    const bool gemini_fold = true;

    // Compute the remaining m opening pairs {−r^{2ˡ}, Aₗ(−r^{2ˡ})}, l = 1, ..., m-1.
    // Also precompute positive evaluations Fold_l(r^{2^l}) for Shplonk.
    // Large folds: parallelize neg and pos evaluations on separate threads.
    // Small folds: evaluate sequentially to avoid parallel_for barrier overhead.
    constexpr size_t LARGE_FOLD_THRESHOLD = 1 << 16;
    for (size_t l = 0; l < log_n - 1; ++l) {
        Fr neg_eval;
        Fr pos_eval;
        if (fold_polynomials[l].size() >= LARGE_FOLD_THRESHOLD) {
            auto fut_pos = std::async(std::launch::async, [&, l]() {
                return fold_polynomials[l].evaluate(r_squares[l + 1]);
            });
            neg_eval = fold_polynomials[l].evaluate(-r_squares[l + 1]);
            pos_eval = fut_pos.get();
        } else {
            // Small fold: sequential Horner evaluation avoids parallel_for overhead.
            // polynomial_arithmetic::evaluate uses parallel_for internally, so call data() directly.
            const Fr* data = fold_polynomials[l].data();
            const size_t n = fold_polynomials[l].size();
            const Fr neg_point = -r_squares[l + 1];
            const Fr pos_point = r_squares[l + 1];
            // Horner's method: evaluate at both points in a single pass over the data
            Fr neg_acc = data[n - 1];
            Fr pos_acc = data[n - 1];
            for (size_t i = n - 1; i > 0; --i) {
                neg_acc = neg_acc * neg_point + data[i - 1];
                pos_acc = pos_acc * pos_point + data[i - 1];
            }
            neg_eval = neg_acc;
            pos_eval = pos_acc;
        }
        Claim claim{ std::move(fold_polynomials[l]),
                     { -r_squares[l + 1], neg_eval },
                     gemini_fold,
                     pos_eval };
        claims.emplace_back(std::move(claim));
    }

    return claims;
};

} // namespace bb

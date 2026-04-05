// === AUDIT STATUS ===
// internal:    { status: Planned, auditors: [Sergei], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================

#pragma once

/**
 * @brief Provides interfaces for different 'CommitmentKey' classes.
 */

#include "barretenberg/common/bb_bench.hpp"
#include "barretenberg/constants.hpp"
#include "barretenberg/common/ref_span.hpp"
#include "barretenberg/ecc/scalar_multiplication/scalar_multiplication.hpp"
#include "barretenberg/ecc/scalar_multiplication/metal/metal_msm.hpp"
#include "barretenberg/polynomials/backing_memory.hpp"
#include "barretenberg/polynomials/polynomial.hpp"
#include "barretenberg/srs/factories/crs_factory.hpp"
#include "barretenberg/srs/global_crs.hpp"

#include <cstddef>
#include <cstdlib>
#include <limits>
#include <memory>
#include <mutex>
#include <string_view>
#include <unordered_map>

namespace bb {
/**
 * @brief CommitmentKey object over a pairing group 𝔾₁.
 *
 * @details Commitments are computed as C = [p(x)] = ∑ᵢ aᵢ⋅Gᵢ where Gᵢ is the i-th element of the SRS. For BN254,
 * the SRS is given as a list of 𝔾₁ points { [xʲ]₁ }ⱼ where 'x' is unknown. For Grumpkin, they are random points. The
 * SRS stored in the commitment key is after applying the pippenger_point_table thus being double the size of what is
 * loaded from path.
 */
template <class Curve> class CommitmentKey {

    using Fr = typename Curve::ScalarField;
    using Commitment = typename Curve::AffineElement;

  protected:
    std::shared_ptr<srs::factories::Crs<Curve>> srs;

  public:
    size_t srs_size;

    CommitmentKey() = default;
    CommitmentKey(const CommitmentKey&) = default;
    CommitmentKey(CommitmentKey&&) noexcept = default;
    CommitmentKey& operator=(const CommitmentKey&) = default;
    CommitmentKey& operator=(CommitmentKey&&) noexcept = default;
    ~CommitmentKey() = default;

    /**
     * @brief Construct a new Kate Commitment Key object from existing SRS
     *
     * @param num_points Number of points needed for commitments
     */
    CommitmentKey(const size_t num_points)
        : srs(srs::get_crs_factory<Curve>()->get_crs(num_points))
        , srs_size(num_points)
    {
#if BB_METAL_MSM_AVAILABLE
        // Prewarm the Metal GPU: initialize pipeline states, allocate buffers, and cache SRS points.
        // This overlaps ~150ms of Metal startup with subsequent CPU work.
        if constexpr (std::is_same_v<Curve, curve::BN254>) {
            scalar_multiplication::metal::metal_prewarm(num_points, get_monomial_points().data());
        }
#endif
    }
    /**
     * @brief Get or create a cached CommitmentKey for the given SRS size.
     *
     * @details Within a persistent bb-avm process, the same circuit types are proved
     * repeatedly (e.g. 20+ PARITY_BASE proofs per epoch). Each proof previously
     * constructed a fresh CommitmentKey, triggering SRS fetch + Metal GPU prewarm
     * (~150-300ms). This cache eliminates that overhead for all but the first proof
     * of each circuit size.
     *
     * The cache grows monotonically (never evicts) because there are only ~6 distinct
     * circuit sizes per epoch and each CK holds a shared_ptr to the SRS (minimal memory).
     *
     * Thread-safe: protected by mutex since multiple proving threads may request CKs
     * concurrently in multi-agent configurations.
     */
    static CommitmentKey get_or_create(size_t num_points)
    {
        static std::mutex cache_mutex;
        static std::unordered_map<size_t, CommitmentKey> cache;

        std::lock_guard<std::mutex> lock(cache_mutex);
        auto it = cache.find(num_points);
        if (it != cache.end()) {
            return it->second;
        }
        cache.emplace(num_points, CommitmentKey(num_points));
        return cache.at(num_points);
    }

    /**
     * @brief Checks the commitment key is properly initialized.
     *
     * @return bool
     */
    bool initialized() const { return srs != nullptr; }

    std::span<Commitment> get_monomial_points() const { return srs->get_monomial_points(); }
    size_t get_monomial_size() const { return srs->get_monomial_size(); }

    /**
     * @brief Uses the ProverSRS to create a commitment to p(X)
     *
     * @param polynomial a univariate polynomial p(X) = ∑ᵢ aᵢ⋅Xⁱ
     * @param prefer_gpu whether to prefer GPU for MSM computation
     * @param active_data_end hint for sparse masked polynomials: if non-zero, positions
     *        [active_data_end, end - NUM_MASKED_ROWS) are known to be zero. The MSM is split
     *        into a main region [start, active_data_end) and a tiny tail [end - NUM_MASKED_ROWS, end),
     *        skipping the zero gap. This saves ~46% GPU MSM work for ZK-masked witness polynomials.
     * @return Commitment computed as C = [p(x)] = ∑ᵢ aᵢ⋅Gᵢ
     */
    Commitment commit(PolynomialSpan<const Fr> polynomial,
                      bool prefer_gpu = true,
                      size_t active_data_end = 0) const
    {
        BB_BENCH_NAME("CommitmentKey::commit");
        std::span<const Commitment> point_table = get_monomial_points();
        size_t consumed_srs = polynomial.start_index + polynomial.size();
        if (consumed_srs > get_monomial_size()) {
            throw_or_abort(format("Attempting to commit to a polynomial that needs ",
                                  consumed_srs,
                                  " points with an SRS of size ",
                                  get_monomial_size()));
        }

        // Sparse masked polynomial optimization: split MSM to skip zero gap.
        // For ZK-masked witness polys, only [start, active_data_end) and [end-3, end) are non-zero.
        constexpr size_t MIN_SPARSE_SAVINGS = 1 << 15; // At least 32K zeros to be worth splitting
        if (active_data_end > polynomial.start_index &&
            active_data_end + NUM_MASKED_ROWS < polynomial.end_index() &&
            (polynomial.end_index() - NUM_MASKED_ROWS - active_data_end) >= MIN_SPARSE_SAVINGS) {
            // Main region: [start_index, active_data_end)
            size_t main_size = active_data_end - polynomial.start_index;
            PolynomialSpan<const Fr> main_span(polynomial.start_index,
                                               polynomial.span.subspan(0, main_size));
            auto main_commit = commit(main_span, prefer_gpu, 0);

            // Tail region: [end - NUM_MASKED_ROWS, end) — only 3 elements, always CPU
            size_t tail_start_idx = polynomial.end_index() - NUM_MASKED_ROWS;
            size_t tail_offset = tail_start_idx - polynomial.start_index;
            PolynomialSpan<const Fr> tail_span(tail_start_idx,
                                               polynomial.span.subspan(tail_offset, NUM_MASKED_ROWS));
            auto tail_commit =
                scalar_multiplication::pippenger_unsafe<Curve>(tail_span, point_table);

            // Combine: C = C_main + C_tail (EC point addition)
            if (main_commit.is_point_at_infinity()) {
                return tail_commit;
            }
            if (tail_commit.is_point_at_infinity()) {
                return main_commit;
            }
            typename Curve::Element sum =
                typename Curve::Element(main_commit) + typename Curve::Element(tail_commit);
            return sum;
        }

#if BB_METAL_MSM_AVAILABLE
        if constexpr (std::is_same_v<Curve, curve::BN254>) {
            if (prefer_gpu && !slow_low_memory &&
                polynomial.size() >= scalar_multiplication::metal::METAL_MSM_THRESHOLD &&
                polynomial.size() <= scalar_multiplication::metal::METAL_MSM_MAX_SIZE &&
                scalar_multiplication::metal::metal_available()) {
                auto gpu_result = scalar_multiplication::metal::metal_pippenger(
                    polynomial,
                    point_table);
                if (!gpu_result.is_point_at_infinity()) {
                    return gpu_result;
                }
                // GPU failed (e.g. bucket imbalance), fall through to CPU
            }
        }
#endif
        return scalar_multiplication::pippenger_unsafe<Curve>(polynomial, point_table);
    };
    /**
     * @brief Batch commitment to multiple polynomials
     * @details Uses batch_multi_scalar_mul for more efficient processing when committing to multiple polynomials.
     *          The input polynomials are not const because batch_mul modifies them and then restores them back.
     *
     * @param polynomials vector of polynomial spans to commit to
     * @return std::vector<Commitment> vector of commitments, one for each polynomial
     */
    std::vector<Commitment> batch_commit(RefSpan<Polynomial<Fr>> polynomials,
                                         size_t max_batch_size = std::numeric_limits<size_t>::max()) const
    {
        BB_BENCH_NAME("CommitmentKey::batch_commit");

#if BB_METAL_MSM_AVAILABLE
        // When GPU is available, commit each polynomial individually via the GPU path.
        // This avoids the CPU scalar_transform + Pippenger overhead of batch_multi_scalar_mul.
        if constexpr (std::is_same_v<Curve, curve::BN254>) {
            if (!slow_low_memory && scalar_multiplication::metal::metal_available()) {
                std::vector<Commitment> commitments;
                commitments.reserve(polynomials.size());
                for (auto& polynomial : polynomials) {
                    commitments.emplace_back(commit(polynomial, /*prefer_gpu=*/true));
                }
                return commitments;
            }
        }
#endif

        // CPU fallback: batch MSM path
        std::vector<Commitment> commitments;

        for (size_t i = 0; i < polynomials.size();) {
            // Note: have to be careful how we compute this to not overlow e.g. max_batch_size + 1 would
            size_t batch_size = std::min(max_batch_size, polynomials.size() - i);
            size_t batch_end = i + batch_size;

            // Prepare spans for batch MSM
            std::vector<std::span<const Commitment>> points_spans;
            std::vector<std::span<Fr>> scalar_spans;

            for (auto& polynomial : polynomials.subspan(i, batch_end - i)) {
                std::span<const Commitment> point_table = get_monomial_points().subspan(polynomial.start_index());
                size_t consumed_srs = polynomial.start_index() + polynomial.size();
                if (consumed_srs > get_monomial_size()) {
                    throw_or_abort(format("Attempting to commit to a polynomial that needs ",
                                          consumed_srs,
                                          " points with an SRS of size ",
                                          get_monomial_size()));
                }
                scalar_spans.emplace_back(polynomial.coeffs());
                points_spans.emplace_back(point_table);
            }

            // Perform batch MSM
            auto results = scalar_multiplication::MSM<Curve>::batch_multi_scalar_mul(points_spans, scalar_spans, false);
            for (const auto& result : results) {
                commitments.emplace_back(result);
            }
            i += batch_size;
        }
        return commitments;
    };

    // helper builder struct for constructing a batch to commit at once
    struct CommitBatch {
        CommitmentKey* key;
        RefVector<Polynomial<Fr>> wires;
        std::vector<std::string> labels;
        std::vector<size_t> sparse_active_ends; // per-poly hint for sparse masked polys (0 = not sparse)

        std::vector<Commitment> commit_and_send_to_verifier(auto transcript,
                                                            size_t max_batch_size = std::numeric_limits<size_t>::max())
        {
            // If any polynomial has a sparse hint, use individual commits with the hint.
            // Otherwise, use the batch commit path.
            bool has_sparse = false;
            for (size_t active_end : sparse_active_ends) {
                if (active_end > 0) {
                    has_sparse = true;
                    break;
                }
            }

            std::vector<Commitment> commitments;
            if (has_sparse) {
                commitments.reserve(wires.size());
                for (size_t i = 0; i < wires.size(); ++i) {
                    commitments.push_back(key->commit(wires[i], true, sparse_active_ends[i]));
                }
            } else {
                commitments = key->batch_commit(wires, max_batch_size);
            }

            for (size_t i = 0; i < commitments.size(); ++i) {
                transcript->send_to_verifier(labels[i], commitments[i]);
            }

            return commitments;
        }

        void add_to_batch(Polynomial<Fr>& poly, const std::string& label, bool mask,
                          size_t active_data_end = 0)
        {
            if (mask) {
                poly.mask();
            }
            wires.push_back(poly);
            labels.push_back(label);
            sparse_active_ends.push_back(mask ? active_data_end : 0);
        }

        // Commit without sending to transcript — for async overlap patterns
        std::vector<Commitment> commit_without_send(size_t max_batch_size = std::numeric_limits<size_t>::max())
        {
            bool has_sparse = false;
            for (size_t active_end : sparse_active_ends) {
                if (active_end > 0) {
                    has_sparse = true;
                    break;
                }
            }

            std::vector<Commitment> commitments;
            if (has_sparse) {
                commitments.reserve(wires.size());
                for (size_t i = 0; i < wires.size(); ++i) {
                    commitments.push_back(key->commit(wires[i], true, sparse_active_ends[i]));
                }
            } else {
                commitments = key->batch_commit(wires, max_batch_size);
            }
            return commitments;
        }

        // Send pre-computed commitments to transcript
        void send_commitments_to_verifier(auto transcript, const std::vector<Commitment>& commitments)
        {
            for (size_t i = 0; i < commitments.size(); ++i) {
                transcript->send_to_verifier(labels[i], commitments[i]);
            }
        }
    };

    CommitBatch start_batch() { return CommitBatch{ this, {}, {}, {} }; }
};

} // namespace bb

// === AUDIT STATUS ===
// internal:    { status: Complete, auditors: [Sergei], commit: }
// external_1:  { status: not started, auditors: [], commit: }
// external_2:  { status: not started, auditors: [], commit: }
// =====================
#pragma once

#include "barretenberg/common/thread.hpp"
#include "barretenberg/common/zip_view.hpp"
#include "barretenberg/polynomials/polynomial.hpp"
#ifndef __wasm__
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace bb {

/**
 * @brief A container for storing the partially evaluated multivariates produced by sumcheck.
 * @details This base class provides the common implementation for all flavors. Each flavor
 * should define a type alias like:
 *   using PartiallyEvaluatedMultivariates = PartiallyEvaluatedMultivariatesBase<AllEntities<Polynomial>,
 * ProverPolynomials, Polynomial>;
 *
 * @tparam AllEntitiesBase The AllEntities<Polynomial> type from the flavor
 * @tparam ProverPolynomialsType The ProverPolynomials type from the flavor
 * @tparam Polynomial The Polynomial type from the flavor
 */
template <typename AllEntitiesBase, typename ProverPolynomialsType, typename Polynomial>
class PartiallyEvaluatedMultivariatesBase : public AllEntitiesBase {
  public:
    using Fr = typename Polynomial::FF;

    // Default constructor: all polynomial members are default-initialized (empty).
    // Used by streaming sumcheck to incrementally populate polynomials.
    PartiallyEvaluatedMultivariatesBase() = default;

    /**
     * @brief Construct from full polynomials, allocating based on their actual sizes.
     * @details Uses pooled allocation: a single contiguous block is allocated for all destination
     * polynomials, then carved into views. This avoids 41 separate mmap allocations and reduces
     * page fault contention from parallel writes in partially_evaluate.
     */
    PartiallyEvaluatedMultivariatesBase(const ProverPolynomialsType& full_polynomials, size_t circuit_size)
    {
        auto full_all = full_polynomials.get_all();
        auto dest_all = this->get_all();

        // Calculate per-polynomial sizes and total
        std::vector<size_t> sizes;
        sizes.reserve(full_all.size());
        size_t total_elements = 0;
        for (auto& full_poly : full_all) {
            size_t desired = (full_poly.end_index() / 2) + (full_poly.end_index() % 2);
            sizes.push_back(desired);
            total_elements += desired;
        }

        // Single allocation for all destination polynomials.
        // The mmap pages are faulted once (by the OS zero-fill) rather than scattered across 41 separate regions.
        auto pool = BackingMemory<Fr>::allocate(total_elements);
        pool_base_ = reinterpret_cast<char*>(pool.raw_data);
        pool_bytes_ = total_elements * sizeof(Fr);

        // Create each polynomial as a view into the pool using aliasing shared_ptr
        size_t offset = 0;
        size_t half_circuit = circuit_size / 2;
        size_t i = 0;
        for (auto [poly, full_poly] : zip_view(dest_all, full_all)) {
            size_t desired = sizes[i++];
            BackingMemory<Fr> slice;
            // Aliasing constructor: shares ownership with pool but points to offset location
            slice.aligned_memory = std::shared_ptr<Fr[]>(pool.aligned_memory, pool.raw_data + offset);
            slice.raw_data = pool.raw_data + offset;
            slice.zero_initialized = pool.zero_initialized;
            poly = Polynomial(std::move(slice), desired, half_circuit);
            offset += desired;
        }
    }

    /**
     * @brief Sequentially pre-fault mmap pages so partially_evaluate doesn't pay page faults.
     * @details Designed to run on a SINGLE background thread while compute_univariate runs on
     * the main thread pool. Sequential access avoids kernel VM lock contention that occurs when
     * multiple threads page-fault simultaneously.
     */
    void prefault_pages()
    {
        if (pool_base_ == nullptr || pool_bytes_ == 0) {
            return;
        }
#ifndef __wasm__
        // Try mlock/munlock first: the kernel faults in all pages in a single bulk operation,
        // avoiding per-page soft fault overhead. Falls back to sequential write-fault if mlock fails
        // (e.g., insufficient locked-memory limit).
        if (mlock(pool_base_, pool_bytes_) == 0) {
            munlock(pool_base_, pool_bytes_);
            return;
        }
#endif
        // Fallback: sequential write-fault with system page size stride.
        // On macOS, mmap(MAP_ANONYMOUS) maps to a shared zero page; first WRITE triggers COW.
        volatile char* base = pool_base_;
        const size_t page_size = static_cast<size_t>(sysconf(_SC_PAGESIZE));
        for (size_t off = 0; off < pool_bytes_; off += page_size) {
            base[off] = 0;
        }
    }

  private:
    char* pool_base_ = nullptr;
    size_t pool_bytes_ = 0;
};

} // namespace bb

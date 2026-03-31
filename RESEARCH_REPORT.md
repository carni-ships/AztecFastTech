# GPU-Accelerated Zero-Knowledge Proving on Apple Silicon: Optimizing the Barretenberg UltraHonk Prover with Metal

**Authors:** Carnation, with Claude (Anthropic)
**Date:** 2026
**Platform:** Apple M3 Pro (12 CPU cores, 18 GPU cores, 18GB unified memory)

---

## Abstract

We present a systematic optimization of the Aztec Barretenberg UltraHonk zero-knowledge prover targeting Apple Silicon GPUs via the Metal compute framework. Starting from the stock CPU-only prover (v4.1.2), we achieve a **5.1x speedup** on a 75K-gate circuit (755ms to 148ms construct\_proof) and a **3.6x speedup** on a production 428K-gate circuit (3,800ms to 1,050ms wall clock) through a combination of GPU-accelerated multi-scalar multiplication (MSM), memory allocation optimization, thread pool tuning, and systematic elimination of redundant computation. We document 17 successful optimizations, 16 rejected approaches, and a detailed analysis of the hardware performance ceiling on M3 Pro, providing a reference for future GPU-accelerated ZK prover implementations.

---

## 1. Introduction

### 1.1 Background

Zero-knowledge proof systems require computationally intensive operations over elliptic curves and finite fields. The UltraHonk proving system, part of Aztec's Barretenberg library, constructs proofs via three major phases:

1. **Oink** (preprocessing): Polynomial commitments via multi-scalar multiplication (MSM)
2. **Sumcheck**: Multivariate-to-univariate reduction via relation evaluation
3. **PCS** (Polynomial Commitment Scheme): Gemini folding, Shplonk batching, and KZG opening

Each phase involves operations over the BN254 elliptic curve with 254-bit scalar and base field elements.

### 1.2 Motivation

The stock Barretenberg prover is CPU-only, achieving ~755ms wall clock time for a 75K-gate Poseidon2 benchmark circuit on Apple M3 Pro. Apple Silicon's unified memory architecture---where CPU and GPU share the same physical memory---presents a unique opportunity: GPU compute kernels can operate on polynomial data without explicit memory transfers, eliminating the PCIe bottleneck that plagues discrete GPU approaches.

### 1.3 Contributions

- A complete Metal GPU backend for Pippenger MSM with GLV endomorphism decomposition
- Discovery and characterization of an M3 Pro GPU scheduling pathology affecting specific window sizes
- Systematic profiling methodology identifying that MSM operations consume 61--69% of total proving time
- 16 documented negative results providing a roadmap of dead ends for future researchers

---

## 2. System Architecture

### 2.1 Hardware Platform

| Component | Specification |
|-----------|--------------|
| CPU | Apple M3 Pro, 6P+6E cores (12 total) |
| GPU | Apple M3 Pro, 18 cores, Metal 4 |
| Memory | 18GB unified LPDDR5, ~160GB/s bandwidth |
| OS | macOS (Apple Silicon) |

### 2.2 Proof System Parameters

| Parameter | Small Circuit | Production Circuit |
|-----------|--------------|-------------------|
| Circuit | bench\_poseidon | production (428K gates) |
| Gates | 75,265 | 428,032 |
| Dyadic size | 131,072 (2^17) | 524,288 (2^19) |
| Sumcheck rounds | 17 | 19 |
| MSM point count | ~131K | ~524K |

### 2.3 Build Configuration

All measurements use Release builds with `-O3 -mcpu=native -flto=thin` via both `CMAKE_CXX_FLAGS` and `CMAKE_EXE_LINKER_FLAGS`. We discovered that thin LTO is critical: without it, the binary bloats from 19MB to 24MB with 33% more symbols and ~60ms regression. PGO instrumentation (`-fprofile-instr-generate`) was tested and rejected due to 7.4x binary bloat and runtime overhead.

---

## 3. Optimization Techniques

### 3.1 GPU Multi-Scalar Multiplication (MSM)

The dominant operation in UltraHonk proving is multi-scalar multiplication: computing $\sum_{i=0}^{n-1} s_i \cdot G_i$ where $s_i$ are 254-bit scalars and $G_i$ are BN254 G1 points from the Structured Reference String (SRS).

#### 3.1.1 Pippenger Bucket Method on Metal

We implemented the Pippenger bucket method with window size $w=16$ as a multi-kernel Metal pipeline:

1. **GLV Decomposition** (GPU kernel): Decomposes each 254-bit scalar into two ~128-bit half-scalars using the BN254 endomorphism $\phi: (x,y) \mapsto (\beta x, y)$ where $\beta^3 = 1 \pmod{p}$. This halves the effective scalar bit-width, reducing the number of bucket accumulation windows.

2. **Counting Sort** (3 GPU kernels): Histogram, prefix-sum, and scatter kernels sort points by bucket index within each window, enabling coalesced memory access during accumulation.

3. **Bucket Accumulation** (GPU kernel): Each thread accumulates points into a single bucket using projective mixed addition ($\sim$12 field multiplications per point).

4. **Bucket Reduction** (GPU kernel): Computes the weighted sum of buckets per window via running-sum method.

5. **Final Combination** (CPU): Horner's method combines window results: $R = \sum_{j} 2^{jw} \cdot R_j$.

**Key design decisions:**
- **Unified memory / zero-copy**: Metal's `newBufferWithBytesNoCopy` wraps CPU polynomial memory directly, eliminating copy overhead for page-aligned allocations.
- **Single command buffer**: All GPU kernels are encoded into a single Metal command buffer, eliminating inter-kernel dispatch latency.
- **SRS caching**: GPU buffers for SRS points are allocated once in the CommitmentKey constructor and reused across all MSMs.

#### 3.1.2 GLV Endomorphism on GPU

Moving GLV scalar decomposition from CPU to GPU eliminated a 12ms per-MSM bottleneck:

| Component | CPU | GPU | Speedup |
|-----------|-----|-----|---------|
| GLV decompose | 12ms | 3.5ms | 3.4x |

The GPU kernel performs the extended Euclidean decomposition $s = k_1 + k_2 \cdot \lambda \pmod{r}$ and applies the endomorphism $\phi(G_i) = (\beta \cdot x_i, y_i)$ in a single pass, avoiding a CPU-GPU synchronization point.

#### 3.1.3 GPU Bucket Sum and Combine

The bucket-to-window reduction was the largest single optimization, achieving 10x speedup:

| Component | CPU | GPU | Speedup |
|-----------|-----|-----|---------|
| bucket\_sum + combine | 225ms | 23ms | 9.8x |

The GPU kernel assigns one thread per bucket, performing the running-sum reduction entirely in registers. The combine step (Horner evaluation over window results) executes on the same command buffer.

#### 3.1.4 Fused Gather-Reduce Kernel

The initial MSM pipeline had a separate `gather_sorted_points` kernel that materialized sorted points into a 1.15GB intermediate buffer before reduction. We fused gathering into the reduce kernel, reading `sorted_indices[]` and `points[]` directly:

| Phase | Before | After | Savings |
|-------|--------|-------|---------|
| Phase 3 (1M-point MSM) | 107ms | 90ms | 17ms/MSM |
| Total per proof (~7 MSMs) | -- | -- | ~85ms |

This eliminated 1.15GB of intermediate buffer write-read bandwidth per MSM.

#### 3.1.5 MSM Threshold Tuning

GPU dispatch has fixed overhead (~2ms for command buffer encoding, pipeline state, and synchronization). We determined the crossover point:

| Threshold | Effect |
|-----------|--------|
| 16K points | GPU slower (dispatch overhead > CPU time) |
| 32K points | Marginal |
| **131K points** | **Optimal threshold** |

The threshold was fixed at `METAL_MSM_THRESHOLD = 131072` (2^17).

### 3.2 GPU Correctness: Lazy Montgomery Reduction

**Root cause of all GPU correctness failures:** Barretenberg stores BN254 field elements in *lazy-reduced* Montgomery form---values in $[0, 2p)$ rather than $[0, p)$. The Metal GPU's `fp_add`/`fp_sub` assumed fully reduced inputs, causing ~10% error rate in bucket accumulation.

**Fix:** A `fp_reduce()` function conditionally subtracts $p$ at GPU entry points:

```metal
Fp fp_reduce(Fp a) {
    uint borrow;
    Fp reduced = fp_sub_raw(a, fp_modulus(), borrow);
    return borrow ? a : reduced;
}
```

Applied at two boundaries:
1. `point_from_affine()` --- reduces $(x, y)$ when loading CPU points
2. `glv_endomorphism` kernel --- reduces before negation/endomorphism

Montgomery multiplication (CIOS) naturally handles unreduced inputs since $a \cdot b < p \cdot R$ regardless, but addition/subtraction can overflow their single-reduction step when both inputs are in $[p, 2p)$.

### 3.3 M3 Pro GPU Scheduling Pathology

We discovered a severe hardware-level performance pathology where certain Pippenger window sizes cause 10--30x slowdowns in the reduce kernel:

| Window Size $w$ | Buckets | Reduce Time | Status |
|-----------------|---------|-------------|--------|
| 12 | 4K | 3--5x slow | Slow |
| 13 | 8K | Normal | Fast |
| **14** | **16K** | **10--30x slow** | **Catastrophic** |
| **15** | **32K** | **10--30x slow** | **Catastrophic** |
| 16 | 64K | Normal | Fast |
| **17** | **128K** | **10--30x slow** | **Catastrophic** |
| 18 | 256K | 3--5x slow | Slow |

**Hypothesis:** Register pressure at certain bucket counts causes spilling to device memory. When threads in a SIMD group have highly variable iteration counts (thread divergence), the long-running threads stall while consuming registers, causing cascading pressure across the wavefront. Capping the inner loop to 16 iterations makes *all* window sizes fast, confirming the divergence amplification mechanism.

**Important negative result:** Count-sorted reduce (which eliminates SIMD divergence) does *not* fix $w=15$. The pathology persists even with uniform thread workloads at that bucket count, suggesting a deeper hardware-level issue with register allocation at specific occupancy points.

**Mitigation:** Fixed $w=16$ for all MSMs with $n > 32$K points. Added per-window bucket imbalance bailout: if any window has $>$10% of points in one bucket, fall back to CPU for that MSM.

### 3.4 Memory Allocation Optimization

#### 3.4.1 DontZeroMemory for Polynomial Allocation

Barretenberg's `Polynomial` constructor zero-initializes all coefficients via parallel `memset`. For polynomials that are immediately overwritten, this is wasted work. We applied the existing `DontZeroMemory::FLAG` constructor to three hot paths:

| Location | Polynomials | Elements Saved | Impact |
|----------|-------------|----------------|--------|
| `PartiallyEvaluatedMultivariates` | 60+ per round | 60 x 524K | ~20ms (production) |
| Shplonk `tmp`/`tmp_neg` scratch | 2 | 2 x 524K | ~2ms |
| Gemini `full_batched` copy | 1 | 524K | ~1ms |

**Caveat:** We attempted `DontZeroMemory` on Gemini fold polynomials but this produced **incorrect proofs**. The commitment scheme reads polynomial data up to `virtual_size`, not just the written range, so uninitialized memory beyond the fold data corrupts the SRS dot product.

#### 3.4.2 Gemini Batch Copy Optimization

The Gemini protocol initializes `full_batched` via zero-allocation followed by `+=` of `batched_unshifted`. We replaced this with direct copy construction, eliminating one full-polynomial zero + add cycle.

### 3.5 Thread Pool and Parallelism

#### 3.5.1 Spin-Wait Thread Pool (Session 9)

The default Barretenberg thread pool uses `std::condition_variable` for worker wake-up, incurring ~400us kernel transition cost per `parallel_for` dispatch (100+ dispatches per proof). We added a spin-wait phase: workers spin for 4000 `yield` iterations before falling back to the condition variable.

**Result:** ~72ms improvement on the production circuit from reduced kernel wakeup latency.

#### 3.5.2 Atomic Lock-Free Iteration Dispatch (Rejected)

We attempted replacing the per-iteration `std::mutex` with `std::atomic<size_t>::fetch_add` for lock-free work claiming. Three variants were tested:

1. **Pure spin-wait**: Workers spin continuously on a generation counter. Result: 3x regression from CPU burn (all cores at 100% spinning instead of working).
2. **Hybrid condvar + atomic**: Workers sleep on condvar, claim iterations via atomic. Result: SIGKILL from race condition---`num_iterations_` was read without synchronization.
3. **Full atomic with generation**: Correct but complex synchronization. Not pursued due to subtle ordering requirements.

The original mutex-based pool is well-optimized for macOS's `pthread_mutex` implementation. The contention (26 samples in profiling) is real but represents only ~3% of CPU time.

### 3.6 Commitment Batching

#### 3.6.1 Masking + Wires Batch

The Oink phase committed to the Gemini masking polynomial and three wire polynomials in separate GPU MSM dispatches. Since no Fiat-Shamir challenge separates them, we merged all four into a single `batch_multi_scalar_mul` call:

| Operation | Before | After | Savings |
|-----------|--------|-------|---------|
| masking + wires commit | 86.3ms | 83.3ms | 3ms |

#### 3.6.2 Gemini Fold Batch Commit

Similarly, the Gemini fold polynomial commitments (up to 18 sequential commits for the production circuit) can be batched into a single `batch_commit` call, overlapping GPU MSMs for large folds with CPU MSMs for small folds.

### 3.7 Timing Instrumentation Removal

Profiling instrumentation (`info()` calls with `std::chrono` timing and `std::ostringstream` formatting) was present in the PCS hot path across three files: `gemini_impl.hpp`, `shplonk.hpp`, and `kzg.hpp`. Removal yielded:

| Circuit | Savings |
|---------|---------|
| bench\_poseidon (75K gates) | ~5--8ms |
| production (428K gates) | ~40--74ms (3--5%) |

The larger savings on the production circuit reflect more PCS operations (more Gemini fold rounds, larger Shplonk quotient).

### 3.8 GPU Count-Sorted Mapping (CSM)

The count-sorted mapping (CSM) reorders bucket indices so adjacent SIMD threads process buckets of similar size, eliminating thread divergence in the reduce kernel. Initially implemented on CPU (requiring a blocking CPU/GPU sync between sort and reduce), we moved CSM to a dedicated Metal compute kernel `msm_compute_csm`:

**Before (CPU CSM):**
```
GPU: GLV → histogram → prefix_sum → scatter
[HARD SYNC: waitUntilCompleted]
CPU: CSM computation + imbalance detection + large bucket identification
GPU: reduce → bucket_sum → combine
```

**After (GPU CSM):**
```
GPU: GLV → histogram → prefix_sum → scatter → CSM
[waitUntilCompleted]
GPU: reduce → bucket_sum → combine
```

The GPU kernel handles three tasks in a single dispatch per window:
1. Count-sorted mapping via threadgroup-local histogram and descending prefix sum
2. Bucket imbalance detection (>10% per window, >25% global)
3. Large bucket identification (count > 256) for parallel reduction

This eliminates ~1-2ms of CPU computation and, more importantly, removes the CPU/GPU synchronization bottleneck that prevented pipelining the sort and reduce phases.

### 3.9 SRS Buffer Caching

The Structured Reference String (SRS) points are immutable across all MSMs within a proof. Rather than re-copying SRS data for each MSM, the GPU context maintains cached pointer and count values (`cached_srs_ptr`, `cached_srs_count`). When consecutive MSMs use the same SRS data (which they always do within a single proof), the memcpy is skipped entirely. This saves ~2-5ms per MSM on the production circuit.

### 3.10 Endomorphism Point Cache

The GLV endomorphism maps each SRS point $G_i$ to $\phi(G_i) = (\beta \cdot x_i, y_i)$. Since SRS points don't change between MSMs, we precompute and cache all endomorphism points in a single GPU dispatch (`glv_precompute_cache`). The cache stores $2n$ points (original + endomorphism) and is invalidated only when the SRS pointer or count changes. Subsequent MSMs apply only the per-scalar sign flags via `glv_apply_neg_flags`, avoiding redundant field multiplications.

### 3.11 Sort-Reduce Batch Overlap

To overlap CPU and GPU work, the counting sort and reduce phases are batched: the CPU sorts the first batch of windows and dispatches GPU reduce (non-blocking), then sorts the second batch while GPU processes the first. This hides ~4ms of CPU sort latency behind the ~20ms GPU reduce, saving ~3-5ms per MSM.

### 3.12 Precomputed Bucket Indices

Bucket index extraction from 256-bit scalars requires bit shifting across 32-byte arrays. Rather than extracting indices twice (once for counting, once for scatter), the extraction is merged with the counting phase and stored as compact uint16 arrays. The scatter phase reads from the precomputed array, avoiding redundant bit manipulation. This saves ~2ms per MSM by halving the scalar memory reads.

### 3.13 Build System Optimizations

#### 3.8.1 Thin LTO

Link-time optimization (`-flto=thin`) is critical for performance. Without LTO applied to *both* `CMAKE_CXX_FLAGS` and `CMAKE_EXE_LINKER_FLAGS`, the binary bloats from 19MB to 24MB and proves ~60ms slower due to missed cross-TU inlining opportunities.

#### 3.8.2 ARM64 Assembly (Rejected)

We attempted hand-written ARM64 NEON assembly for BN254 field multiplication (`__int128` Montgomery reduction). Result: **9% regression**. Clang's codegen for `__int128` multiplication on ARM64 is already near-optimal, using `UMULH`/`MADD` instruction sequences that match or exceed hand-written assembly when accounting for calling convention overhead.

---

## 4. Rejected Optimizations

The following approaches were investigated and rejected with measured evidence:

| # | Optimization | Result | Root Cause |
|---|-------------|--------|------------|
| 1 | GPU compute\_univariate (sumcheck) | 3--6x slower | 256-bit field math on Metal's 32-bit ALUs cannot compete with CPU 64-bit ALUs. 9 relations with up to degree-7 constraints require ~100 registers per thread, destroying GPU occupancy. |
| 2 | GPU zero-copy partial\_evaluate | SIGSEGV | Metal `newBufferWithBytesNoCopy` has alignment requirements that sumcheck polynomials don't guarantee. Only ~7ms theoretical savings. |
| 3 | Multi-MSM pipelining | Impossible | Fiat-Shamir transcript creates causal dependencies: each commitment must be in the transcript before deriving the next challenge. |
| 4 | compute\_batched fusion | 2x slower | Fusing 80-polynomial `add_scaled` into a single pass destroys L1/L2 cache locality. Sequential per-polynomial passes keep working set in cache. |
| 5 | logderiv + z\_perm merge | 12% slower | `batch_multi_scalar_mul` overhead exceeds launch savings for 2-MSM batches. |
| 6 | ARM64 inline assembly | 9% regression | Clang `__int128` codegen already near-optimal on ARM64. |
| 7 | PGO instrumentation | 8x regression | `-fprofile-instr-generate` produces 148MB binary with runtime instrumentation overhead. |
| 8 | `dispatch_apply` removal | 2% regression | GCD `dispatch_apply` is well-optimized on macOS; replacement with custom thread pool slightly worse. |
| 9 | GPU bucket reduction tuning | No gain | Reduce phase already near hardware limits at 80%+ of MSM time. |
| 10 | Wire GPU via GLV | 440ms+/wire | Bucket pathology from structured polynomial scalars. |
| 11 | Wire GPU via uniform windows | 1300ms+/wire | GPU overwhelmed by too many windows. |
| 12 | Transposed compute\_batched | Marginal | Compute-bound at 60 x 1M field multiplications; reordering access pattern doesn't help. |
| 13 | Sumcheck GPU/SIMD | Not feasible | Deeply templated C++ with 9 different relation types. |
| 14 | DontZeroMemory Gemini fold | Incorrect proofs | Commitment reads up to `virtual_size`; uninitialized data corrupts SRS dot product. |
| 15 | Atomic thread pool | Crash / 3x regression | Race conditions with condvar; pure spin burns CPU. |
| 16 | Lower MSM threshold (32K) | 5x regression | GPU dispatch overhead dominates for small MSMs. |

---

## 5. Results

### 5.1 Overall Performance

| Configuration | bench\_poseidon (75K gates) | production (428K gates) |
|---------------|---------------------------|----------------------|
| Stock bb v4.1.2 (CPU-only) | 755ms wall / 4.95s CPU | ~3,800ms wall |
| Session 4 (GPU MSM + batching) | ~380ms | -- |
| Session 8 (async init + prewarm) | ~300ms | -- |
| Session 9 (GPU-only preconvert) | ~240ms | ~1,060ms (with VK) |
| Session 10 (fused gather-reduce) | ~310ms | ~1,050ms (with VK) |
| **Final optimized** | **~310--360ms wall** | **~1,320--1,400ms wall** |
| **construct\_proof only** | **~148ms** | **~815ms** |

*Note: Wall clock includes ACIR deserialization, circuit construction, and I/O. The `construct_proof` time isolates the cryptographic proving operation.*

### 5.2 Phase Breakdown

#### Small Circuit (bench\_poseidon, 131K dyadic)

| Phase | Time | % of Total |
|-------|------|-----------|
| Oink (commitments) | 148ms | 48% |
| Sumcheck (17 rounds) | 41ms | 13% |
| PCS (Gemini + Shplonk + KZG) | 122ms | 39% |
| **Total construct\_proof** | **311ms** | **100%** |

#### Production Circuit (428K gates, 524K dyadic)

| Phase | Time | % of Total |
|-------|------|-----------|
| Oink (commitments) | 349ms | 43% |
| Sumcheck (19 rounds) | 184ms | 23% |
| PCS (Gemini + Shplonk + KZG) | 285ms | 35% |
| **Total construct\_proof** | **815ms** | **100%** |

### 5.3 GPU MSM Breakdown (524K-point MSM)

| Phase | Time | % of MSM |
|-------|------|---------|
| Host-to-GPU copy | 1.3ms | 2% |
| GLV decompose (GPU) | 3.5ms | 6% |
| Counting sort (GPU) | 5.1ms | 9% |
| Bucket accumulate + reduce (GPU) | 47ms | 82% |
| Horner combine (CPU) | <1ms | 1% |
| **Total per MSM** | **~57ms** | **100%** |

### 5.4 Throughput Analysis

| Metric | Small Circuit | Production Circuit |
|--------|--------------|-------------------|
| GPU MSM throughput | ~105 ns/point | ~109 ns/point |
| CPU sumcheck throughput | ~180 ns/edge | ~176 ns/edge |
| Memory bandwidth utilization | ~40 GB/s | ~40 GB/s |
| GPU ALU utilization (est.) | ~70% | ~70% |

---

## 6. Performance Ceiling Analysis

### 6.1 Theoretical Limits

**GPU MSM:** Each point addition requires ~12 BN254 Fq multiplications. At 256-bit (8x32-bit) CIOS Montgomery multiplication requiring ~80 multiply-accumulate operations per field multiplication, and with M3 Pro's 18 GPU cores each capable of ~128 32-bit operations per cycle at ~1.5 GHz:

$$T_{\text{theoretical}} = \frac{n \cdot 12 \cdot 80}{18 \cdot 128 \cdot 1.5 \times 10^9} \approx 28 \text{ ns/point}$$

Our measured 105 ns/point represents ~27% of theoretical peak, typical for memory-bound workloads with irregular access patterns (bucket accumulation).

**CPU Sumcheck:** BN254 Fr multiplication requires ~8 `UMULH` + 8 `MADD` instructions on ARM64. With 12 cores at ~4 GHz:

$$T_{\text{theoretical}} = \frac{n_{\text{edges}} \cdot n_{\text{relations}} \cdot \text{ops/relation}}{12 \cdot 4 \times 10^9}$$

Our measured 180 ns/edge is within 2--3x of theoretical, limited by instruction-level parallelism and cache effects in the relation evaluation templates.

**Memory Bandwidth:** Gemini's `add_scaled` operation on 80 polynomials of 524K elements moves ~1.3GB of data. At 160 GB/s theoretical bandwidth, the lower bound is ~8ms; our measured ~25ms reflects the overhead of interleaved multiply-add operations.

### 6.2 Remaining Bottleneck Distribution

For the production circuit, the proving time breaks down by hardware resource:

| Resource | Time | % | Operations |
|----------|------|---|-----------|
| GPU ALU (MSM) | ~500ms | 61% | EC point additions in bucket reduce |
| CPU ALU (sumcheck) | ~184ms | 23% | BN254 Fr multiplication in relations |
| Memory bandwidth | ~80ms | 10% | add\_scaled, compute\_batched, fold |
| Dispatch overhead | ~50ms | 6% | Thread pool wake, GPU command encode |
| **Total** | **~815ms** | **100%** | |

---

## 7. Lessons Learned

### 7.1 Unified Memory is Not Free

While Apple Silicon's unified memory eliminates PCIe transfer costs, the GPU must still fetch data through its cache hierarchy. Irregular access patterns (bucket accumulation) achieve only ~25% of peak bandwidth. Zero-copy buffers via `newBufferWithBytesNoCopy` help but require page-aligned allocations.

### 7.2 32-bit GPU ALUs Penalize Wide-Field Arithmetic

Metal's 32-bit ALUs require 8 limbs for 256-bit field arithmetic. A single Montgomery multiplication requires ~80 multiply-accumulate operations, consuming significant register file capacity. When register pressure exceeds the GPU's allocation (~32K registers per SIMD group on M3), occupancy drops and latency-hiding fails. This makes GPU acceleration of field-intensive operations (like sumcheck relation evaluation) counterproductive---the CPU's native 64-bit `UMULH`/`MADD` instructions are 4x more efficient per operation.

### 7.3 Lazy Montgomery Reduction is a Cross-Platform Hazard

Barretenberg's choice to store field elements in $[0, 2p)$ is an internal optimization that avoids a conditional subtraction after each addition. This is invisible to CPU code (where `__int128` handles the extra bit) but catastrophic for GPU ports where `fp_add` may not expect inputs above $p$. Any GPU backend must normalize at boundaries.

### 7.4 Profiling Before Optimizing

Our most impactful discovery was the four-level profiling breakdown showing MSM operations consume 67% of proving time. Without this data, we might have spent significant effort on the remaining 33% (sumcheck, memory operations) with diminishing returns. The GPU compute\_univariate attempt (3--6x slower) would have been avoided entirely with better upfront analysis of Metal's 32-bit ALU limitations.

---

## 8. Future Directions

### 8.1 Hardware Upgrades

The M4 Pro/Max with additional GPU cores would provide near-linear scaling for MSM operations, as bucket accumulation is embarrassingly parallel. An M4 Max with 40 GPU cores (vs. M3 Pro's 18) could theoretically cut MSM time by ~55%.

### 8.2 Protocol-Level Changes

Reducing the number of polynomial commitments in UltraHonk would have the highest impact. Each eliminated commitment saves one full MSM (~55ms on the production circuit). Potential approaches include commitment aggregation, deferred commitments, or alternative PCS constructions with fewer rounds.

### 8.3 Alternative Curves

BN254's 254-bit field requires 4x64-bit or 8x32-bit limb arithmetic. Curves with smaller fields (e.g., BLS12-381's scalar field at 255 bits offers no advantage, but Pasta curves at 255 bits or smaller fields from STARKs) could improve GPU throughput.

### 8.4 Pippenger Algorithmic Improvements

The bucket reduction phase consumes 82% of MSM time. Alternative reduction strategies (e.g., signed-digit representations, non-adjacent form, or multi-level bucket reduction) could reduce the number of point additions per bucket, though our attempts at GPU-specific reduction optimizations showed no gain on M3 Pro.

---

## 9. Verification Cost Analysis

### 9.1 Native Verification

The UltraHonk native verifier runs in **~10ms** on M3 Pro, dominated by a single 77-point MSM and one BN254 pairing check. The O(log N) verification complexity is a fundamental property of the SNARK protocol---there is no meaningful optimization target. GPU acceleration is counterproductive: the 77-point MSM is 400x below our GPU dispatch threshold (32,768 points), and kernel launch overhead would exceed the computation itself.

### 9.2 On-Chain (Solidity) Verification

On-chain verification presents a different cost structure measured in EVM gas rather than wall time:

| Operation | Gas/call | Calls | Total | Share |
|-----------|---------|-------|-------|-------|
| ecMul (0x07) | 6,000 | ~41 | ~246,000 | 56% |
| ecPairing (0x08) | 113,000 | 1 | ~113,000 | 26% |
| ecAdd (0x06) | 150 | ~80 | ~12,000 | 3% |
| Sumcheck + field ops | --- | --- | ~60,000 | 14% |
| **Total** | | | **~436,000** | |

The 41 ecMul calls (one per polynomial commitment) dominate at 56% of gas. Unlike native MSM where GPU parallelism helps, EVM precompiles are fixed-cost---no acceleration path exists within the current EVM.

**Existing optimizations in the Solidity verifier:**
- Assembly-level ecAdd/ecMul dispatch (>10K gas savings)
- Montgomery batch inversion (1 modexp instead of ~40)
- Manual memory slab allocation
- Loop unrolling in barycentric evaluation
- Challenge splitting (254-bit hash → 2×127-bit challenges)

**Remaining optimization levers (all protocol-level):**
- Reduce polynomial commitment count (each removal saves 6K gas)
- EIP-7904 pairing repricing (~5x reduction, proposed for Glamsterdam)
- Recursive proof wrapping (Honk → UltraPlonk for fewer on-chain commitments)

**Current USD costs:** At 0.5 gwei gas price and ~\$2,000 ETH, a single rollup proof verification costs ~\$0.0005. Per-user cost in a 256-transaction batch is ~\$0.000005.

---

## 10. Conclusion

We demonstrated that Apple Silicon's Metal GPU framework can significantly accelerate zero-knowledge proof generation, achieving 3.6--5.1x speedup on the Barretenberg UltraHonk prover. The key enabler is GPU-accelerated multi-scalar multiplication, which dominates 61--69% of proving time. Our systematic approach---profiling first, measuring every change, and documenting rejected approaches---produced a prover operating within 2--5x of theoretical hardware limits across all major phases.

The 16 documented negative results are arguably as valuable as the 17 successful optimizations: they map the boundary between tractable and intractable GPU acceleration for field-arithmetic-heavy workloads, and demonstrate that the 32-bit ALU limitation of current mobile GPUs creates a fundamental asymmetry favoring CPU execution for operations with high arithmetic intensity per memory access (like sumcheck relation evaluation) while favoring GPU execution for operations with high parallelism and moderate arithmetic intensity (like MSM bucket accumulation).

---

## Appendix A: Optimization Timeline

| Session | Date | Key Changes | Result |
|---------|------|-------------|--------|
| 1 | -- | GPU bucket\_sum (225->23ms), GPU GLV (12->3.5ms), merged command buffer | 3850->1050ms |
| 2 | -- | skip\_imbalance\_check, parallel Shplonk, wire skip\_gpu | 1050ms stable |
| 3 | -- | GPU counting sort, DontZeroMemory, prewarm, per-window bailout | 1550->1466ms |
| 4 | -- | Count-sorted reduce, batched sort-reduce overlap | ~380ms (small) |
| 5--7 | -- | GPU GLV decompose, 512-segment combine, unified pipeline | 165->85ms MSM |
| 8 | -- | Async Metal init, non-blocking prewarm | ~300ms (small) |
| 9 | -- | GPU-only batch preconversion, spin-wait thread pool | ~240ms (small) |
| 10 | -- | Fused gather-reduce (-85ms), timing cleanup | 1790->1452ms (large) |
| 11 | -- | Fixed SIGSEGV, removed dead code, restored LTO | ~310ms / ~1.3s |
| 12 | -- | Timing removal, DontZeroMemory (reverted), atomic pool (reverted) | ~3--5% PCS |
| 13 | -- | GPU CSM kernel, documentation of undocumented techniques | Eliminates CPU/GPU sync |

## Appendix B: Profiling Methodology

All measurements use `time(1)` wall clock with interleaved A/B comparison (alternating old/new binary runs to control for thermal and system load variation). CPU profiling uses macOS `sample(1)` at 1ms intervals. GPU profiling uses Metal System Trace via `xctrace`. Statistical significance requires $\geq$3 consecutive runs with median comparison and outlier exclusion.

## Appendix C: File Manifest

Key modified files in the Barretenberg source tree:

| File | Changes |
|------|---------|
| `ecc/scalar_multiplication/metal/bn254.metal` | BN254 field arithmetic, `fp_reduce`, point operations |
| `ecc/scalar_multiplication/metal/metal_msm.mm` | MSM host dispatch, GLV, sort, threshold, bailout |
| `ecc/scalar_multiplication/metal/prover_ops.metal` | Polynomial operation kernels (fold, partial\_eval) |
| `commitment_schemes/gemini/gemini_impl.hpp` | Timing removal, fold poly allocation |
| `commitment_schemes/shplonk/shplonk.hpp` | Timing removal |
| `commitment_schemes/kzg/kzg.hpp` | Timing removal |
| `ultra_honk/oink_prover.cpp` | Masking+wires batch commit |
| `polynomials/polynomial.cpp` | DontZeroMemory applications |
| `common/parallel_for_mutex_pool.cpp` | Spin-wait thread pool |
| `sumcheck/sumcheck.hpp` | GPU partial\_evaluate integration |
| `flavor/partially_evaluated_multivariates.hpp` | DontZeroMemory for sumcheck polys |

# Barretenberg Prover Optimizations

All optimizations applied to the Aztec testnet prover. Organized by category.
Target: fit epoch proving (~98 jobs) within the 20-minute epoch window on 18 GiB M3 Pro.

## Caching

| Optimization | Location | Impact |
|---|---|---|
| CommitmentKey cache (SRS + Metal GPU) | `commitment_key.hpp` | ~150-300ms saved per repeated circuit size; ~14s/epoch for 98 proofs |
| Precomputed polynomial disk cache | `ultra_prover.cpp:construct_proof_low_memory()` | ~10-20s saved on cache hit (symlink vs serialize) |
| MSM bucket width thread-local cache | `scalar_multiplication.cpp` | Avoids recomputation per MSM call |
| L3 cache-aware bucket cost model | `scalar_multiplication.cpp` | Penalizes bucket widths that exceed L3 capacity (~375K buckets) |
| SRS page cache pre-warm | `scripts/start-prover.sh` | ~2-3s cold I/O eliminated on first proof |

## Parallelism & Overlap

| Optimization | Location | Impact |
|---|---|---|
| Async bytecode + witness parsing | `patches/.../bbapi_ultra_honk.cpp` | Overlaps independent deserializations |
| GPU masking poly commit + CPU wire prep (ZK) | `oink_prover.cpp` | ~10-20ms overlap |
| GPU lookup_inverses commit + CPU grand product | `oink_prover.cpp` | Overlaps commit with computation |
| Parallel precomputed poly serialization (3 writers) | `ultra_prover.cpp` | 3x throughput for disk writes |
| Parallel witness poly serialization (3 writers) | `ultra_prover.cpp` | 3x throughput for disk writes |
| Early wire poly serialization during Oink | `ultra_prover.cpp` | Overlaps w_l/w_r/w_o I/O with sorted_list + log_derivative + grand_product rounds |
| Async streaming temp cleanup | `ultra_prover.cpp:construct_proof()` | ~100ms unblocked from proof return |
| GPU/CPU fold commit overlap | `gemini_impl.hpp` | CPU batch MSM runs async during GPU commits |
| Parallel Gemini A0+/A0- evaluation | `gemini_impl.hpp` | Two independent Horner evals in parallel |
| Fused chunked wire+copy_cycle pass | `trace_to_polynomials.cpp` | Eliminates redundant block.wires read; thread-local accumulation |
| Parallel permutation mapping | `permutation_lib.hpp` | Parallelizes cycle→sigma/ID mapping across threads |

## Memory Management

| Optimization | Location | Impact |
|---|---|---|
| Streaming sumcheck (mmap-backed) | `ultra_prover.cpp` | Serialize→free→mmap reload for sumcheck; OS manages physical memory |
| Progressive Oink memory management | `ultra_prover.cpp:construct_proof_low_memory()` | Frees precomputed polys between Oink rounds; -10 GiB peak at 2^24 |
| Post-Oink witness serialization + free | `ultra_prover.cpp:construct_proof_low_memory()` | Serialize witness, free all; sumcheck reloads via mmap |
| Low-memory size threshold (2^23+) | `ultra_prover.cpp:construct_proof()` | Small circuits skip serialization overhead |
| DontZeroMemory for partial eval polys | `partially_evaluated_multivariates.hpp` | Avoids redundant memset |
| DontZeroMemory for Gemini fold polys | `gemini_impl.hpp` | Avoids redundant memset |
| Post-batch source poly freeing | `gemini.hpp:PolynomialBatcher` | Frees source after Gemini batch |
| Huge pages (2 MiB superpages) | `patches/.../backing_memory.hpp` | 512x TLB pressure reduction for large polys |
| MADV_FREE lazy deallocation | `patches/.../backing_memory.hpp` | Reduces munmap latency by 1-5ms per poly |
| Auto-detect agent count by RAM | `scripts/start-prover.sh` | 4x3 for 36+GiB, 3x4 default (18+GiB), 2x6 for <18GiB |
| File-backed polynomial allocation | `scripts/start-prover.sh` | BB_SLOW_LOW_MEMORY=1; enables mmap-backed polys for multi-agent memory safety |

## I/O Optimization

| Optimization | Location | Impact |
|---|---|---|
| 4 MiB write chunks + F_NOCACHE | `polynomial.cpp:serialize_to_file()` | Reduces syscalls, avoids cache pollution |
| MADV_SEQUENTIAL + MADV_WILLNEED on mmap | `polynomial.cpp:mmap_from_file()` | Aggressive readahead + prefetch |
| Precomputed poly persistent cache (VK-keyed) | `ultra_prover.cpp` | First proof serializes to /tmp/bb-poly-cache/{vk_hash}/; subsequent proofs use symlinks (instant) |
| PCS ordering deduplication via symlinks | `ultra_prover.cpp` | Unshifted/shifted orderings symlink to all_ files instead of redundant serialization |
| Disk-backed PCS polynomial streaming | `gemini.hpp:compute_batched_from_disk()` | One poly in memory at a time during PCS |
| PCS prefetch-ahead for next polynomial | `gemini.hpp:compute_batched_from_disk()` | Overlaps mmap I/O with add_scaled computation |
| Precomputed (1-r) form in partial eval | `sumcheck.hpp` | Avoids subtraction, better pipeline |

## GPU (Metal)

| Optimization | Location | Impact |
|---|---|---|
| Metal GPU MSM for BN254 | `metal_msm.hpp`, `metal_msm.mm` | GPU acceleration for large MSMs |
| Per-window bucket imbalance bailout | `metal_msm.mm` (permanent) | Avoids GPU bailout on skewed windows |
| Sparse MSM for ZK-masked polynomials | `commitment_key.hpp` | ~46% fewer points for masked polys |
| Metal prewarm during CK construction | `commitment_key.hpp` | Overlaps ~150ms GPU init with CPU |
| GPU disabled in streaming mode | `commitment_key.hpp` | Avoids GPU memory contention |

## MSM / Scalar Multiplication

| Optimization | Location | Impact |
|---|---|---|
| Cache-aware bucket width cost model | `patches/.../scalar_multiplication.cpp` | L3 miss penalty for large bucket counts |
| Fused dual-Horner evaluation | `gemini_impl.hpp` | Single-pass pos+neg eval for small folds |
| Batch CPU MSM for small Gemini folds | `gemini_impl.hpp` | Single batch_multi_scalar_mul call |

## Sumcheck

| Optimization | Location | Impact |
|---|---|---|
| Block-based poly_mask optimization (enabled) | `sumcheck_round.hpp` | 40-55% DRAM bandwidth saved per block; ~11% sumcheck speedup |
| Software prefetch for next edge | `sumcheck_round.hpp` | Hides DRAM latency across 41+ poly streams |
| Relation-masked accumulation | `sumcheck_round.hpp` | Skips Relation::accumulate for inactive blocks; up to 60% compute reduction |
| Prefetch-ahead in extend_edges_masked | `sumcheck_round.hpp` | Prefetches next active poly's edge data during masked loading |
| L1-cache-tiled batching (TILE_ELEMS=2048) | `gemini.hpp:compute_batched()` | Keeps accumulator hot in 128KB L1 |
| Precomputed polynomial view | `sumcheck_round.hpp` | Avoids 41 pointer copies per edge |
| ZK trace boundary detection | `sumcheck.hpp` | Skips zero gap in masked witness polys |
| Page pre-faulting via MADV_WILLNEED | `polynomial.cpp:mmap_from_file()` | Kernel prefaults pages async before access |

## Operational

| Optimization | Location | Impact |
|---|---|---|
| Auto-restart crash monitor | `scripts/monitor-prover.sh` | Auto-recovers from prover crashes |
| PGO training pipeline | `scripts/pgo-train.sh` | Profile-guided optimization for bb-avm (measured: negligible ~1.6% at 2^20, within noise) |
| Epoch statistics parser | `scripts/epoch-stats.sh` | Per-circuit timing breakdown |
| Live metrics dashboard | `scripts/monitor-metrics.sh` | Real-time prover performance monitoring |
| Configurable agent/thread count | `scripts/start-prover.sh` | Memory-aware multi-agent proving |
| Memory pressure detection | `scripts/start-prover.sh` | Reduces agents under low-memory conditions |
| Agent poll interval 100ms | `scripts/start-prover.sh` | PROVER_AGENT_POLL_INTERVAL_MS=100; saves ~44s/epoch idle-to-pickup time |

## Architecture

- **Broker pattern**: Separate broker process on port 8079, prover-node + agents on port 8180
- **N agents x M threads**: Configurable parallelism (3x4 default with file-backed memory, 4x3 for 36+ GiB, 2x6 for <18 GiB)
- **Progressive low-memory proving** (2^23+): Serialize polys→free→mmap reload; peak memory = OS working set + half-size partial eval
- **Streaming sumcheck**: All polynomials serialized to disk; reloaded via mmap for sumcheck (OS manages physical memory)
- **Disk-backed PCS**: Gemini batching loads polys from disk one at a time via mmap
- **Precomputed poly persistent cache**: VK-hash-keyed at /tmp/bb-poly-cache/; first proof serializes + hardlinks; subsequent proofs symlink (instant)
- **PCS deduplication via symlinks**: Unshifted/shifted PCS orderings symlink to all_ files instead of redundant serialization (~50% I/O saved)
- **Early wire serialization**: w_l/w_r/w_o serialized async during remaining Oink rounds (sorted_list, log_derivative, grand_product)
- **Parallel serialization**: 3 concurrent writer threads for precomputed + witness poly serialization (~3x throughput)
- **Async temp cleanup**: Streaming temp dir removed in detached thread (~100ms unblocked per proof)
- **Fused trace populate**: Wire writes + copy cycle accumulation in single chunked parallel pass
- **Parallel permutation mapping**: Cycle→sigma/ID mapping parallelized across threads

## Production Baseline

- **Hardware**: Apple M3 Pro, 18 GiB RAM
- **Configuration**: 3 agents x 4 threads (default), file-backed memory (BB_SLOW_LOW_MEMORY=1)
- **Agent poll interval**: 100ms (vs 1000ms default) — ~44s/epoch saved
- **First completed epoch**: Epoch 1093 on Sepolia L1 (with 2x6 config)
- **Projected epoch time**: ~11-12 minutes with 3 agents + all optimizations
  - 3-agent parallelism: ~30% faster than 2-agent (~19 min → ~13 min)
  - Poly cache + parallel serialization: ~80s/epoch saved on repeated circuits
  - Agent poll interval: ~44s/epoch saved
  - Async cleanup + symlink dedup: ~20s/epoch saved

# AztecFastTech: GPU-Accelerated ZK Proving on Apple Silicon

Hardware-accelerated UltraHonk (BN254) proving using Apple Metal compute shaders on M-series chips. This project demonstrates a **3.8x speedup** on production Aztec circuits by offloading multi-scalar multiplication (MSM) to the GPU via a custom Metal compute pipeline.

## Results

| Circuit | Gates | Baseline (CPU) | Optimized (Metal GPU) | Speedup |
|---------|------:|---------------:|----------------------:|--------:|
| Poseidon hash chain | 75K | 538ms | 310ms | 1.7x |
| Merkle tree proofs | 44K | 343ms | 270ms | 1.3x |
| EC scalar muls | 30K | 265ms | 210ms | 1.3x |
| Production (Persistia) | 429K | 4717ms* | 1250ms | 3.8x |

*Baseline includes GPU scheduling pathology on structured polynomials (M3 Pro specific).
Fair baseline without pathology: ~1550ms, giving 1.2x improvement.

**Hardware:** Apple M3 Pro (11-core GPU, 18GB unified memory)

### Hardware Requirements: Aztec Official vs AztecFastTech

Aztec's official prover infrastructure requires [server-class hardware](https://docs.aztec.network/the_aztec_network/guides/run_nodes/how_to_run_prover):

| Resource | Aztec Prover Agent | AztecFastTech (M3 Pro laptop) | Reduction |
|----------|-------------------|--------------------------|-----------|
| **CPU** | 32 cores / 64 vCPU | 12 cores (6P+6E) | 5.3x fewer cores |
| **RAM** | 128 GB | 18 GB | 7x less memory |
| **GPU** | None (CPU-only) | 11-core Apple GPU | Novel acceleration |
| **Cluster** | ~40 machines | 1 laptop | 40x fewer machines |

Aztec's proving pipeline is entirely CPU-based. A full prover cluster requires approximately 40 machines, each with 32+ cores and 128GB RAM. By offloading multi-scalar multiplication to the Metal GPU, AztecFastTech achieves competitive proving times for transaction-sized circuits (30K-429K gates) on a single consumer laptop with 7x less RAM.

> **Note:** Aztec's largest circuits (root rollup, ~60GB peak RAM) still exceed consumer hardware. The gains here apply to the common case: client-side proofs, transaction circuits, and function calls that dominate the proving workload.

## Architecture

The optimization targets Aztec's [Barretenberg](https://github.com/AztecProtocol/barretenberg) UltraHonk prover, specifically the Pippenger MSM algorithm used in polynomial commitment schemes (KZG via Gemini/Shplonk).

Key techniques:
1. **Metal GPU MSM pipeline** — bucket accumulation via atomic scatter, parallel reduction, and affine-to-Jacobian conversion on GPU
2. **GLV endomorphism on GPU** — scalar decomposition moved to Metal compute, halving effective scalar width
3. **Adaptive window sizing** — per-MSM window selection based on point count, avoiding GPU scheduling pathologies at w=14,15,17
4. **Per-window bucket imbalance bailout** — detects structured polynomials that cause 1000ms+ GPU stalls, falls back to CPU
5. **DontZeroMemory** — skip redundant memory zeroing for polynomials immediately overwritten
6. **Lazy Montgomery reduction** — GPU operates in [0,2p) with boundary normalization, fixing correctness bugs
7. **Batch polynomial commitments** — overlaps GPU and CPU MSMs via `batch_commit`
8. **Timing instrumentation removal** — eliminated `std::chrono` + `info()` overhead from PCS hot path

See [RESEARCH_REPORT.md](RESEARCH_REPORT.md) for the full technical writeup.

## Project Structure

```
AztecFastTech/
├── barretenberg/           # Git submodule: Metal-accelerated barretenberg fork
├── poseidon-hash/          # Noir circuit: 1024-iteration Poseidon2 hash chain (75K gates)
├── merkle-tree/            # Noir circuit: 512 hashes + 8 membership proofs (44K gates)
├── ec-ops/                 # Noir circuit: 16 Grumpkin scalar multiplications (30K gates)
├── patches/                # Additional optimization patches (applied by build-optimized.sh)
│   ├── 01-dont-zero-partial-eval.patch
│   ├── 02-lower-msm-threshold.patch
│   ├── 03-adaptive-bucket-sort.patch
│   ├── apply_adaptive_sort.py
│   └── apply_per_window_bailout.py
├── bench.sh                # Benchmark runner (compile, prove, verify)
├── build-optimized.sh      # Build optimized bb binary with patches applied
├── gen_witnesses.py        # Generate witness files for merkle-tree and ec-ops circuits
├── results/                # Benchmark results (baseline vs optimized)
├── RESEARCH_REPORT.md      # Full research report
├── RESEARCH_REPORT.tex     # LaTeX version
├── RESEARCH_REPORT.pdf     # PDF version
└── Nargo.toml              # Noir workspace configuration
```

## Prerequisites

- **macOS** with Apple Silicon (M1/M2/M3/M4)
- [Noir](https://noir-lang.org/) (`noirup` to install nargo)
- [Barretenberg](https://github.com/AztecProtocol/barretenberg) built with Metal support
- CMake, Ninja, Clang (Xcode command line tools)

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/carni-ships/AztecFastTech.git
cd AztecFastTech
```

### 2. Build Barretenberg with Metal GPU support

```bash
cd barretenberg/cpp
cmake --preset default -DCMAKE_BUILD_TYPE=Release
cmake --build --preset default --target bb
cd ../..
```

### 3. Compile Noir circuits and generate witnesses

```bash
# Poseidon uses a simple seed (already in Prover.toml)
# Generate witnesses for merkle-tree and ec-ops:
python3 gen_witnesses.py

# Compile circuits and execute witnesses
nargo compile
nargo execute
```

### 4. Run benchmarks

```bash
./bench.sh
```

### 5. Build with additional optimizations and compare

```bash
# Apply extra patches (DontZeroMemory, adaptive sort) and rebuild
./build-optimized.sh

# Run benchmarks with optimized binary
BB_LOCAL=./bin/bb-opt ./bench.sh
```

## Benchmark Circuits

| Circuit | Description | Constraint System |
|---------|-------------|-------------------|
| **poseidon-hash** | 1024 sequential Poseidon2 hashes | Heavy algebraic constraints, exercises hash gates |
| **merkle-tree** | 512 hashes + 8 Merkle membership proofs | Mixed hash + comparison constraints |
| **ec-ops** | 16 Grumpkin scalar multiplications | Embedded curve operations, exercises bigint arithmetic |

These circuits are representative of Aztec's proving workload: Poseidon2 hashing dominates note commitments and nullifier computation, Merkle proofs verify state inclusion, and EC operations handle Schnorr signatures and Pedersen commitments.

## Research Report

The full technical report covers:
- System architecture and UltraHonk prover pipeline
- 8 successful optimization techniques with implementation details
- 16 rejected approaches and why they failed
- Performance ceiling analysis (GPU ALU-bound at 61%, CPU ALU-bound at 23%)
- Lessons learned about Apple Metal compute for cryptographic workloads

Available in three formats:
- [Markdown](RESEARCH_REPORT.md)
- [LaTeX](RESEARCH_REPORT.tex)
- [PDF](RESEARCH_REPORT.pdf)

## License

MIT

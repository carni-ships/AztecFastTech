# AztecFastTech: GPU-Accelerated ZK Proving on Apple Silicon

Hardware-accelerated UltraHonk (BN254) proving using Apple Metal compute shaders on M-series chips. This project benchmarks GPU-accelerated proving on both synthetic circuits and real Aztec protocol circuits.

## Results

### Synthetic Circuits (Aztec-representative operations)

Wall clock time including circuit construction, proving, and I/O:

| Circuit | Gates | Baseline (CPU) | Optimized (Metal GPU) | Speedup |
|---------|------:|---------------:|----------------------:|--------:|
| Poseidon hash chain | 75K | 538ms | 310ms | 1.7x |
| Merkle tree proofs | 44K | 343ms | 270ms | 1.3x |
| EC scalar muls | 30K | 265ms | 210ms | 1.3x |

The research report measures `construct_proof` time (cryptographic proving only, excluding I/O): **148ms** for the 75K-gate Poseidon circuit and **815ms** for the 428K-gate production circuit, representing **5.1x** and **3.6x** speedups respectively over stock Barretenberg.

### Real Aztec Protocol Circuits (from aztec-packages v4.1.2)

| Circuit | Gates | Baseline (CPU) | Optimized (Metal GPU) | Speedup |
|---------|------:|---------------:|----------------------:|--------:|
| parity-base | 2.27M | ~13.4s | ~12.0s | 1.12x |

The `parity-base` circuit computes SHA256 + Poseidon Merkle roots over 256 L1-to-L2 messages. At 2.27M gates it is the largest UltraHonk circuit benchmarked. GPU acceleration offloads all 10 PCS-phase MSMs (including 3 at n=4,194,304), reducing CPU utilization by 52% (94.6s → 45.7s user time).

**Hardware:** Apple M3 Pro (18-core GPU, 18GB unified memory)

### Hardware Requirements: Aztec Official vs AztecFastTech

Aztec's official prover infrastructure requires [server-class hardware](https://docs.aztec.network/the_aztec_network/guides/run_nodes/how_to_run_prover):

| Resource | Aztec Prover Agent | AztecFastTech (M3 Pro laptop) | Reduction |
|----------|-------------------|--------------------------|-----------|
| **CPU** | 32 cores / 64 vCPU | 12 cores (6P+6E) | 5.3x fewer cores |
| **RAM** | 128 GB | 18 GB | 7x less memory |
| **GPU** | None (CPU-only) | 18-core Apple GPU | Novel acceleration |
| **Cluster** | ~40 machines | 1 laptop | 40x fewer machines |

Aztec's proving pipeline is entirely CPU-based. A full prover cluster requires approximately 40 machines, each with 32+ cores and 128GB RAM. By offloading multi-scalar multiplication to the Metal GPU, AztecFastTech achieves competitive proving times on a single consumer laptop with 7x less RAM — from transaction-sized circuits (30K-429K gates) up to the 2.27M-gate parity-base circuit.

> **Note:** Aztec's root rollup circuit (13M gates, dyadic size 2^24) requires an estimated 25-42 GiB of proving memory — beyond 18GB consumer hardware. The gains here apply to circuits up to ~4M dyadic size: client-side proofs, transaction circuits, parity circuits, and function calls that dominate the proving workload.

## Architecture

The optimization targets Aztec's [Barretenberg](https://github.com/AztecProtocol/barretenberg) UltraHonk prover, specifically the Pippenger MSM algorithm used in polynomial commitment schemes (KZG via Gemini/Shplonk).

17 optimization techniques including:
1. **Metal GPU MSM pipeline** — Pippenger bucket method with 22 GPU kernels for accumulation, reduction, and combination
2. **GLV endomorphism on GPU** — scalar decomposition moved to Metal compute, halving effective scalar width
3. **Count-sorted reduce** — bucket IDs sorted by size to eliminate SIMD thread divergence (60% → 95%+ utilization)
4. **GPU count-sorted mapping (CSM)** — moved CSM from CPU to GPU kernel, eliminating CPU/GPU sync bottleneck
5. **SRS buffer + endomorphism caching** — persistent GPU buffers avoid redundant SRS copies and endomorphism recomputation
6. **Sort-reduce batch overlap** — CPU sorts batch 2 while GPU reduces batch 1, hiding 4ms latency
7. **Per-window bucket imbalance bailout** — detects structured polynomials causing 1000ms+ GPU stalls, falls back to CPU
8. **DontZeroMemory** — skip redundant memory zeroing for polynomials immediately overwritten
9. **Lazy Montgomery reduction** — GPU operates in [0,2p) with boundary normalization, fixing correctness bugs
10. **Batch polynomial commitments** — overlaps GPU and CPU MSMs via `batch_commit`

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
├── setup-aztec-circuits.sh # Fetch and compile real Aztec protocol circuits
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
cd barretenberg/barretenberg/cpp
cmake --preset default -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-O3 -mcpu=native"
cmake --build --preset default --target bb -j$(sysctl -n hw.ncpu)
cd ../../..
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

### Synthetic (Aztec-representative)

| Circuit | Description | Gates |
|---------|-------------|------:|
| **poseidon-hash** | 1024 sequential Poseidon2 hashes | 75K |
| **merkle-tree** | 512 hashes + 8 Merkle membership proofs | 44K |
| **ec-ops** | 16 Grumpkin scalar multiplications | 30K |

These exercise the core operations in Aztec's proving workload: Poseidon2 hashing (note commitments, nullifiers), Merkle proofs (state inclusion), and EC operations (Schnorr signatures, Pedersen commitments).

### Real Aztec Protocol Circuits

| Circuit | Description | Gates | Source |
|---------|-------------|------:|--------|
| **parity-base** | SHA256 + Poseidon Merkle root over 256 L1-to-L2 messages | 2.27M | aztec-packages v4.1.2 |

Pre-compiled artifacts are included in `target/`. To regenerate from source, see [aztec-packages](https://github.com/AztecProtocol/aztec-packages) at tag `v4.1.2`.

## Building a GPU-Accelerated Aztec Prover

You can use this repo to build a Metal-accelerated `bb` binary that serves as a drop-in replacement for Barretenberg's stock prover. This works with any Noir circuit targeting the UltraHonk backend.

### Build the prover

```bash
git clone --recurse-submodules https://github.com/carni-ships/AztecFastTech.git
cd AztecFastTech

# Build barretenberg with Metal GPU support
cd barretenberg/barretenberg/cpp
cmake --preset default -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-O3 -mcpu=native"
cmake --build --preset default --target bb -j$(sysctl -n hw.ncpu)
cd ../../..
```

The resulting binary is at `barretenberg/barretenberg/cpp/build/bin/bb`.

### Use with any Noir circuit

```bash
# Compile your circuit
nargo compile

# Execute witness
nargo execute

# Prove (GPU acceleration is automatic — no flags needed)
bb prove -b target/<circuit>.json -w target/<circuit>.gz -o proof

# Verify
bb verify -k vk -p proof/proof -i proof/public_inputs
```

The GPU pipeline activates automatically for MSMs with 32K+ points (typical for circuits above ~60K gates). Smaller circuits stay on CPU where it's faster. If the GPU encounters bucket imbalance (common with structured witness polynomials), it falls back to CPU transparently.

### Use with Aztec protocol circuits

```bash
# Fetch and compile real Aztec circuits (requires nargo 1.0.0-beta.18+)
./setup-aztec-circuits.sh

# Prove parity-base (2.27M gates)
bb prove -b target/parity_base.json -w target/parity_base.gz -o proof
```

### Apply additional optimizations

```bash
# Build with DontZeroMemory and other patches
./build-optimized.sh

# Use the optimized binary
./bin/bb-opt prove -b target/<circuit>.json -w target/<circuit>.gz -o proof
```

### Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Xcode command line tools (for Metal compiler and C++ toolchain)
- CMake and Ninja (`brew install cmake ninja`)
- [Noir](https://noir-lang.org/) nargo (`noirup` to install) — for circuit compilation only

### Environment variables

| Variable | Effect |
|----------|--------|
| `BB_NO_GPU=1` | Disable GPU, use CPU-only proving |
| `BB_GPU_PROFILE=1` | Print per-MSM GPU timing |
| `BB_GPU_PROFILE=2` | Print per-phase GPU timing (glv, sort, csm, reduce, sum, combine) |

## Research Report

The full technical report covers:
- System architecture and UltraHonk prover pipeline
- 17 successful optimization techniques with implementation details
- 16 rejected approaches with measured evidence
- Performance ceiling analysis (GPU ALU-bound at 61%, CPU ALU-bound at 23%)
- Lessons learned about Apple Metal compute for cryptographic workloads

Available in three formats:
- [Markdown](RESEARCH_REPORT.md)
- [LaTeX](RESEARCH_REPORT.tex)
- [PDF](RESEARCH_REPORT.pdf)

## License

MIT

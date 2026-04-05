# AztecFastTech

Optimized Aztec epoch prover for Apple Silicon. Proves full epochs on Sepolia testnet within the 20-minute window on an 18 GiB M3 Pro.

## What This Does

Runs a prover node against the Aztec testnet that picks up epochs, generates ~98 UltraHonk proofs across 6 circuit types, and submits the epoch proof to Sepolia L1.

Key optimizations over stock Barretenberg:
- **Streaming low-memory proving** — serialize/free/mmap-reload to fit 13M-gate root rollup in 18 GiB
- **Multi-agent parallelism** — 3 agents with file-backed memory for deeper merge-tree overlap
- **Precomputed poly cache** — VK-keyed disk cache eliminates recomputation across agents
- **Block-based sumcheck masking** — 40-55% DRAM bandwidth saved, ~11% sumcheck speedup
- **22% total proving speedup** from algorithmic optimizations (no GPU)

Full optimization inventory: [docs/optimizations.md](docs/optimizations.md)

## Pre-built Binaries (Apple Silicon)

Download optimized `bb` and `bb-avm` binaries — no build step required:

```bash
curl -L https://github.com/carni-ships/AztecFastTech/releases/download/v0.1.0/bb -o bb
curl -L https://github.com/carni-ships/AztecFastTech/releases/download/v0.1.0/bb-avm -o bb-avm
chmod +x bb bb-avm
```

Requires Apple Silicon (M1/M2/M3/M4) and macOS 13+. No additional dependencies — all libraries are system-provided.

<details>
<summary>SHA-256 checksums</summary>

```
699335b9f4ea0fb6af7938d2d27c13523d5036bb3683b457e315bb2fcc01b0f0  bb
d41fafbaec722f44b94cfa493543902d99eb91c2166552936c72ae42480610cc  bb-avm
```
</details>

Or build from source with `scripts/build-optimized.sh`.

## Prerequisites

1. **Sepolia ETH** in the prover wallet (for L1 proof submissions)
2. **Aztec CLI** installed at `~/.aztec/current`
3. **bb-avm binary** — use the [pre-built download](#pre-built-binaries-apple-silicon) above, or build from `aztec-packages-v4.1.2/barretenberg/cpp`:
   ```bash
   cd aztec-packages-v4.1.2/barretenberg/cpp
   cmake --preset default -DCMAKE_BUILD_TYPE=Release
   cmake --build --preset default --target bb-avm -j$(sysctl -n hw.ncpu)
   ```
4. **acvm binary** built from `aztec-packages-v4.1.2/noir/noir-repo`:
   ```bash
   cd aztec-packages-v4.1.2/noir/noir-repo
   RUSTFLAGS="-C target-cpu=native" cargo build --release -p acvm_cli
   ```
5. **Prover wallet** configured in `.secrets/prover-wallet.env`:
   ```bash
   PROVER_PRIVATE_KEY=0x...
   PROVER_ADDRESS=0x...
   ```

## Start the Prover

```bash
# Dry run (print config without starting)
./scripts/start-prover.sh --dry-run

# Start prover node + broker (auto-detects agent config based on RAM)
SPLIT_BROKER=1 ./scripts/start-prover.sh

# Override agent/thread config
PROVER_AGENTS=3 PROVER_THREADS=4 SPLIT_BROKER=1 ./scripts/start-prover.sh
```

Agent configuration is auto-detected based on available RAM:

| RAM | Config | Epoch Time | Notes |
|-----|--------|-----------|-------|
| <18 GiB | 2 agents x 6 threads | ~19 min | Safe default |
| 18+ GiB | 3 agents x 4 threads | ~13 min | Deeper merge-tree parallelism |
| 36+ GiB | 4 agents x 3 threads | ~10 min | Maximum parallelism |

## Architecture

```
Broker (port 8079) <-- Prover Node (port 8180)
                           |-- Agent 1 (N threads)
                           |-- Agent 2 (N threads)
                           +-- Agent 3 (N threads)  [if 18+ GiB RAM]
```

Each epoch requires ~98 proving jobs across circuit types:

| Circuit | Count | Size | Time (each) |
|---------|-------|------|-------------|
| PRIVATE_TX_BASE_ROLLUP | ~32 | 2^22 | ~30s |
| PARITY_BASE | ~16 | 2^16 | ~3s |
| BLOCK_MERGE | ~16 | 2^22 | ~25s |
| CHECKPOINT_MERGE | ~8 | 2^22 | ~25s |
| CHECKPOINT_ROOT | 1 | 2^23 | ~60s |
| ROOT_ROLLUP | 1 | 2^24 (13M gates) | ~300s |

### Epoch Proving DAG

```
Leaf proofs (BASE_ROLLUP x ~32)  --+
                                    +-- Block merges (BLOCK_MERGE x ~16)
Parity proofs (PARITY_BASE x ~16) -+
                                    +-- Checkpoint merges (CHECKPOINT_MERGE x ~8)
                                    +-- Checkpoint root (CHECKPOINT_ROOT x 1)
                                    +-- Root rollup (ROOT_ROLLUP x 1, ~5 min, 13M gates)
```

The **root rollup is always the critical path**. The optimal strategy is finishing all dependencies ASAP so the single long root rollup starts as early as possible.

## Operational Scripts

| Script | Purpose |
|--------|---------|
| `scripts/start-prover.sh` | Main entrypoint with auto-config |
| `scripts/monitor-prover.sh` | Auto-restart crash monitor |
| `scripts/epoch-stats.sh` | Per-circuit timing breakdown |
| `scripts/track-epoch-timing.sh` | Epoch time tracking with buffer calculation |
| `scripts/monitor-metrics.sh` | Live performance dashboard |
| `scripts/warmup-epoch.sh` | Pre-warm proving caches |
| `scripts/setup-ramdisk.sh` | Optional RAM disk for scratch files |
| `scripts/compact-archiver.sh` | Prune archiver DB |
| `scripts/build-optimized.sh` | Build bb-avm with optimizations |

## Proven Epochs

**Epoch 1093** (checkpoints 28774-28804) — first fully completed epoch:
- **Tx**: [`0xa975cc...`](https://sepolia.etherscan.io/tx/0xa975cce09a223a845c520a5ac4678bbad6e6a126180a55cce4fd999fbe319305) (Sepolia block 10584707)
- **82 proofs, 0 errors** across all circuit types
- **Prover**: `0xe8fd052579c6552328f0aa316D1B341EaB5Fd42b`

**Epoch 1129** — second completed epoch, confirmed all optimizations proof-compatible.

## Hardware

| Component | Spec |
|-----------|------|
| CPU | Apple M3 Pro (12-core) |
| RAM | 18 GiB unified |
| SSD | ~7 GB/s APFS |
| GPU | Metal (disabled — CPU 2x faster for MSM at these sizes) |

## Noir Prover SDK

The generic Noir prover SDK (circuit-agnostic proving, adapter pattern, Persistia reference implementation) lives on the [`persistia-sdk`](../../tree/persistia-sdk) branch.

## License

MIT

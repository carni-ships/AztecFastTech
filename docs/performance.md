# Prover Stack Performance & Resource Requirements

Measured on Aztec testnet epochs 1129-1130 (2026-04-04). All data from production proving runs.

## Hardware

| Component | Spec |
|-----------|------|
| CPU | Apple M3 Pro (12 cores: 6P + 6E) |
| RAM | 18 GiB unified memory |
| SSD | ~7 GB/s sequential (Apple internal NVMe) |
| OS | macOS 26.3.0 (Darwin) |

## Software Stack

| Component | Version / Detail |
|-----------|-----------------|
| Aztec CLI | 4.1.3 |
| bb binary | Custom `bb-avm` (84 MB), commit `9c4ad91d5d` |
| Compiler | Apple Clang (CommandLineTools), `-O3 -mcpu=native -flto=thin` |
| ACVM | Custom build from aztec-packages v4.1.2 |
| Node.js | Aztec's bundled runtime |
| Network | Sepolia L1 (14 public RPCs, 9 typically healthy) |

## Epoch Proving Performance

An epoch is 32 L2 slots. Each epoch produces ~100-120 proving jobs across the circuit tree.

| Metric | Epoch 1129 | Epoch 1130 |
|--------|-----------|-----------|
| Wall time | 20 min 31s | 16 min 59s |
| Proofs generated | 117 | ~100 |
| Errors | 0 | 0 |
| Agents | 1 (swap-reduced) | 1 |
| Threads per agent | 6 | 6 |
| L1 gas (submit) | 3,509,423 | 3,509,581 |
| L1 gas price | 123 gwei | 196 gwei |

Epoch 1129 was slower due to cold start (first proofs after restart, SRS loading, no poly cache).

With the default 3-agent config (3x4), epoch completion is projected at ~11-12 minutes.

## Per-Circuit Proof Timings

Averaged across epochs 1129-1130 (1 agent, 6 threads). Times include witness generation, proving, and verification.

| Circuit | Avg Time | Count | Dyadic Size | Notes |
|---------|----------|-------|-------------|-------|
| RootRollup | 89,436ms | 2 | 2^24 | Final epoch proof; runs solo |
| PublicTxBaseRollup | 95,974ms | 4 | 2^22 | Includes recursive AVM verify |
| CheckpointRootSingleBlock | 42,553ms | 64 | 2^23 | Most common large circuit |
| PublicChonkVerifier | 31,382ms | 7 | 2^22 | Chonk (batched public tx) verifier |
| ParityBase | 22,486ms | 3 | 2^22 | L1-to-L2 message parity |
| TxMerge | 21,473ms | 2 | 2^21 | Transaction merge rollup |
| ParityRoot | 18,294ms | 2 | 2^22 | Parity tree root |
| BlockRootFirst | 15,737ms | 1 | 2^22 | First block in epoch |
| CheckpointMerge | 14,973ms | 60 | 2^21 | Merge tree (high count) |
| AVM circuits | 10,855-20,450ms | 5 | 2^21 | Application VM proofs |
| BlockRootEmptyTxFirst | 7,361ms | 63 | 2^20 | Empty block rollup (most frequent) |

## Proof Phase Breakdown (CheckpointRoot, 2^23)

| Phase | Time | % |
|-------|------|---|
| Oink (commitments) | ~13,700ms | 32% |
| - CK init | ~350ms | |
| - Preamble + wires | ~4,900ms | |
| - Sorted list | ~3,000ms | |
| - Logderiv + grand product + commits | ~5,400ms | |
| Sumcheck | ~5,200ms | 12% |
| PCS (Gemini + Shplonk) | ~23,600ms | 56% |
| **Total** | ~42,500ms | |

PCS dominates at 2^23 due to larger polynomials requiring more Gemini fold rounds and heavier Shplonk MSM.

## Peak Memory Usage

Virtual memory per circuit (with `BB_SLOW_LOW_MEMORY=1` for file-backed polynomials). macOS manages physical memory via paging; only the working set needs to fit in RAM.

| Circuit | Peak Virtual Memory |
|---------|-------------------|
| RootRollup (2^24) | 11,261 MiB |
| CheckpointRootSingleBlock (2^23) | 8,854 MiB |
| PublicTxBaseRollup (2^22) | 8,715 MiB |
| ParityRoot (2^22) | 5,847 MiB |
| ParityBase (2^22) | 5,328 MiB |
| BlockRootFirst (2^22) | 4,262 MiB |
| PublicChonkVerifier (2^22) | 3,391 MiB |
| TxMerge (2^21) | 3,034 MiB |
| CheckpointMerge (2^21) | 2,987 MiB |
| BlockRootEmptyTxFirst (2^20) | 1,477 MiB |

## Agent Configurations

The start script auto-selects based on available RAM and current memory pressure:

| Config | Agents x Threads | RAM Requirement | Use Case |
|--------|-----------------|-----------------|----------|
| Maximum | 4 x 3 | >= 36 GiB | Full parallelism |
| Default | 3 x 4 | >= 18 GiB | Best for M3 Pro (file-backed memory) |
| Conservative | 2 x 6 | < 18 GiB | Low memory machines |
| Minimal | 1 x 6 | Under pressure | Auto-fallback when swap > 1 GiB |

All configs use `BB_SLOW_LOW_MEMORY=1` for mmap-backed polynomial allocation.

## Disk Usage

| Component | Size | Path |
|-----------|------|------|
| Prover data (LMDB) | ~680 MB | `.prover-data/` |
| BB working directory | ~1.4 GB | `/tmp/aztec-prover-bb/` |
| SRS (CRS) | 2.0 GB | `~/.bb-crs/` |
| bb-avm binary | 84 MB | `barretenberg/cpp/build/bin/bb-avm` |
| Aztec CLI | ~2.5 GB | `~/.aztec/versions/4.1.3/` |
| **Total** | **~6.7 GB** | |

## Network Requirements

- **L1 RPC**: 14 Sepolia endpoints configured; 9 typically healthy. Archiver polls every 2s, batches of 500 checkpoints during sync.
- **Aztec node**: `rpc.testnet.aztec-labs.com` for L2 block data.
- **Blob store**: `aztec-labs-snapshots.com` for checkpoint blob data.
- **L1 submission**: ~3.5M gas per epoch proof (~15.9 KB calldata). At 100-200 gwei, costs ~0.35-0.70 Sepolia ETH per submission.

## Key Environment Variables

```bash
BB_SLOW_LOW_MEMORY=1              # File-backed polynomial allocation
PROVER_AGENT_POLL_INTERVAL_MS=100 # Fast job pickup (~44s/epoch saved)
ARCHIVER_POLLING_INTERVAL_MS=2000 # Reduce L1 RPC pressure
ARCHIVER_BATCH_SIZE=500           # Fewer RPC calls during sync
ARCHIVER_STORE_MAP_SIZE_KB=409600 # 400 MB archiver DB cap
HARDWARE_CONCURRENCY=4            # Threads per agent (or 6 for 1-2 agents)
PROVER_BROKER_MAX_EPOCHS_TO_KEEP_RESULTS_FOR=1  # Limit broker memory
```

## Build Instructions

```bash
# From aztec-packages-v4.1.2/barretenberg/cpp/
cmake --preset default  # Uses -O3 -mcpu=native -flto=thin
cmake --build --preset default --target bb-avm
```

Build takes ~8-12 minutes (compile) + ~5-8 minutes (ThinLTO link). The link phase uses ~5 GB RAM.

## Proof Submission History

| Epoch | Date | TX Hash | Gas | Status |
|-------|------|---------|-----|--------|
| 1093 | 2026-04-03 | `0xa975cc...` | 3,505,795 | Accepted |
| 1129 | 2026-04-04 | `0xad24c5...` | 3,509,423 | Accepted |
| 1130 | 2026-04-04 | `0x523f9d...` | 3,509,581 | Accepted |

Prover address: `0xe8fd052579c6552328f0aa316D1B341EaB5Fd42b`

Testnet rewards are not yet funded (reward distributor contract has 0 balance as of 2026-04-04).

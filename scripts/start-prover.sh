#!/bin/bash
# Start an Aztec prover node against testnet using our optimized bb binary.
#
# Prerequisites:
#   - Sepolia ETH in the prover wallet (for L1 proof submissions)
#   - aztec CLI installed (~/.aztec/current)
#
# Usage:
#   ./scripts/start-prover.sh
#   ./scripts/start-prover.sh --dry-run    # print config without starting

set -e

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AZTEC=~/.aztec/current/node_modules/.bin/aztec

# --- Agent/thread configuration ---
# 3×4: default for 18+ GiB with file-backed memory (BB_SLOW_LOW_MEMORY=1)
#       ~30% faster epochs via deeper merge-tree parallelism vs 2×6.
#       File-backed polynomials let macOS page intelligently; M3 SSD (~7 GB/s)
#       handles minor swap with negligible impact vs 30% epoch speedup.
#       Root rollup (2^24) always runs last (solo agent), no memory contention.
# 4×3: for 36+ GiB machines (maximum parallelism)
# 2×6: fallback for <18 GiB or high memory pressure
PROVER_AGENTS="${PROVER_AGENTS:-3}"
PROVER_THREADS="${PROVER_THREADS:-4}"

# Enable file-backed polynomial allocation: mmap'd temp files let macOS manage
# physical memory via paging. Critical for multi-agent proving on 18 GiB.
# At 2^22 (most epoch circuits): 3 agents × ~5.2 GiB virtual = 15.6 GiB,
# with file-backed mmap the OS keeps only the working set in RAM.
export BB_SLOW_LOW_MEMORY=1

# Reduce agent poll interval from default 1000ms to 100ms.
# With 98 proofs/epoch, default 1000ms wastes ~49s on average idle-to-pickup time.
# At 100ms: ~5s total idle time. Net saving: ~44s per epoch.
export PROVER_AGENT_POLL_INTERVAL_MS=100

# Preemptive job dispatch: when an agent heartbeats on a low-priority job
# (e.g., base rollup) and a higher-priority job is queued (e.g., merge rollup),
# the broker tells the agent to abort and switch. Only preempts if the job has
# been running less than this threshold (avoids thrashing near-complete proofs).
export PROVER_BROKER_PREEMPTION_THRESHOLD_MS=2000

# Batch flush: accumulate proving job results and flush in batches
# to reduce DB write contention under high agent concurrency.
export PROVER_BROKER_BATCH_INTERVAL_MS=500
export PROVER_BROKER_BATCH_SIZE=1000

# --- Archiver & broker tuning ---
# Reduce archiver L1 polling to avoid rate-limiting on public RPCs.
# Default 500ms is aggressive; 2000ms cuts L1 queries by 4x during sync.
export ARCHIVER_POLLING_INTERVAL_MS=2000

# Larger batch size = fewer RPC calls during catch-up sync.
# Default is 100 checkpoints/batch; 500 fetches 5x more per call.
export ARCHIVER_BATCH_SIZE=500

# Cap LMDB database sizes to prevent unbounded growth on small machines.
export ARCHIVER_STORE_MAP_SIZE_KB=409600       # 400 MB archiver DB cap
export WS_DB_MAP_SIZE_KB=512000                # 500 MB world state cap
export WS_NUM_HISTORIC_CHECKPOINTS=8           # Keep only recent checkpoints

# Broker: only retain proving jobs from the last epoch. Cleans up 600-750MB
# of old job data from prior epochs that gets loaded into memory on startup.
export PROVER_BROKER_MAX_EPOCHS_TO_KEEP_RESULTS_FOR=1

# Auto-detect agent count based on available RAM and current memory pressure
if [ -z "${PROVER_AGENTS+x}" ] || [ "$PROVER_AGENTS" = "3" ]; then
  TOTAL_MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}')

  # Check current memory pressure (macOS: vm_stat free+inactive pages)
  FREE_MEM_GB=0
  if command -v vm_stat >/dev/null 2>&1; then
    # Sum free + inactive pages (available for use without swap)
    FREE_PAGES=$(vm_stat | awk '/Pages free|Pages inactive/ {gsub(/\./,"",$NF); sum+=$NF} END {print sum}')
    PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
    FREE_MEM_GB=$(echo "$FREE_PAGES $PAGE_SIZE" | awk '{printf "%d", ($1 * $2) / 1073741824}')
  fi

  if [ "$TOTAL_MEM_GB" -ge 36 ] 2>/dev/null; then
    # 36+ GiB: 4 agents × 3 threads (maximum parallelism)
    PROVER_AGENTS=4
    PROVER_THREADS=3
  elif [ "$TOTAL_MEM_GB" -lt 18 ] 2>/dev/null; then
    # <18 GiB: 2 agents × 6 threads (conservative)
    PROVER_AGENTS=2
    PROVER_THREADS=6
  elif [ "$FREE_MEM_GB" -lt 6 ] 2>/dev/null && [ "$FREE_MEM_GB" -gt 0 ]; then
    # Under memory pressure (<6 GiB free): reduce to 1 agent
    PROVER_AGENTS=1
    PROVER_THREADS=6
    echo "WARNING: Low available memory (${FREE_MEM_GB} GiB free). Using 1 agent to avoid swap."
  fi

  # Detect active swap usage — swap kills proving performance (10-100x slower)
  SWAP_USED_MB=0
  if command -v sysctl >/dev/null 2>&1; then
    SWAP_USED_MB=$(sysctl -n vm.swapusage 2>/dev/null | awk -F'[= ]+' '/used/ {for(i=1;i<=NF;i++) if($i=="used") {gsub(/M/,"",$(i+1)); printf "%d", $(i+1)}}' || echo "0")
  fi
  if [ "$SWAP_USED_MB" -gt 1024 ] 2>/dev/null; then
    echo "WARNING: ${SWAP_USED_MB} MB swap in use. Proving performance will be severely degraded."
    echo "  Consider closing other applications or reducing agent count."
    if [ "$PROVER_AGENTS" -gt 1 ]; then
      PROVER_AGENTS=1
      PROVER_THREADS=6
      echo "  Auto-reduced to 1 agent to minimize swap pressure."
    fi
  elif [ "$SWAP_USED_MB" -gt 256 ] 2>/dev/null; then
    echo "NOTE: ${SWAP_USED_MB} MB swap in use. Monitor for performance impact."
  fi
fi

# --- Config ---
source "$BASE_DIR/.secrets/prover-wallet.env"

# BB binary — optimized build with AVM support (bb-avm is a superset of bb)
# Fallback bundled bb: "$HOME/.aztec/versions/4.1.3/node_modules/@aztec/bb.js/build/arm64-macos/bb"
# Non-AVM only: "$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb"
BB_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb-avm"

# ACVM binary (Noir witness executor)
ACVM_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/noir/noir-repo/target/release/acvm"

# Sepolia L1 RPCs — multiple endpoints for rotation when rate-limited.
# The archiver hits L1 heavily during sync; public RPCs enforce per-IP rate limits.
# ETHEREUM_HOSTS accepts comma-separated URLs; the client rotates on failure.
SEPOLIA_RPCS=(
  "https://ethereum-sepolia-rpc.publicnode.com"
  "https://rpc.sepolia.org"
  "https://sepolia.drpc.org"
  "https://1rpc.io/sepolia"
  "https://endpoints.omniatech.io/v1/eth/sepolia/public"
  "https://eth-sepolia.public.blastapi.io"
  "https://rpc2.sepolia.org"
  "https://rpc.sepolia.ethpandaops.io"
  "https://ethereum-sepolia.rpc.subquery.network/public"
  "https://0xrpc.io/sep"
  "https://eth-sepolia.api.onfinality.io/public"
  "https://gateway.tenderly.co/public/sepolia"
  "https://ethereum-sepolia-public.nodies.app"
  "https://rpc.notadegen.com/eth/sepolia"
)
# Join with commas for ETHEREUM_HOSTS
L1_RPC=$(IFS=,; echo "${SEPOLIA_RPCS[*]}")

# Aztec testnet node
AZTEC_NODE_URL="https://rpc.testnet.aztec-labs.com"

# Working directories
BB_WORK_DIR="/tmp/aztec-prover-bb"
ACVM_WORK_DIR="/tmp/aztec-prover-acvm"
DATA_DIR="$BASE_DIR/.prover-data"

mkdir -p "$BB_WORK_DIR" "$ACVM_WORK_DIR" "$DATA_DIR"

# --- Sync gap check ---
# Estimate if incremental sync is feasible or if we should warn about snapshot
ARCHIVER_DB="$DATA_DIR/archiver"
if [ -d "$ARCHIVER_DB" ]; then
  # Get local checkpoint from last known sync
  LOCAL_CHECKPOINT=$(grep -o '"currentL2Checkpoint":[0-9]*' "$DATA_DIR/prover.log" 2>/dev/null | tail -1 | sed 's/.*://')
  if [ -n "$LOCAL_CHECKPOINT" ]; then
    # Query current pending checkpoint from L1 via Aztec node (5s timeout)
    REMOTE_TIP=$(curl -s --max-time 5 "$AZTEC_NODE_URL" -X POST -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' 2>/dev/null | \
      grep -o '"pending":{[^}]*}' | grep -o '"number":[0-9]*' | head -1 | sed 's/.*://')
    if [ -n "$REMOTE_TIP" ] && [ -n "$LOCAL_CHECKPOINT" ]; then
      GAP=$((REMOTE_TIP - LOCAL_CHECKPOINT))
      if [ "$GAP" -gt 5000 ]; then
        echo "WARNING: Large sync gap detected: ${GAP} checkpoints behind (local: ${LOCAL_CHECKPOINT}, remote: ${REMOTE_TIP})"
        echo "  Incremental sync may take a very long time with public RPCs."
        echo "  Consider: 1) Using paid RPCs (Infura/Alchemy) for faster sync"
        echo "            2) Deleting $ARCHIVER_DB and re-syncing from a snapshot (if available)"
        echo "            3) Using HyperSync (Envio) for fast historical event fetching"
        echo ""
      elif [ "$GAP" -gt 500 ]; then
        echo "NOTE: Sync gap: ${GAP} checkpoints behind. Should catch up in ~$((GAP / 10)) minutes with parallel fetch."
      else
        echo "  Sync gap: ${GAP} checkpoints (should catch up quickly)"
      fi
    fi
  fi
fi

# --- Validation ---
if [ ! -f "$BB_BINARY" ]; then
  echo "ERROR: bb binary not found at $BB_BINARY"
  echo "Build with: cd aztec-packages-v4.1.2/barretenberg/cpp && cmake --build --preset default --target bb"
  exit 1
fi

if [ ! -f "$ACVM_BINARY" ]; then
  echo "ERROR: acvm binary not found at $ACVM_BINARY"
  echo "Build with: cd aztec-packages-v4.1.2/noir/noir-repo && cargo build --release -p acvm_cli"
  exit 1
fi

if [ -z "$PROVER_PRIVATE_KEY" ]; then
  echo "ERROR: No prover wallet configured. Run wallet setup first."
  exit 1
fi

echo "=== Aztec Prover Node ==="
echo "  Network:    testnet"
echo "  L1 RPC:     $L1_RPC"
echo "  Aztec node: $AZTEC_NODE_URL"
echo "  Prover:     $PROVER_ADDRESS"
echo "  Agents:     $PROVER_AGENTS × $PROVER_THREADS threads"
echo "  bb binary:  $BB_BINARY"
echo "  acvm binary: $ACVM_BINARY"
echo "  bb workdir: $BB_WORK_DIR"
echo "  Data dir:   $DATA_DIR"
echo ""

# Check balance
CAST=~/.aztec/current/bin/cast
BALANCE=$($CAST balance "$PROVER_ADDRESS" --rpc-url "$L1_RPC" -e 2>/dev/null || echo "?")
echo "  Sepolia ETH: $BALANCE"
echo ""

if [ "$1" = "--dry-run" ]; then
  echo "[dry-run] Would start prover node + broker + agent with the above config."
  exit 0
fi

# --- Pre-warm ---
# Load SRS file into OS page cache before starting prover.
# First proof of each circuit size triggers SRS read (~1 GB); without page cache,
# this adds ~2-3s of cold I/O. Background cat warms the cache while broker starts.
SRS_FILE="${CRS_PATH:-$HOME/.bb-crs}/bn254_g1.dat"
if [ -f "$SRS_FILE" ]; then
  echo "Pre-warming SRS page cache ($(du -h "$SRS_FILE" | cut -f1))..."
  cat "$SRS_FILE" > /dev/null &
  PREWARM_PID=$!
fi

# Pre-warm poly cache dir and existing cached polys (reduces first-proof I/O)
POLY_CACHE_DIR="/tmp/bb-poly-cache"
mkdir -p "$POLY_CACHE_DIR"
CACHE_SIZE=$(du -sh "$POLY_CACHE_DIR" 2>/dev/null | cut -f1)
if [ -n "$(ls -A "$POLY_CACHE_DIR" 2>/dev/null)" ]; then
  echo "Pre-warming poly cache (${CACHE_SIZE})..."
  find "$POLY_CACHE_DIR" -name '*.bin' -exec cat {} + > /dev/null 2>&1 &
fi

# --- Launch ---
echo "Starting prover node + broker + agent..."
echo ""

export ETHEREUM_HOSTS="$L1_RPC"
export PROVER_PUBLISHER_PRIVATE_KEY="$PROVER_PRIVATE_KEY"
export DATA_DIRECTORY="$DATA_DIR"
export BB_BINARY_PATH="$BB_BINARY"
export BB_WORKING_DIRECTORY="$BB_WORK_DIR"
export ACVM_BINARY_PATH="$ACVM_BINARY"
export ACVM_WORKING_DIRECTORY="$ACVM_WORK_DIR"
export BB_SKIP_CLEANUP=true

# --- Single-process mode (default) vs split mode ---
# Single-process: broker + node + agent in one process. Saves ~200MB RAM.
# Split mode: broker runs separately (set SPLIT_BROKER=1 if single-process fails).
SPLIT_BROKER="${SPLIT_BROKER:-0}"

# Ensure SRS prewarm finished before first proof
if [ -n "${PREWARM_PID:-}" ]; then
  wait "$PREWARM_PID" 2>/dev/null && echo "  SRS page cache warm." || true
fi

# N agents with M threads each: more agents = deeper merge-tree parallelism
# 3×4: default (file-backed memory); 4×3: for 36+ GiB; 2×6: fallback for <18 GiB
export HARDWARE_CONCURRENCY="$PROVER_THREADS"

if [ "$SPLIT_BROKER" = "1" ]; then
  # Split mode: broker as separate process
  BROKER_PORT=8079
  BROKER_URL="http://localhost:$BROKER_PORT"

  echo "Starting prover broker on port $BROKER_PORT..."
  $AZTEC start \
    --prover-broker \
    --network testnet \
    --port "$BROKER_PORT" \
    --rpcMaxBodySize 50mb \
    2>&1 | sed 's/^/[broker] /' &
  BROKER_PID=$!
  echo "  Broker PID: $BROKER_PID"

  echo "  Waiting for broker..."
  for i in $(seq 1 30); do
    if curl -s "$BROKER_URL" >/dev/null 2>&1; then
      echo "  Broker ready."
      break
    fi
    sleep 2
  done

  echo "Starting prover node + agent..."
  export PROVER_BROKER_HOST="$BROKER_URL"

  exec $AZTEC start \
    --prover-node \
    --prover-agent \
    --network testnet \
    --p2p-enabled false \
    --port 8180 \
    --rpcMaxBodySize 50mb \
    --proverNode.nodeUrl "$AZTEC_NODE_URL" \
    --proverNode.proverId "$PROVER_ADDRESS" \
    --proverAgent.proverAgentCount "$PROVER_AGENTS"
else
  # Single-process mode: all components in one process (saves ~200MB RAM)
  echo "Starting prover (node + broker + agent, single process)..."

  exec $AZTEC start \
    --prover-node \
    --prover-broker \
    --prover-agent \
    --network testnet \
    --p2p-enabled false \
    --port 8180 \
    --rpcMaxBodySize 50mb \
    --proverNode.nodeUrl "$AZTEC_NODE_URL" \
    --proverNode.proverId "$PROVER_ADDRESS" \
    --proverAgent.proverAgentCount "$PROVER_AGENTS"
fi

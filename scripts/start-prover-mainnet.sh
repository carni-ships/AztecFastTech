#!/bin/bash
# Start an Aztec prover node against MAINNET using our optimized bb binary.
#
# MAINNET: This uses real ETH for L1 gas. Proof submissions earn AZTEC rewards
# but are vulnerable to front-running (proverId from calldata, not msg.sender).
# Flashbots Protect is used by default for private L1 submissions.
#
# Prerequisites:
#   - Real ETH in the prover wallet (for L1 proof submissions)
#   - Ethereum mainnet RPC(s) — paid RPCs strongly recommended
#   - aztec CLI installed (~/.aztec/current)
#
# Usage:
#   ETHEREUM_MAINNET_RPC="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY" ./scripts/start-prover-mainnet.sh
#   ./scripts/start-prover-mainnet.sh --dry-run    # print config without starting
#
# Required env vars:
#   ETHEREUM_MAINNET_RPC  - Primary Ethereum mainnet RPC URL (Alchemy, Infura, etc.)
#
# Optional env vars:
#   AZTEC_MAINNET_NODE_URL  - Aztec mainnet node RPC (if not using P2P)
#   FLASHBOTS_RPC           - Private mempool RPC (default: Flashbots Protect)
#   PROVER_AGENTS           - Number of proving agents (default: auto-detect)
#   PROVER_THREADS          - Threads per agent (default: auto-detect)
#   DISABLE_FLASHBOTS       - Set to 1 to skip Flashbots Protect (not recommended)

set -e

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AZTEC=~/.aztec/current/node_modules/.bin/aztec

# =============================================================================
# MAINNET SAFETY CHECKS
# =============================================================================

# Require explicit mainnet RPC — no public fallbacks for mainnet
if [ -z "${ETHEREUM_MAINNET_RPC:-}" ]; then
  echo "ERROR: ETHEREUM_MAINNET_RPC is required for mainnet proving."
  echo ""
  echo "  Recommended providers (paid tier for reliability):"
  echo "    Alchemy:  https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
  echo "    Infura:   https://mainnet.infura.io/v3/YOUR_KEY"
  echo "    Llamanode: https://eth.llamarpc.com"
  echo ""
  echo "  Usage:"
  echo "    ETHEREUM_MAINNET_RPC=\"https://...\" ./scripts/start-prover-mainnet.sh"
  exit 1
fi

# =============================================================================
# MEV PROTECTION — Flashbots Protect
# =============================================================================
# Proof submissions are vulnerable to front-running: the proverId field in
# submitEpochRootProof calldata can be replaced by a mempool observer.
# Flashbots Protect sends transactions via a private mempool, preventing
# front-running bots from seeing and copying our proof submissions.
#
# How it works: instead of broadcasting to the public mempool, transactions
# go to Flashbots' private relay which includes them directly in blocks.
# Latency: ~1-2 blocks slower than public mempool (12-24s), but proof
# submissions are not time-critical within the epoch window.
FLASHBOTS_RPC="${FLASHBOTS_RPC:-https://rpc.flashbots.net}"

if [ "${DISABLE_FLASHBOTS:-0}" = "1" ]; then
  echo "WARNING: Flashbots Protect DISABLED. Proof submissions will be visible"
  echo "  in the public mempool and vulnerable to front-running."
  echo ""
  # Use only the user-provided mainnet RPC
  L1_RPC="$ETHEREUM_MAINNET_RPC"
else
  # Flashbots Protect as PRIMARY for L1 submissions (private mempool),
  # mainnet RPC as SECONDARY for reads and fallback.
  L1_RPC="${FLASHBOTS_RPC},${ETHEREUM_MAINNET_RPC}"
  echo "  MEV protection: Flashbots Protect enabled (private mempool)"
fi

# =============================================================================
# AGENT/THREAD CONFIGURATION (same as testnet)
# =============================================================================
PROVER_AGENTS="${PROVER_AGENTS:-3}"
PROVER_THREADS="${PROVER_THREADS:-4}"

export BB_SLOW_LOW_MEMORY=1

# --- Scratch directory for file-backed polynomials ---
BB_RAMDISK_SIZE_MB="${BB_RAMDISK_SIZE_MB:-0}"
BB_RAMDISK_PATH="/Volumes/BBScratch"

if [ "$BB_RAMDISK_SIZE_MB" -gt 0 ] 2>/dev/null; then
  if mount | grep -q "$BB_RAMDISK_PATH"; then
    echo "  RAM disk already mounted at $BB_RAMDISK_PATH"
  else
    SECTORS=$((BB_RAMDISK_SIZE_MB * 2048))
    echo "Creating ${BB_RAMDISK_SIZE_MB} MiB RAM disk at $BB_RAMDISK_PATH..."
    DISK_DEV=$(hdiutil attach -nomount ram://$SECTORS 2>/dev/null)
    if [ -n "$DISK_DEV" ]; then
      DISK_DEV=$(echo "$DISK_DEV" | tr -d '[:space:]')
      diskutil erasevolume HFS+ "BBScratch" "$DISK_DEV" >/dev/null 2>&1
      if mount | grep -q "$BB_RAMDISK_PATH"; then
        echo "  RAM disk ready: $BB_RAMDISK_PATH (${BB_RAMDISK_SIZE_MB} MiB)"
      else
        echo "  WARNING: RAM disk format failed. Using default scratch dir."
        hdiutil detach "$DISK_DEV" >/dev/null 2>&1 || true
      fi
    else
      echo "  WARNING: RAM disk creation failed. Using default scratch dir."
    fi
  fi
  if mount | grep -q "$BB_RAMDISK_PATH"; then
    export BB_SCRATCH_DIR="$BB_RAMDISK_PATH"
  fi
elif [ -n "${BB_SCRATCH_DIR:-}" ]; then
  mkdir -p "$BB_SCRATCH_DIR" 2>/dev/null || true
  echo "  Scratch dir: $BB_SCRATCH_DIR"
fi

if [ -n "${BB_SCRATCH_DIR:-}" ] && [ -d "$BB_SCRATCH_DIR" ]; then
  export TMPDIR="$BB_SCRATCH_DIR"
fi

# --- Agent tuning (same as testnet) ---
export PROVER_AGENT_POLL_INTERVAL_MS=100
export PROVER_WITNESS_PREFETCH="${PROVER_WITNESS_PREFETCH:-1}"
export PROVER_BROKER_PREEMPTION_THRESHOLD_MS=2000
export PROVER_BROKER_BATCH_INTERVAL_MS=500
export PROVER_BROKER_BATCH_SIZE=1000
export PROVER_MAX_CONCURRENT_HEAVY="${PROVER_MAX_CONCURRENT_HEAVY:-1}"
export PROVER_MAX_CONCURRENT_LARGE="${PROVER_MAX_CONCURRENT_LARGE:-2}"

# =============================================================================
# MAINNET CONFIG
# =============================================================================
source "$BASE_DIR/.secrets/prover-wallet.env"

# BB binary
BB_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb-avm"

# ACVM binary
ACVM_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/noir/noir-repo/target/release/acvm"

# Aztec mainnet node — either user-provided or use P2P discovery
AZTEC_NODE_URL="${AZTEC_MAINNET_NODE_URL:-}"
USE_P2P=true
if [ -n "$AZTEC_NODE_URL" ]; then
  USE_P2P=false
  echo "  Aztec node: $AZTEC_NODE_URL (direct RPC)"
else
  echo "  Aztec node: P2P discovery (no AZTEC_MAINNET_NODE_URL set)"
fi

# Working directories — separate from testnet to avoid data corruption
BB_WORK_DIR="/tmp/aztec-prover-bb-mainnet"
ACVM_WORK_DIR="/tmp/aztec-prover-acvm-mainnet"
DATA_DIR="$BASE_DIR/.prover-data-mainnet"

mkdir -p "$BB_WORK_DIR" "$ACVM_WORK_DIR" "$DATA_DIR"

# --- Archiver & broker tuning (prover-optimized) ---
# Mainnet: conservative polling to respect paid RPC rate limits
export ARCHIVER_POLLING_INTERVAL_MS="${ARCHIVER_POLLING_INTERVAL_MS:-3000}"
export ARCHIVER_BATCH_SIZE=500
export ARCHIVER_STORE_MAP_SIZE_KB=2097152     # 2 GB archiver DB cap (mainnet has more data)
export WS_DB_MAP_SIZE_KB=1048576              # 1 GB world state cap

# Prover only needs current state — 1 checkpoint saves ~300-400MB vs default 8.
# The prover never replays historical state; it only proves the current epoch.
export WS_NUM_HISTORIC_CHECKPOINTS=1

# Only keep last epoch's proving jobs. Cleans up 600-750MB of stale job data.
export PROVER_BROKER_MAX_EPOCHS_TO_KEEP_RESULTS_FOR=1

# Skip archiver initial sync if already partially synced and gap is small.
# On first run this is ignored (no archiver DB yet). On restarts after short
# downtime, the archiver catches up incrementally during proving — no need
# to block startup waiting for full sync.
ARCHIVER_DB="$DATA_DIR/archiver"
if [ -d "$ARCHIVER_DB" ]; then
  export SKIP_ARCHIVER_INITIAL_SYNC="${SKIP_ARCHIVER_INITIAL_SYNC:-1}"
  if [ "${SKIP_ARCHIVER_INITIAL_SYNC}" = "1" ]; then
    echo "  Archiver: incremental sync (skipping initial block)"
  fi
fi

# Disable debug log collection in prover-only mode (saves memory on proof runs)
export PROVER_REAL_PROOFS=true

# =============================================================================
# AUTO-DETECT AGENT COUNT (same logic as testnet)
# =============================================================================
if [ -n "${PROVER_AGENTS_OVERRIDE:-}" ]; then
  PROVER_AGENTS="$PROVER_AGENTS_OVERRIDE"
elif [ -z "${PROVER_AGENTS+x}" ] || [ "$PROVER_AGENTS" = "3" ]; then
  TOTAL_MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}')

  FREE_MEM_GB=0
  if command -v vm_stat >/dev/null 2>&1; then
    FREE_PAGES=$(vm_stat | awk '/Pages free|Pages inactive/ {gsub(/\./,"",$NF); sum+=$NF} END {print sum}')
    PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
    FREE_MEM_GB=$(echo "$FREE_PAGES $PAGE_SIZE" | awk '{printf "%d", ($1 * $2) / 1073741824}')
  fi

  if [ "$TOTAL_MEM_GB" -ge 36 ] 2>/dev/null; then
    PROVER_AGENTS=4; PROVER_THREADS=3
  elif [ "$TOTAL_MEM_GB" -lt 18 ] 2>/dev/null; then
    PROVER_AGENTS=2; PROVER_THREADS=6
  elif [ "$FREE_MEM_GB" -lt 6 ] 2>/dev/null && [ "$FREE_MEM_GB" -gt 0 ]; then
    PROVER_AGENTS=1; PROVER_THREADS=6
    echo "WARNING: Low available memory (${FREE_MEM_GB} GiB free). Using 1 agent."
  fi

  if [ "${SKIP_MEMORY_CLEANUP:-}" != "1" ]; then
    echo "Pre-flight memory cleanup (set SKIP_MEMORY_CLEANUP=1 to skip)..."
    pkill -f clangd 2>/dev/null && echo "  Killed clangd" || true
    pkill -f SourceKitService 2>/dev/null && echo "  Killed SourceKitService" || true
    pkill -f sourcekit-lsp 2>/dev/null || true
    sudo purge 2>/dev/null && echo "  Flushed page cache" || true
    sleep 2
  fi

  SWAP_USED_MB=0
  if command -v sysctl >/dev/null 2>&1; then
    SWAP_USED_MB=$(sysctl -n vm.swapusage 2>/dev/null | awk -F'[= ]+' '/used/ {for(i=1;i<=NF;i++) if($i=="used") {gsub(/M/,"",$(i+1)); printf "%d", $(i+1)}}' || echo "0")
  fi
  if [ "$SWAP_USED_MB" -gt 2048 ] 2>/dev/null; then
    echo "WARNING: ${SWAP_USED_MB} MB swap in use. Reducing to 1 agent."
    PROVER_AGENTS=1; PROVER_THREADS=6
  elif [ "$SWAP_USED_MB" -gt 256 ] 2>/dev/null; then
    echo "NOTE: ${SWAP_USED_MB} MB swap in use."
  fi
fi

# =============================================================================
# VALIDATION
# =============================================================================
if [ ! -f "$BB_BINARY" ]; then
  echo "ERROR: bb binary not found at $BB_BINARY"
  exit 1
fi

if [ ! -f "$ACVM_BINARY" ]; then
  echo "ERROR: acvm binary not found at $ACVM_BINARY"
  exit 1
fi

if [ -z "$PROVER_PRIVATE_KEY" ]; then
  echo "ERROR: No prover wallet configured."
  exit 1
fi

# =============================================================================
# STATUS DISPLAY
# =============================================================================
echo ""
echo "=== Aztec Prover Node (MAINNET) ==="
echo "  Network:      mainnet (L1 chain ID: 1)"
echo "  L1 RPC:       $(echo "$L1_RPC" | cut -d, -f1) (+$(echo "$L1_RPC" | tr ',' '\n' | wc -l | tr -d ' ') endpoints)"
echo "  MEV protect:  $([ "${DISABLE_FLASHBOTS:-0}" = "1" ] && echo "DISABLED" || echo "Flashbots Protect")"
if [ -n "$AZTEC_NODE_URL" ]; then
  echo "  Aztec node:   $AZTEC_NODE_URL"
else
  echo "  Aztec node:   P2P discovery"
fi
echo "  Prover:       $PROVER_ADDRESS"
echo "  Agents:       $PROVER_AGENTS x $PROVER_THREADS threads"
echo "  bb binary:    $BB_BINARY"
echo "  Data dir:     $DATA_DIR"
echo "  Scratch dir:  ${BB_SCRATCH_DIR:-\$TMPDIR (default)}"
echo ""

# Check mainnet ETH balance
CAST=~/.aztec/current/bin/cast
L1_RPC_FIRST="$(echo "$ETHEREUM_MAINNET_RPC" | cut -d, -f1)"
BALANCE=$($CAST balance "$PROVER_ADDRESS" --rpc-url "$L1_RPC_FIRST" -e 2>/dev/null || echo "?")
echo "  ETH balance:  $BALANCE"

# Warn if balance is low (proof submission costs ~0.005-0.02 ETH per epoch)
if [ "$BALANCE" != "?" ]; then
  LOW_BALANCE=$(echo "$BALANCE" | awk '{print ($1 < 0.05) ? "1" : "0"}')
  if [ "$LOW_BALANCE" = "1" ]; then
    echo "  WARNING: Low ETH balance. Each proof submission costs ~0.005-0.02 ETH."
    echo "  Consider topping up before proving."
  fi
fi

# --- Reward timelock check ---
# The mainnet rollup contract has a 90-day timelock before rewards can be claimed.
# Once the owner calls setRewardsClaimable(true) after the timelock, the atomic
# claim+swap pipeline becomes viable. Until then, proving is gas-only cost.
ROLLUP_CONTRACT="0x603bb2c05d474794ea97805e8de69bccfb3bca12"
REWARDS_CLAIMABLE=$($CAST call "$ROLLUP_CONTRACT" "isRewardsClaimable()(bool)" --rpc-url "$L1_RPC_FIRST" 2>/dev/null || echo "error")
if [ "$REWARDS_CLAIMABLE" = "true" ]; then
  echo "  Rewards:      CLAIMABLE (atomic claim+swap pipeline ready)"
elif [ "$REWARDS_CLAIMABLE" = "false" ]; then
  echo "  Rewards:      LOCKED (90-day timelock active — rewards accumulate but cannot be claimed yet)"
  echo "                Proving costs gas with no immediate revenue until timelock expires."
else
  echo "  Rewards:      Could not query rollup contract (RPC error)"
fi
echo ""

if [ "$1" = "--dry-run" ]; then
  echo "[dry-run] Would start mainnet prover with the above config."
  exit 0
fi

# =============================================================================
# PRE-WARM
# =============================================================================
SRS_FILE="${CRS_PATH:-$HOME/.bb-crs}/bn254_g1.dat"
if [ -f "$SRS_FILE" ]; then
  echo "Pre-warming SRS page cache ($(du -h "$SRS_FILE" | cut -f1))..."
  cat "$SRS_FILE" > /dev/null &
  PREWARM_PID=$!
fi

POLY_CACHE_DIR="${BB_POLY_CACHE_DIR:-/tmp/bb-poly-cache}"
export BB_POLY_CACHE_DIR="$POLY_CACHE_DIR"
mkdir -p "$POLY_CACHE_DIR"
CACHE_ENTRIES=$(find "$POLY_CACHE_DIR" -name '.complete' 2>/dev/null | wc -l | tr -d ' ')
if [ "$CACHE_ENTRIES" -gt 0 ]; then
  CACHE_SIZE=$(du -sh "$POLY_CACHE_DIR" 2>/dev/null | cut -f1)
  echo "Pre-warming poly cache (${CACHE_SIZE}, ${CACHE_ENTRIES} circuit types)..."
  find "$POLY_CACHE_DIR" -name '*.bin' -exec cat {} + > /dev/null 2>&1 &
fi

# --- RAM disk cleanup on exit ---
if mount | grep -q "$BB_RAMDISK_PATH" 2>/dev/null; then
  cleanup_ramdisk() {
    echo "Ejecting RAM disk $BB_RAMDISK_PATH..."
    hdiutil detach "$BB_RAMDISK_PATH" -force 2>/dev/null || true
  }
  trap cleanup_ramdisk EXIT
fi

# =============================================================================
# LAUNCH
# =============================================================================
echo "Starting mainnet prover node..."
echo ""

# Ensure SRS prewarm finished
if [ -n "${PREWARM_PID:-}" ]; then
  wait "$PREWARM_PID" 2>/dev/null && echo "  SRS page cache warm." || true
fi

# Epoch warmup
if [ "${SKIP_EPOCH_WARMUP:-0}" != "1" ] && [ -d "/tmp/bb-file-cache" ]; then
  export BB_WARMUP_DIR="/tmp/bb-file-cache"
  WARMUP_SCRIPT="$BASE_DIR/scripts/warmup-epoch.sh"
  if [ -x "$WARMUP_SCRIPT" ]; then
    echo "Running epoch warmup (background)..."
    BB_BINARY_PATH="$BB_BINARY" "$WARMUP_SCRIPT" &
  fi
fi

export ETHEREUM_HOSTS="$L1_RPC"
export PROVER_PUBLISHER_PRIVATE_KEY="$PROVER_PRIVATE_KEY"
export DATA_DIRECTORY="$DATA_DIR"
export BB_BINARY_PATH="$BB_BINARY"
export BB_WORKING_DIRECTORY="$BB_WORK_DIR"
export ACVM_BINARY_PATH="$ACVM_BINARY"
export ACVM_WORKING_DIRECTORY="$ACVM_WORK_DIR"
export BB_SKIP_CLEANUP=true
export HARDWARE_CONCURRENCY="$PROVER_THREADS"

# Tx collection: if we have a node URL, use it for tx fetching
if [ -n "$AZTEC_NODE_URL" ]; then
  export TX_COLLECTION_NODE_RPC_URLS="$AZTEC_NODE_URL"
fi

# Build CLI args
AZTEC_ARGS=(
  --prover-node
  --prover-broker
  --prover-agent
  --network mainnet
  --port 8180
  --rpcMaxBodySize 50mb
  --proverNode.proverId "$PROVER_ADDRESS"
  --proverAgent.proverAgentCount "$PROVER_AGENTS"
)

if [ "$USE_P2P" = "true" ]; then
  # P2P enabled: discover peers and fetch txs via gossip
  # Mainnet bootnodes are provided by --network mainnet config
  AZTEC_ARGS+=(--p2p-enabled true)
else
  # Direct RPC to a known Aztec node
  AZTEC_ARGS+=(
    --p2p-enabled false
    --proverNode.nodeUrl "$AZTEC_NODE_URL"
  )
fi

echo "Starting prover (node + broker + agent, single process)..."
exec $AZTEC start "${AZTEC_ARGS[@]}"

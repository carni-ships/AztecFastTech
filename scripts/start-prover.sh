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

# --- Config ---
source "$BASE_DIR/.secrets/prover-wallet.env"

# BB binary — optimized build with AVM support (bb-avm is a superset of bb)
# Fallback bundled bb: "$HOME/.aztec/versions/4.1.3/node_modules/@aztec/bb.js/build/arm64-macos/bb"
# Non-AVM only: "$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb"
BB_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb-avm"

# ACVM binary (Noir witness executor)
ACVM_BINARY="$BASE_DIR/../aztec-packages-v4.1.2/noir/noir-repo/target/release/acvm"

# Sepolia L1 RPC (free, reliable)
L1_RPC="https://ethereum-sepolia-rpc.publicnode.com"

# Aztec testnet node
AZTEC_NODE_URL="https://rpc.testnet.aztec-labs.com"

# Working directories
BB_WORK_DIR="/tmp/aztec-prover-bb"
ACVM_WORK_DIR="/tmp/aztec-prover-acvm"
DATA_DIR="$BASE_DIR/.prover-data"

mkdir -p "$BB_WORK_DIR" "$ACVM_WORK_DIR" "$DATA_DIR"

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

# Architecture: broker must run separately from prover-node.
# Start broker on port 8079, then prover-node + agent pointing at it.
BROKER_PORT=8079
BROKER_URL="http://localhost:$BROKER_PORT"

echo "Phase 1: Starting prover broker on port $BROKER_PORT..."
$AZTEC start \
  --prover-broker \
  --network testnet \
  --port "$BROKER_PORT" \
  2>&1 | sed 's/^/[broker] /' &
BROKER_PID=$!
echo "  Broker PID: $BROKER_PID"

# Wait for broker to be ready
echo "  Waiting for broker..."
for i in $(seq 1 30); do
  if curl -s "$BROKER_URL" >/dev/null 2>&1; then
    echo "  Broker ready."
    break
  fi
  sleep 2
done

echo ""
echo "Phase 2: Starting prover node + agent..."
export PROVER_BROKER_HOST="$BROKER_URL"

exec $AZTEC start \
  --prover-node \
  --prover-agent \
  --network testnet \
  --p2p-enabled false \
  --port 8180 \
  --proverNode.nodeUrl "$AZTEC_NODE_URL" \
  --proverNode.proverId "$PROVER_ADDRESS"

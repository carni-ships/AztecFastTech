#!/bin/bash
# Benchmark proving time for an Aztec rollup circuit with dummy witness.
# Usage: ./bench-circuit.sh <circuit_name> [verifier_target]
#
# Examples:
#   ./bench-circuit.sh rollup_tx_merge noir-rollup-no-zk
#   ./bench-circuit.sh rollup_root evm-no-zk
#   ./bench-circuit.sh parity_base noir-recursive-no-zk

set -e

CIRCUIT_NAME=${1:?Usage: bench-circuit.sh <circuit_name> [verifier_target]}
TARGET=${2:-noir-rollup-no-zk}

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BB="${BASE_DIR}/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb"
CIRCUITS="${BASE_DIR}/circuits/target"
WORK="/tmp/aztec-bench-prove/${CIRCUIT_NAME}"

mkdir -p "$WORK"

CIRCUIT_PATH="$CIRCUITS/${CIRCUIT_NAME}.json"
if [ ! -f "$CIRCUIT_PATH" ]; then
  echo "Circuit not found: $CIRCUIT_PATH"
  exit 1
fi

echo "=== Benchmarking ${CIRCUIT_NAME} (target: ${TARGET}) ==="

# Step 1: Get gate count and max witness index
echo -n "Gate count: "
GATES_JSON=$($BB gates -b "$CIRCUIT_PATH" -t "$TARGET" 2>&1)
echo "$GATES_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['functions'][0]['circuit_size'])" 2>/dev/null || echo "?"

# Step 2: Get max_witness_index by trying with 1 witness and reading the error
WITNESS_COUNT=$($BB prove -b "$CIRCUIT_PATH" -w /dev/null -t "$TARGET" -o "$WORK" 2>&1 | grep -oP 'max witness index \+ 1 \(\K\d+' || echo "0")

if [ "$WITNESS_COUNT" = "0" ]; then
  # Parse from gates output or try a different approach
  # Generate a minimal witness and let bb tell us the right size
  cd "$BASE_DIR/prover"
  WITNESS_COUNT=$(npx tsx -e "
import { writeFileSync } from 'fs';
import { gzipSync } from 'zlib';
import { pack } from 'msgpackr';
const wm = new Map(); wm.set(0, Buffer.alloc(32));
const packed = pack([[[0, wm]]]);
const out = Buffer.concat([Buffer.from([2]), packed]);
writeFileSync('$WORK/probe.gz', gzipSync(out));
" 2>/dev/null && $BB prove -b "$CIRCUIT_PATH" -w "$WORK/probe.gz" -t "$TARGET" -o "$WORK" 2>&1 | grep -oE 'max witness index \+ 1 \([0-9]+\)' | grep -oE '[0-9]+' | tail -1 || echo "0")
fi

echo "Witness count needed: $WITNESS_COUNT"

if [ "$WITNESS_COUNT" = "0" ] || [ -z "$WITNESS_COUNT" ]; then
  echo "Could not determine witness count. Trying with gates info..."
  WITNESS_COUNT=100
fi

# Step 3: Generate dummy witness with correct size
echo "Generating dummy witness ($WITNESS_COUNT entries)..."
cd "$BASE_DIR/prover"
npx tsx -e "
import { writeFileSync } from 'fs';
import { gzipSync } from 'zlib';
import { pack } from 'msgpackr';
const n = $WITNESS_COUNT;
const wm = new Map();
const zero = Buffer.alloc(32);
for (let i = 0; i < n; i++) wm.set(i, zero);
const packed = pack([[[0, wm]]]);
const out = Buffer.concat([Buffer.from([2]), packed]);
writeFileSync('$WORK/witness.gz', gzipSync(out));
console.log('Witness: ' + n + ' entries (' + out.length + ' bytes)');
" 2>&1

# Step 4: Generate VK
echo "Computing verification key..."
time $BB write_vk -b "$CIRCUIT_PATH" -t "$TARGET" -o "$WORK" 2>&1 | grep -E "computed|saved"

# Step 5: Prove
echo ""
echo "=== PROVING ==="
time $BB prove -b "$CIRCUIT_PATH" -w "$WORK/witness.gz" -k "$WORK/vk" -t "$TARGET" -o "$WORK" 2>&1

echo ""
if [ -f "$WORK/proof" ]; then
  echo "Proof size: $(wc -c < "$WORK/proof") bytes"
  echo "Proof generated successfully."
else
  echo "No proof file generated."
fi

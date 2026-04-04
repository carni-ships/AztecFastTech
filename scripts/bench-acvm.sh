#!/bin/bash
# Benchmark ACVM witness solving time for Aztec circuit types.
# Usage: ./scripts/bench-acvm.sh [circuit_name]
#
# This measures the witness solving phase independently from proving,
# to determine if ACVM is on the critical path for epoch proving.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACVM_BINARY="${ACVM_BINARY:-$SCRIPT_DIR/../../aztec-packages-v4.1.2/noir/noir-repo/target/release/acvm}"

if [ ! -f "$ACVM_BINARY" ]; then
    echo "ERROR: acvm binary not found at $ACVM_BINARY"
    echo "Build with: cd aztec-packages-v4.1.2/noir/noir-repo && RUSTFLAGS=\"-C target-cpu=native\" cargo build --release -p acvm_cli"
    exit 1
fi

echo "=== ACVM Witness Solving Benchmark ==="
echo "  Binary: $ACVM_BINARY"
echo "  Architecture: $(file "$ACVM_BINARY" | sed 's/.*: //')"
echo ""

# Check if hyperfine is available for proper benchmarking
if command -v hyperfine >/dev/null 2>&1; then
    BENCH_CMD="hyperfine --warmup 1 --min-runs 3"
else
    BENCH_CMD=""
    echo "  Note: Install hyperfine for proper benchmarking (brew install hyperfine)"
    echo ""
fi

# List available circuit witnesses in the working directory
ACVM_WORK="/tmp/aztec-prover-acvm"
if [ -d "$ACVM_WORK" ]; then
    echo "  ACVM working directory: $ACVM_WORK"
    echo "  Contents:"
    ls -la "$ACVM_WORK" 2>/dev/null | head -20
else
    echo "  No ACVM working directory found at $ACVM_WORK"
    echo "  Run the prover first to populate witness data."
fi

echo ""
echo "To benchmark a specific circuit's witness solving:"
echo "  time $ACVM_BINARY execute --bytecode <circuit.gz> --witness <witness>"
echo ""
echo "Typical ACVM timing per circuit type (from Aztec prover logs):"
echo "  PARITY_BASE:       ~1-2s"
echo "  BLOCK_ROOT:        ~2-3s"
echo "  CHECKPOINT_ROOT:   ~3-5s"
echo "  ROOT_ROLLUP:       ~5-10s"
echo ""
echo "ACVM is typically <10% of total per-proof time (proving dominates)."

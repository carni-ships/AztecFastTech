#!/bin/bash
# Test the epoch warmup mechanism.
#
# Tests three warmup modes:
#   1. Shell warmup (warmup-epoch.sh): populates disk poly cache
#   2. In-process warmup (--warmup-dir): populates in-memory cache
#   3. JSON protocol warmup ({"type":"warmup"}): on-demand via prove_loop
#
# Usage:
#   ./scripts/test-warmup.sh              # test all modes
#   ./scripts/test-warmup.sh --shell-only # test shell warmup only
#   ./scripts/test-warmup.sh --daemon     # test prove_loop daemon warmup

set -e

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BB_BINARY="${BB_BINARY_PATH:-$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb-avm}"
FILE_CACHE="/tmp/bb-file-cache"
POLY_CACHE="/tmp/bb-poly-cache"

if [ ! -f "$BB_BINARY" ]; then
  echo "ERROR: bb binary not found at $BB_BINARY"
  exit 1
fi

if [ ! -d "$FILE_CACHE" ]; then
  echo "ERROR: File cache $FILE_CACHE does not exist."
  echo "Run at least one epoch to populate it."
  exit 1
fi

echo "=== Warmup Test ==="
echo "  bb binary: $BB_BINARY"
echo "  File cache: $FILE_CACHE"
echo ""

# Count cached circuit types
BYTECODE_COUNT=$(ls "$FILE_CACHE"/*-bytecode-* 2>/dev/null | wc -l | tr -d ' ')
echo "  Cached circuit types: $BYTECODE_COUNT"

# Show current poly cache state
if [ -d "$POLY_CACHE" ]; then
  CACHE_ENTRIES=$(find "$POLY_CACHE" -name '.complete' 2>/dev/null | wc -l | tr -d ' ')
  CACHE_SIZE=$(du -sh "$POLY_CACHE" 2>/dev/null | cut -f1)
  echo "  Poly cache: $CACHE_ENTRIES entries, $CACHE_SIZE"
else
  echo "  Poly cache: empty"
fi
echo ""

MODE="${1:---all}"

# --- Test 1: Shell warmup ---
if [ "$MODE" = "--all" ] || [ "$MODE" = "--shell-only" ]; then
  echo "--- Test 1: Shell warmup (warmup-epoch.sh) ---"
  WARMUP_SCRIPT="$BASE_DIR/scripts/warmup-epoch.sh"
  if [ -x "$WARMUP_SCRIPT" ]; then
    time BB_BINARY_PATH="$BB_BINARY" "$WARMUP_SCRIPT"
  else
    echo "  SKIP: warmup-epoch.sh not found or not executable"
  fi
  echo ""
fi

# --- Test 2: Daemon in-process warmup (--warmup-dir) ---
if [ "$MODE" = "--all" ] || [ "$MODE" = "--daemon" ]; then
  echo "--- Test 2: Daemon in-process warmup (--warmup-dir) ---"
  echo "  Starting bb prove_loop with --warmup-dir=$FILE_CACHE ..."
  echo "  (Will send empty input to trigger warmup then exit)"
  echo ""

  # Start prove_loop with warmup-dir and send a single empty line then close stdin
  # The daemon will warmup, then exit when stdin closes
  echo "" | timeout 120 "$BB_BINARY" prove_loop \
    --scheme ultra_honk \
    --oracle_hash poseidon2 \
    --disable_zk \
    --warmup-dir "$FILE_CACHE" \
    -v 2>&1 || true

  echo ""
  echo "  Daemon warmup test complete."
  echo ""
fi

# --- Test 3: JSON protocol warmup ---
if [ "$MODE" = "--all" ] || [ "$MODE" = "--json" ]; then
  echo "--- Test 3: JSON protocol warmup ---"

  # Pick a bytecode file
  BYTECODE_FILE=$(ls "$FILE_CACHE"/*-bytecode-* 2>/dev/null | head -1)
  if [ -z "$BYTECODE_FILE" ]; then
    echo "  SKIP: No bytecode files found"
  else
    CIRCUIT_NAME=$(basename "$BYTECODE_FILE" | sed 's/-bytecode-.*//')
    echo "  Sending warmup request for $CIRCUIT_NAME ..."

    # Send warmup JSON then close stdin
    echo "{\"type\":\"warmup\",\"bytecode\":\"$BYTECODE_FILE\"}" | \
      timeout 60 "$BB_BINARY" prove_loop \
        --scheme ultra_honk \
        --oracle_hash poseidon2 \
        --disable_zk \
        -v 2>&1 || true

    echo ""
    echo "  JSON warmup test complete."
  fi
  echo ""
fi

# Show final poly cache state
if [ -d "$POLY_CACHE" ]; then
  CACHE_ENTRIES=$(find "$POLY_CACHE" -name '.complete' 2>/dev/null | wc -l | tr -d ' ')
  CACHE_SIZE=$(du -sh "$POLY_CACHE" 2>/dev/null | cut -f1)
  echo "=== Final State ==="
  echo "  Poly cache: $CACHE_ENTRIES entries, $CACHE_SIZE"
fi

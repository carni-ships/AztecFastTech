#!/bin/bash
# Pre-warm cross-process disk poly cache and OS page cache for all circuit types.
#
# For in-process warmup (tier 1), use bb prove_loop --warmup-dir or BB_WARMUP_DIR.
#
# Eliminates cold-cache penalties on first proof of each circuit type:
#   - SRS page cache: already loaded by start-prover.sh
#   - Precomputed poly disk cache: populated by bb write_vk (dummy witness)
#   - Bytecode/VK file cache: warmed into page cache
#   - CommitmentKey (SRS + point table): constructed and cached in-process
#
# Measured cold-cache penalties per circuit type (from prover.log):
#   ParityBaseArtifact:                        ~1.3s
#   ParityRootArtifact:                        ~2.7s
#   BlockRootEmptyTxFirstRollupArtifact:       ~0.95s
#   CheckpointRootSingleBlockRollupArtifact:   ~4.2s
#   PrivateTxBaseRollupArtifact:               ~1.2s (estimated)
#   CheckpointMergeRollupArtifact:             ~0.8s (estimated)
#   RootRollupArtifact:                        ~5.0s (estimated, 2^24)
#
# Total cold-cache overhead (first epoch): ~16s across 5-7 distinct types.
# With warmup, these are shifted to before the first proof arrives.
#
# Usage:
#   ./scripts/warmup-epoch.sh              # warm all cached circuit types
#   ./scripts/warmup-epoch.sh --dry-run    # show what would be done
#
# Prerequisites:
#   - bb-avm binary built and available
#   - Circuit bytecode/VK files in /tmp/bb-file-cache/ (populated by prior epoch)

set -e

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Configuration ---
BB_BINARY="${BB_BINARY_PATH:-$BASE_DIR/../aztec-packages-v4.1.2/barretenberg/cpp/build/bin/bb-avm}"
FILE_CACHE="/tmp/bb-file-cache"
POLY_CACHE="/tmp/bb-poly-cache"
WARMUP_DIR="/tmp/bb-warmup"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# --- Circuit type definitions ---
# Returns the bb verifier_target for a given circuit name.
# Flavor mapping (from honk.js):
#   ParityBase, ParityRoot          -> ultra_honk        (noir-recursive-no-zk)
#   RootRollup                      -> ultra_keccak_honk (evm-no-zk)
#   Everything else                 -> ultra_rollup_honk (noir-rollup-no-zk)
get_flavor() {
  case "$1" in
    ParityBaseArtifact|ParityRootArtifact)
      echo "noir-recursive-no-zk" ;;
    RootRollupArtifact)
      echo "evm-no-zk" ;;
    *)
      echo "noir-rollup-no-zk" ;;
  esac
}

# --- Validation ---
if [ ! -f "$BB_BINARY" ]; then
  echo "ERROR: bb binary not found at $BB_BINARY"
  echo "Set BB_BINARY_PATH or build bb-avm first."
  exit 1
fi

if [ ! -d "$FILE_CACHE" ]; then
  echo "WARNING: File cache $FILE_CACHE does not exist."
  echo "No circuit bytecode/VK files available for warmup."
  echo "Run at least one epoch to populate the cache, then re-run warmup."
  exit 0
fi

# --- Discover available circuit types ---
# The file cache contains entries like: ParityBaseArtifact-bytecode-2442812
# We need both bytecode and VK for a given circuit type.
echo "=== Epoch Warmup ==="
echo "  bb binary:  $BB_BINARY"
echo "  File cache: $FILE_CACHE"
echo "  Poly cache: $POLY_CACHE"
echo ""

AVAILABLE_CIRCUITS=()
for bytecode_file in "$FILE_CACHE"/*-bytecode-*; do
  [ -f "$bytecode_file" ] || continue
  # Extract circuit name: ParityBaseArtifact-bytecode-2442812 -> ParityBaseArtifact
  basename=$(basename "$bytecode_file")
  circuit_name="${basename%%-bytecode-*}"

  # Check if VK also exists
  vk_file=$(ls "$FILE_CACHE/${circuit_name}-vk-"* 2>/dev/null | head -1)
  if [ -n "$vk_file" ]; then
    AVAILABLE_CIRCUITS+=("$circuit_name")
  fi
done

if [ ${#AVAILABLE_CIRCUITS[@]} -eq 0 ]; then
  echo "No circuit types found in file cache. Nothing to warm up."
  exit 0
fi

echo "Found ${#AVAILABLE_CIRCUITS[@]} circuit types to warm:"
for circuit in "${AVAILABLE_CIRCUITS[@]}"; do
  flavor="$(get_flavor "$circuit")"
  echo "  - $circuit (flavor: $flavor)"
done
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] Would warm ${#AVAILABLE_CIRCUITS[@]} circuit types."
  exit 0
fi

mkdir -p "$WARMUP_DIR" "$POLY_CACHE"

# --- Phase 1: Pre-warm bytecode/VK files into page cache ---
echo "Phase 1: Pre-warming bytecode/VK files into page cache..."
for circuit in "${AVAILABLE_CIRCUITS[@]}"; do
  bytecode_file=$(ls "$FILE_CACHE/${circuit}-bytecode-"* 2>/dev/null | head -1)
  vk_file=$(ls "$FILE_CACHE/${circuit}-vk-"* 2>/dev/null | head -1)
  cat "$bytecode_file" > /dev/null 2>&1 &
  cat "$vk_file" > /dev/null 2>&1 &
done
wait
echo "  Done."
echo ""

# --- Phase 2: Pre-warm poly cache files (if they exist from prior epochs) ---
if [ -n "$(ls -A "$POLY_CACHE" 2>/dev/null)" ]; then
  echo "Phase 2: Pre-warming existing poly cache into page cache..."
  POLY_SIZE=$(du -sh "$POLY_CACHE" 2>/dev/null | cut -f1)
  echo "  Poly cache size: $POLY_SIZE"
  find "$POLY_CACHE" -name '*.bin' -exec cat {} + > /dev/null 2>&1 &
  POLY_PID=$!
fi

# --- Phase 3: Run bb write_vk for each circuit type (constructs ProverInstance) ---
# write_vk uses dummy witnesses internally, constructing the full circuit and ProverInstance.
# This warms:
#   - ACIR bytecode parsing and circuit construction
#   - SRS (Structured Reference String) fetch and page cache
#   - ProverInstance polynomial computation (selectors, sigma, ID, tables)
#   - CommitmentKey construction (SRS point table)
#
# All circuit types run in parallel (independent circuits, different memory profiles).
# Small circuits (2^20-2^22) are lightweight; large ones (2^23-2^24) may need sequencing.

echo "Phase 3: Constructing ProverInstance for each circuit type (bb write_vk)..."

WARMUP_PIDS=()
WARMUP_NAMES=()
WARMUP_START=$(date +%s)

# Separate small and large circuits to avoid memory contention
SMALL_CIRCUITS=()
LARGE_CIRCUITS=()
for circuit in "${AVAILABLE_CIRCUITS[@]}"; do
  case "$circuit" in
    CheckpointRoot*|RootRollup*)
      LARGE_CIRCUITS+=("$circuit")
      ;;
    *)
      SMALL_CIRCUITS+=("$circuit")
      ;;
  esac
done

warmup_circuit() {
  local circuit="$1"
  local flavor="$(get_flavor "$circuit")"
  local bytecode_file=$(ls "$FILE_CACHE/${circuit}-bytecode-"* 2>/dev/null | head -1)
  local output_dir="$WARMUP_DIR/$circuit"
  mkdir -p "$output_dir"

  local start_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s)

  "$BB_BINARY" write_vk \
    -b "$bytecode_file" \
    -o "$output_dir" \
    -t "$flavor" \
    2>&1 | while IFS= read -r line; do echo "  [$circuit] $line"; done

  local end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s)
  local elapsed=$((end_ms - start_ms))
  echo "  [$circuit] write_vk completed in ${elapsed}ms"
}

# Run small circuits in parallel
for circuit in "${SMALL_CIRCUITS[@]}"; do
  warmup_circuit "$circuit" &
  WARMUP_PIDS+=($!)
  WARMUP_NAMES+=("$circuit")
done

# Wait for small circuits
for i in "${!WARMUP_PIDS[@]}"; do
  wait "${WARMUP_PIDS[$i]}" 2>/dev/null || \
    echo "  WARNING: ${WARMUP_NAMES[$i]} warmup failed (non-fatal)"
done

# Run large circuits sequentially (they need significant memory)
for circuit in "${LARGE_CIRCUITS[@]}"; do
  warmup_circuit "$circuit"
done

WARMUP_END=$(date +%s)
WARMUP_ELAPSED=$((WARMUP_END - WARMUP_START))

echo ""
echo "  All circuit types warmed in ${WARMUP_ELAPSED}s"
echo ""

# Note: write_vk also populates the precomputed poly disk cache (PrecomputedPolyCache).
# On first warmup for a circuit type: MISS -> SAVED (serializes 28 polys to disk).
# On subsequent warmup: DISK HIT -> loaded from cross-process shared mmap cache.
# This means the warmup fully eliminates the poly serialization penalty on first proof.

# Wait for poly cache pre-warm if it was running
if [ -n "${POLY_PID:-}" ]; then
  wait "$POLY_PID" 2>/dev/null || true
  echo "  Poly cache page pre-warm complete."
fi

# --- Cleanup ---
# Don't clean warmup dir — the VK outputs might be useful for debugging.
# They're tiny (3.6 KB each) and overwritten on next warmup.

echo "=== Warmup Complete ==="
echo "  Circuit types warmed: ${#AVAILABLE_CIRCUITS[@]}"
echo "  Wall time: ${WARMUP_ELAPSED}s"
echo "  The first proof of each circuit type should now be ~60-70% faster."
echo ""

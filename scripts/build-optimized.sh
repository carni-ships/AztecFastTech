#!/usr/bin/env bash
# Build optimized bb binary from barretenberg with patches applied.
# Files are backed up before modification and restored on exit (success or failure).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AZTEC_ROOT="${AZTEC_ROOT:-$SCRIPT_DIR/../../aztec-packages-v4.1.2}"
BB_SRC="$AZTEC_ROOT/barretenberg/cpp/src/barretenberg"
BB_BUILD="$AZTEC_ROOT/barretenberg/cpp/build"
BIN_DIR="$SCRIPT_DIR/../bin"
BACKUP_DIR=$(mktemp -d)

echo "=== Building optimized barretenberg ==="
echo "Backup dir: $BACKUP_DIR"
echo ""

# Files to patch (relative to BB_SRC) — only files that need backup/restore
# metal_msm.mm has permanent changes in source; per-window patch applied additively
PATCH_FILES=(
    "flavor/partially_evaluated_multivariates.hpp"
    "commitment_schemes/commitment_key.hpp"
    "polynomials/backing_memory.hpp"
    "ecc/scalar_multiplication/scalar_multiplication.cpp"
)

# Backup originals
echo "--- Backing up files ---"
for f in "${PATCH_FILES[@]}"; do
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp "$BB_SRC/$f" "$BACKUP_DIR/$f"
    echo "  Backed up: $f"
done

# Restore function (called on exit, success or failure)
restore_files() {
    echo ""
    echo "--- Restoring original files ---"
    for f in "${PATCH_FILES[@]}"; do
        cp "$BACKUP_DIR/$f" "$BB_SRC/$f"
        echo "  Restored: $f"
    done
    # metal_msm.mm changes are now permanent in source (no restore needed)
    rm -rf "$BACKUP_DIR"
    echo "Source directory restored."
}
trap restore_files EXIT

# === Apply optimizations ===
echo ""
echo "--- Applying optimizations ---"

# 1. DontZeroMemory for partial evaluation polynomials
F="$BB_SRC/flavor/partially_evaluated_multivariates.hpp"
sed -i '' 's|poly = Polynomial(desired_size, circuit_size / 2);|poly = Polynomial(desired_size, circuit_size / 2, Polynomial::DontZeroMemory::FLAG);|' "$F"
echo "  [1] DontZeroMemory for partial evaluation"

# 2. MSM threshold: keep at 2^17 (lowering to 2^15 hurts on small circuits
#    where GPU dispatch overhead + bucket imbalance bailout > CPU time)
echo "  [2] MSM threshold: kept at 2^17 (GPU overhead dominates below 131K)"

# 3. Per-window bucket imbalance bailout: now permanently in source (metal_msm.mm).
#    skip_imbalance_check propagated through batch_multi_scalar_mul for wire commits.
echo "  [3] Per-window bucket bailout (permanent in source)"

# 4. CommitmentKey cache: avoid SRS re-fetch + Metal prewarm across same-size proofs
PATCH_SRC="$SCRIPT_DIR/../patches/barretenberg/cpp/src/barretenberg"
BASE_DIR="$SCRIPT_DIR/.."
if [ -f "$PATCH_SRC/commitment_schemes/commitment_key.hpp" ]; then
    cp "$PATCH_SRC/commitment_schemes/commitment_key.hpp" "$BB_SRC/commitment_schemes/commitment_key.hpp"
    echo "  [4] CommitmentKey::get_or_create() cache"
fi

# 5. bbapi CK cache integration: skipped — upstream now has its own precomputed
#    polynomial cache and ACIR format cache; patch is outdated (273 vs 734 lines)
echo "  [5] bbapi CK cache: SKIPPED (upstream has precomputed poly cache)"

# 6. Huge page support for large polynomial allocations (reduces TLB misses)
if [ -f "$PATCH_SRC/polynomials/backing_memory.hpp" ]; then
    cp "$PATCH_SRC/polynomials/backing_memory.hpp" "$BB_SRC/polynomials/backing_memory.hpp"
    echo "  [6] Huge pages + MADV_FREE for polynomial allocations"
fi

# 7. Cache-aware MSM bucket width selection
if [ -f "$PATCH_SRC/ecc/scalar_multiplication/scalar_multiplication.cpp" ]; then
    cp "$PATCH_SRC/ecc/scalar_multiplication/scalar_multiplication.cpp" "$BB_SRC/ecc/scalar_multiplication/scalar_multiplication.cpp"
    echo "  [7] Cache-aware MSM bucket width + thread-local LUT"
fi

echo ""

# === Build ===
echo "--- Building (ninja) ---"
cd "$BB_BUILD"
ninja -j$(sysctl -n hw.logicalcpu) bb bb-avm 2>&1 | tail -30
echo ""

# === Copy binaries ===
echo "--- Copying binaries to $BIN_DIR ---"
mkdir -p "$BIN_DIR"
for bin in bb bb-avm; do
    if [ -f "$BB_BUILD/bin/$bin" ]; then
        cp "$BB_BUILD/bin/$bin" "$BIN_DIR/$bin"
        echo "  Copied: $bin"
    fi
done

# Copy metal shaders if present
for shader in "$BB_BUILD/bin/"*.metal; do
    [ -f "$shader" ] && cp "$shader" "$BIN_DIR/" && echo "  Copied: $(basename "$shader")"
done

echo ""
echo "=== Build complete ==="
echo "Optimized binaries in: $BIN_DIR"

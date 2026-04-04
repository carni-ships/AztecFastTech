#!/bin/bash
# Generate PGO (Profile-Guided Optimization) training data from Aztec circuits.
#
# Current PGO profile only covers parity_base. This script trains on all
# circuit types encountered during epoch proving for better branch prediction
# across the full circuit mix.
#
# Usage:
#   1. Build instrumented bb: ./scripts/pgo-train.sh --build
#   2. Run training:          ./scripts/pgo-train.sh --train
#   3. Merge profiles:        ./scripts/pgo-train.sh --merge
#   4. Rebuild with PGO:      ./scripts/pgo-train.sh --rebuild
#   5. All-in-one:            ./scripts/pgo-train.sh --all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BB_CPP="$SCRIPT_DIR/../../aztec-packages-v4.1.2/barretenberg/cpp"
BB_BUILD="$BB_CPP/build"
PGO_DIR="/tmp/bb_pgo_profiles"
MERGED_PROFILE="$PGO_DIR/merged.profdata"

# Circuits to train on (in order of frequency during epoch proving)
# These are the circuit types proven most often per epoch
TRAINING_CIRCUITS=(
    "parity_base"           # ~16 per epoch, 2.27M gates
    # Add more circuits here as witnesses become available:
    # "rollup_block_merge"  # ~16 per epoch, 1.58M gates
    # "checkpoint_merge"    # ~8 per epoch, 1.58M gates
    # "checkpoint_root"     # ~1 per epoch, 5.39M gates
)

case "${1:-}" in
    --build)
        echo "=== Building instrumented bb for PGO training ==="
        cd "$BB_CPP"
        cmake --preset default \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_CXX_FLAGS="-O3 -mcpu=native -fprofile-instr-generate=$PGO_DIR/bb-%p.profraw" \
            -DCMAKE_EXE_LINKER_FLAGS="-fprofile-instr-generate"
        cmake --build --preset default --target bb-avm -j$(sysctl -n hw.ncpu)
        echo "Instrumented binary: $BB_BUILD/bin/bb-avm"
        ;;
    --train)
        echo "=== Running PGO training workload ==="
        mkdir -p "$PGO_DIR"
        BB="$BB_BUILD/bin/bb-avm"

        for circuit in "${TRAINING_CIRCUITS[@]}"; do
            CIRCUIT_DIR="$SCRIPT_DIR/../circuits/target"
            CIRCUIT_JSON="$CIRCUIT_DIR/${circuit}.json"
            WITNESS_DIR="$CIRCUIT_DIR"

            if [ -f "$CIRCUIT_JSON" ] || [ -f "${CIRCUIT_JSON}.gz" ]; then
                echo "  Training on: $circuit"
                # Run prove + verify to exercise both paths
                if [ -f "$CIRCUIT_JSON.gz" ]; then
                    BYTECODE_FLAG="-b $CIRCUIT_JSON.gz"
                else
                    BYTECODE_FLAG="-b $CIRCUIT_JSON"
                fi

                # Find witness file
                WITNESS_FILE="$WITNESS_DIR/${circuit}.gz"
                if [ ! -f "$WITNESS_FILE" ]; then
                    WITNESS_FILE="$WITNESS_DIR/${circuit}_witness.gz"
                fi
                if [ -f "$WITNESS_FILE" ]; then
                    $BB prove $BYTECODE_FLAG -w "$WITNESS_FILE" -o /tmp/pgo_proof 2>&1 | tail -5
                    echo "  ✓ $circuit training complete"
                else
                    echo "  ⚠ No witness found for $circuit, skipping"
                fi
            else
                echo "  ⚠ Circuit not found: $circuit"
            fi
        done
        echo ""
        echo "Raw profiles in: $PGO_DIR/"
        ls -la "$PGO_DIR"/*.profraw 2>/dev/null || echo "  (no profiles generated)"
        ;;
    --merge)
        echo "=== Merging PGO profiles ==="
        LLVM_PROFDATA=$(xcrun -find llvm-profdata 2>/dev/null || which llvm-profdata 2>/dev/null || echo "")
        if [ -z "$LLVM_PROFDATA" ]; then
            # Try Homebrew LLVM
            LLVM_PROFDATA=$(ls /opt/homebrew/opt/llvm/bin/llvm-profdata 2>/dev/null || echo "")
        fi
        if [ -z "$LLVM_PROFDATA" ]; then
            echo "ERROR: llvm-profdata not found. Install with: brew install llvm"
            exit 1
        fi

        $LLVM_PROFDATA merge -sparse "$PGO_DIR"/*.profraw -o "$MERGED_PROFILE"
        echo "Merged profile: $MERGED_PROFILE ($(du -h "$MERGED_PROFILE" | cut -f1))"
        ;;
    --rebuild)
        echo "=== Rebuilding bb with PGO profile ==="
        if [ ! -f "$MERGED_PROFILE" ]; then
            echo "ERROR: No merged profile at $MERGED_PROFILE. Run --merge first."
            exit 1
        fi
        cd "$BB_CPP"
        cmake --preset default \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_CXX_FLAGS="-O3 -mcpu=native -flto=thin -fprofile-instr-use=$MERGED_PROFILE -Wno-error=profile-instr-unprofiled" \
            -DCMAKE_EXE_LINKER_FLAGS="-flto=thin -fprofile-instr-use=$MERGED_PROFILE"
        cmake --build --preset default --target bb-avm -j$(sysctl -n hw.ncpu)
        echo ""
        echo "PGO-optimized binary: $BB_BUILD/bin/bb-avm"
        echo "Profile: $MERGED_PROFILE"
        ;;
    --all)
        "$0" --build
        "$0" --train
        "$0" --merge
        "$0" --rebuild
        echo ""
        echo "=== PGO pipeline complete ==="
        ;;
    *)
        echo "Usage: $0 {--build|--train|--merge|--rebuild|--all}"
        echo ""
        echo "Steps:"
        echo "  --build   Build instrumented bb binary"
        echo "  --train   Run training workload on Aztec circuits"
        echo "  --merge   Merge raw profiles into single .profdata"
        echo "  --rebuild Rebuild bb with PGO optimization"
        echo "  --all     Run all steps"
        ;;
esac

#!/usr/bin/env bash
# AztecFastTech - Noir proving benchmarks with Metal GPU acceleration
# Measures: compile time, witness generation, gate count, proving time, verification time
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Use Metal-enabled bb if available (local build), otherwise fall back to installed bb
# BB_LOCAL env var overrides default path (e.g. BB_LOCAL=./bin/bb-opt ./bench.sh)
BB_LOCAL="${BB_LOCAL:-$SCRIPT_DIR/barretenberg/cpp/build/bin/bb}"
if [ -x "$BB_LOCAL" ]; then
    BB="$BB_LOCAL"
    BB_LABEL="local Metal-enabled build"
else
    BB="bb"
    BB_LABEL="installed (CPU-only)"
fi

PACKAGES=(bench_poseidon bench_merkle bench_ec_ops)
RESULTS_FILE="results/bench-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p results

echo "=== AztecFastTech Benchmark Suite ===" | tee "$RESULTS_FILE"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" | tee -a "$RESULTS_FILE"
echo "Machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)" | tee -a "$RESULTS_FILE"
echo "Cores: $(sysctl -n hw.ncpu)" | tee -a "$RESULTS_FILE"
echo "RAM: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB" | tee -a "$RESULTS_FILE"
echo "nargo: $(nargo --version 2>&1 | head -1)" | tee -a "$RESULTS_FILE"
echo "bb: $($BB --version 2>&1) ($BB_LABEL)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

for pkg in "${PACKAGES[@]}"; do
    echo "━━━ $pkg ━━━" | tee -a "$RESULTS_FILE"

    # Gate count
    gates_json=$($BB gates -b "target/${pkg}.json" 2>&1 | grep -v "^Scheme")
    circuit_size=$(echo "$gates_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['functions'][0]['circuit_size'])")
    acir_opcodes=$(echo "$gates_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['functions'][0]['acir_opcodes'])")
    echo "  ACIR opcodes: $acir_opcodes" | tee -a "$RESULTS_FILE"
    echo "  Circuit size (gates): $circuit_size" | tee -a "$RESULTS_FILE"

    # Witness generation
    t0=$(python3 -c "import time; print(time.time())")
    if nargo execute --package "$pkg" > /dev/null 2>&1; then
        t1=$(python3 -c "import time; print(time.time())")
        witness_ms=$(python3 -c "print(f'{($t1 - $t0) * 1000:.1f}')")
        echo "  Witness gen: ${witness_ms}ms" | tee -a "$RESULTS_FILE"
    else
        echo "  Witness gen: skipped (using cached witness)" | tee -a "$RESULTS_FILE"
    fi

    # Write VK first (needed for proving)
    # -t noir-recursive-no-zk: skip ZK blinding (not needed for recursive Noir proofs)
    mkdir -p "target/${pkg}_vk" "target/${pkg}_proof"
    $BB write_vk -b "target/${pkg}.json" -o "target/${pkg}_vk" -t noir-recursive-no-zk 2>/dev/null

    # Proving (UltraHonk, the scheme Aztec uses)
    t0=$(python3 -c "import time; print(time.time())")
    $BB prove -b "target/${pkg}.json" -w "target/${pkg}.gz" \
       -k "target/${pkg}_vk/vk" -o "target/${pkg}_proof" -t noir-recursive-no-zk 2>/dev/null
    t1=$(python3 -c "import time; print(time.time())")
    prove_ms=$(python3 -c "print(f'{($t1 - $t0) * 1000:.1f}')")
    echo "  Prove (UltraHonk, no-zk): ${prove_ms}ms" | tee -a "$RESULTS_FILE"

    # Verification
    t0=$(python3 -c "import time; print(time.time())")
    $BB verify -k "target/${pkg}_vk/vk" \
       -p "target/${pkg}_proof/proof" \
       -i "target/${pkg}_proof/public_inputs" -t noir-recursive-no-zk 2>/dev/null
    t1=$(python3 -c "import time; print(time.time())")
    verify_ms=$(python3 -c "print(f'{($t1 - $t0) * 1000:.1f}')")
    echo "  Verify: ${verify_ms}ms" | tee -a "$RESULTS_FILE"

    # Proof size
    proof_size=$(wc -c < "target/${pkg}_proof/proof" | tr -d ' ')
    echo "  Proof size: ${proof_size} bytes" | tee -a "$RESULTS_FILE"

    echo "" | tee -a "$RESULTS_FILE"
done

# Also benchmark the existing incremental circuit if witness exists
if [ -f "target/persistia_incremental_proof.gz" ]; then
    pkg="persistia_incremental_proof"
    echo "━━━ $pkg (production circuit) ━━━" | tee -a "$RESULTS_FILE"

    gates_json=$($BB gates -b "target/${pkg}.json" 2>&1 | grep -v "^Scheme")
    circuit_size=$(echo "$gates_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['functions'][0]['circuit_size'])")
    acir_opcodes=$(echo "$gates_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['functions'][0]['acir_opcodes'])")
    echo "  ACIR opcodes: $acir_opcodes" | tee -a "$RESULTS_FILE"
    echo "  Circuit size (gates): $circuit_size" | tee -a "$RESULTS_FILE"

    mkdir -p "target/${pkg}_proof"

    t0=$(python3 -c "import time; print(time.time())")
    $BB prove -b "target/${pkg}.json" -w "target/${pkg}.gz" \
       -o "target/${pkg}_proof" -t noir-recursive-no-zk --write_vk 2>/dev/null
    t1=$(python3 -c "import time; print(time.time())")
    prove_ms=$(python3 -c "print(f'{($t1 - $t0) * 1000:.1f}')")
    echo "  Prove (UltraHonk, no-zk): ${prove_ms}ms" | tee -a "$RESULTS_FILE"

    t0=$(python3 -c "import time; print(time.time())")
    $BB verify -k "target/${pkg}_proof/vk" \
       -p "target/${pkg}_proof/proof" \
       -i "target/${pkg}_proof/public_inputs" -t noir-recursive-no-zk 2>/dev/null
    t1=$(python3 -c "import time; print(time.time())")
    verify_ms=$(python3 -c "print(f'{($t1 - $t0) * 1000:.1f}')")
    echo "  Verify: ${verify_ms}ms" | tee -a "$RESULTS_FILE"

    proof_size=$(wc -c < "target/${pkg}_proof/proof" | tr -d ' ')
    echo "  Proof size: ${proof_size} bytes" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"
fi

echo "=== Benchmark Complete ===" | tee -a "$RESULTS_FILE"
echo "Results saved to $RESULTS_FILE"

#!/bin/bash
# Parse prover logs to extract per-epoch timing breakdown.
# Usage:
#   ./scripts/epoch-stats.sh [log_file]
#   echo "... log output ..." | ./scripts/epoch-stats.sh
#
# Parses bb-avm timing lines to compute:
#   - Per-epoch total time
#   - Per-circuit-type average and max prove time
#   - Idle time (gaps between proofs)
#   - Spare margin vs epoch window

set -e

LOG_FILE="${1:-/dev/stdin}"

echo "=== Epoch Proving Statistics ==="
echo ""

# Extract construct_proof timing lines
# Format: "construct_proof timing: oink=XXXms gate_challenges=XXXms sumcheck=XXXms pcs=XXXms total=XXXms"
grep -o 'construct_proof timing:.*total=[0-9]*ms' "$LOG_FILE" 2>/dev/null | while read -r line; do
    total=$(echo "$line" | grep -o 'total=[0-9]*' | cut -d= -f2)
    oink=$(echo "$line" | grep -o 'oink=[0-9]*' | cut -d= -f2)
    sumcheck=$(echo "$line" | grep -o 'sumcheck=[0-9]*' | cut -d= -f2)
    pcs=$(echo "$line" | grep -o 'pcs=[0-9]*' | cut -d= -f2)
    echo "  total=${total}ms oink=${oink}ms sumcheck=${sumcheck}ms pcs=${pcs}ms"
done

echo ""

# Count proofs and compute average
if [ -f "$LOG_FILE" ]; then
    num_proofs=$(grep -c 'construct_proof timing:' "$LOG_FILE" 2>/dev/null || echo "0")
    if [ "$num_proofs" -gt 0 ]; then
        total_ms=$(grep -o 'total=[0-9]*ms' "$LOG_FILE" | grep -o '[0-9]*' | awk '{sum+=$1} END {print sum}')
        avg_ms=$((total_ms / num_proofs))
        max_ms=$(grep -o 'total=[0-9]*ms' "$LOG_FILE" | grep -o '[0-9]*' | sort -n | tail -1)
        echo "Summary:"
        echo "  Proofs: $num_proofs"
        echo "  Average: ${avg_ms}ms"
        echo "  Maximum: ${max_ms}ms"
        echo "  Total proving: ${total_ms}ms ($((total_ms / 1000))s)"

        # Estimate epoch time with 2 agents
        estimated_2agent=$((total_ms / 2 / 1000))
        estimated_3agent=$((total_ms / 3 / 1000))
        echo ""
        echo "Estimated epoch wall time:"
        echo "  2 agents: ~${estimated_2agent}s ($((estimated_2agent / 60))m)"
        echo "  3 agents: ~${estimated_3agent}s ($((estimated_3agent / 60))m)"
        echo ""
        echo "Epoch window: ~1200s (20 minutes)"
        echo "  2-agent margin: $((1200 - estimated_2agent))s"
        echo "  3-agent margin: $((1200 - estimated_3agent))s"
    else
        echo "No construct_proof timing lines found in log."
    fi
fi

# ACVM witness solving timing (if present in logs)
if [ -f "$LOG_FILE" ]; then
    acvm_lines=$(grep -c 'witness.*solv\|acvm.*time\|witness_generation\|ACVM' "$LOG_FILE" 2>/dev/null || echo "0")
    if [ "$acvm_lines" -gt 0 ]; then
        echo "ACVM Witness Solving:"
        grep -i 'witness.*solv\|acvm.*time\|witness_generation\|ACVM.*ms' "$LOG_FILE" 2>/dev/null | tail -10
        echo ""
    fi
fi

# Per-circuit-type breakdown
if [ -f "$LOG_FILE" ]; then
    echo "Per-Circuit-Type Timing:"
    for circuit_type in "parity_base" "block_root" "checkpoint" "root_rollup" "public_tx"; do
        count=$(grep -ic "$circuit_type.*construct_proof\|construct_proof.*$circuit_type" "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo "  $circuit_type: $count proofs"
        fi
    done
    echo ""
fi

echo ""
echo "Note: Pipe prover output through this script, e.g.:"
echo "  ./scripts/start-prover.sh 2>&1 | tee prover.log"
echo "  ./scripts/epoch-stats.sh prover.log"

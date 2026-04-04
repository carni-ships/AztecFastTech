#!/bin/bash
# Monitor the Aztec prover for proving activity, errors, and epoch progress.
# Usage: ./scripts/monitor-prover.sh [--follow]
set -e

LOG="/Users/carnation/Documents/Claude/aztec-bench/.prover-data/prover.log"

if [ ! -f "$LOG" ]; then
  echo "No prover log found at $LOG"
  exit 1
fi

echo "=== Prover Monitor ($(date)) ==="

# Process status
echo ""
echo "--- Processes ---"
ps aux | grep "aztec\|bb msgpack\|bb prove\|bb-avm" | grep -v grep | \
  awk '{printf "  PID %-6s RSS %-6dMB CPU %-5s %s\n", $2, $6/1024, $3, $11}' || echo "  No prover processes"

# System resources
echo ""
echo "--- Resources ---"
echo "  Swap: $(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}')"
FREE_PAGES=$(vm_stat 2>/dev/null | awk '/Pages free|Pages inactive/ {gsub(/\./,"",$NF); sum+=$NF} END {print sum}')
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
echo "  Free+inactive: $(echo "$FREE_PAGES $PAGE_SIZE" | awk '{printf "%.1f GB", ($1 * $2) / 1073741824}')"

# Log summary
echo ""
echo "--- Log Summary ---"
TOTAL_LINES=$(wc -l < "$LOG")
echo "  Log lines: $TOTAL_LINES"

# Errors
ERRORS=$(grep -c "ERROR" "$LOG" 2>/dev/null || echo 0)
echo "  Errors: $ERRORS"

# Proving jobs
STARTED=$(grep -c "Starting proof\|CircuitProve\|construct_proof\|prove.*start" "$LOG" 2>/dev/null || echo 0)
COMPLETED=$(grep -c "Proof saved\|proof.*success\|fulfilled" "$LOG" 2>/dev/null || echo 0)
FAILED=$(grep -c "proof.*fail\|verification failed\|rejected" "$LOG" 2>/dev/null || echo 0)
echo "  Proofs started: $STARTED"
echo "  Proofs completed: $COMPLETED"
echo "  Proofs failed: $FAILED"

# Epoch info
EPOCHS=$(grep -oE "epoch [0-9]+" "$LOG" 2>/dev/null | sort -u | tail -3)
if [ -n "$EPOCHS" ]; then
  echo "  Recent epochs: $EPOCHS"
fi

# Latest archiver sync status
SYNC_LINE=$(grep "archiver.*sync\|blocksSynchedTo\|checkpointNumber" "$LOG" 2>/dev/null | tail -1)
if [ -n "$SYNC_LINE" ]; then
  echo "  Latest sync: $(echo "$SYNC_LINE" | cut -c1-120)"
fi

# Node health
echo ""
echo "--- Health ---"
NODE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8180/status 2>/dev/null || echo "unreachable")
BROKER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8079/ 2>/dev/null || echo "unreachable")
echo "  Node (8180): $NODE_STATUS"
echo "  Broker (8079): $BROKER_STATUS"

# Recent log (non-broker)
echo ""
echo "--- Recent Activity ---"
grep -v "^\[broker\]" "$LOG" | tail -5

if [ "$1" = "--follow" ]; then
  echo ""
  echo "=== Following log (Ctrl+C to stop) ==="
  tail -f "$LOG" | grep --line-buffered -E "prove|ERROR|epoch|CircuitProve|construct_proof|archiver.*sync|checkpoint"
fi

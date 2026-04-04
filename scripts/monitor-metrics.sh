#!/bin/bash
# Live prover metrics dashboard.
# Tails the prover log and displays real-time statistics.
#
# Usage:
#   ./scripts/monitor-metrics.sh [log_file]
#   ./scripts/start-prover.sh 2>&1 | tee prover.log &
#   ./scripts/monitor-metrics.sh prover.log
#
# Displays:
#   - Proofs completed and rate (proofs/min)
#   - Per-phase timing (oink, sumcheck, pcs)
#   - Memory usage (RSS of bb-avm process)
#   - Current circuit type being proven
#   - Epoch progress estimate

set -e

LOG_FILE="${1:-/tmp/aztec-prover.log}"
REFRESH_INTERVAL=5

if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE"
  echo "Start the prover with: ./scripts/start-prover.sh 2>&1 | tee $LOG_FILE"
  exit 1
fi

# Colors
BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

while true; do
  clear
  echo -e "${BOLD}=== Aztec Prover Dashboard ===${RESET}"
  echo "  Log: $LOG_FILE"
  echo "  Updated: $(date '+%H:%M:%S')"
  echo ""

  # Count total proofs
  TOTAL_PROOFS=$(grep -c 'construct_proof timing:' "$LOG_FILE" 2>/dev/null || echo "0")

  # Get timing of last 10 proofs
  if [ "$TOTAL_PROOFS" -gt 0 ]; then
    # Extract total times
    LAST_TIMES=$(grep -o 'total=[0-9]*ms' "$LOG_FILE" | tail -10 | grep -o '[0-9]*')
    LAST_TIME=$(echo "$LAST_TIMES" | tail -1)
    AVG_TIME=$(echo "$LAST_TIMES" | awk '{sum+=$1; n++} END {if(n>0) printf "%d", sum/n; else print "0"}')

    # Compute proofs/minute from last 10 proofs' timestamps
    TOTAL_MS=$(grep -o 'total=[0-9]*ms' "$LOG_FILE" | grep -o '[0-9]*' | awk '{sum+=$1} END {print sum}')
    if [ "$TOTAL_MS" -gt 0 ]; then
      RATE=$(echo "$TOTAL_PROOFS $TOTAL_MS" | awk '{printf "%.1f", $1 / ($2 / 60000)}')
    else
      RATE="?"
    fi

    echo -e "${BOLD}Proving Statistics${RESET}"
    echo -e "  Total proofs:   ${GREEN}$TOTAL_PROOFS${RESET}"
    echo -e "  Last proof:     ${LAST_TIME}ms"
    echo -e "  Avg (last 10):  ${AVG_TIME}ms"
    echo -e "  Rate:           ${CYAN}${RATE} proofs/min${RESET}"
    echo ""

    # Phase breakdown of last proof
    LAST_LINE=$(grep 'construct_proof timing:' "$LOG_FILE" | tail -1)
    OINK=$(echo "$LAST_LINE" | grep -o 'oink=[0-9]*' | cut -d= -f2)
    GATE=$(echo "$LAST_LINE" | grep -o 'gate_challenges=[0-9]*' | cut -d= -f2)
    SUMCHECK=$(echo "$LAST_LINE" | grep -o 'sumcheck=[0-9]*' | cut -d= -f2)
    PCS=$(echo "$LAST_LINE" | grep -o 'pcs=[0-9]*' | cut -d= -f2)
    TOTAL=$(echo "$LAST_LINE" | grep -o 'total=[0-9]*' | cut -d= -f2)

    echo -e "${BOLD}Last Proof Phase Breakdown${RESET}"
    echo "  oink:            ${OINK:-?}ms"
    echo "  gate_challenges: ${GATE:-?}ms"
    echo "  sumcheck:        ${SUMCHECK:-?}ms"
    echo "  pcs:             ${PCS:-?}ms"
    echo "  total:           ${TOTAL:-?}ms"
    echo ""

    # Epoch estimate (98 jobs, current rate)
    if [ "$TOTAL_PROOFS" -ge 2 ]; then
      EPOCH_EST=$(echo "$AVG_TIME" | awk '{printf "%d", ($1 * 98 / 2 / 1000)}')
      MARGIN=$((1200 - EPOCH_EST))
      echo -e "${BOLD}Epoch Estimate (2 agents)${RESET}"
      echo "  Estimated epoch:  ${EPOCH_EST}s ($((EPOCH_EST / 60))m)"
      echo "  Window:           1200s (20m)"
      if [ "$MARGIN" -gt 0 ]; then
        echo -e "  Margin:           ${GREEN}+${MARGIN}s${RESET}"
      else
        echo -e "  Margin:           ${YELLOW}${MARGIN}s (TIGHT)${RESET}"
      fi
      echo ""
    fi
  else
    echo "  No proofs completed yet. Waiting..."
    echo ""
  fi

  # Memory usage
  BB_PID=$(pgrep -f "bb-avm" 2>/dev/null | head -1 || echo "")
  if [ -n "$BB_PID" ]; then
    RSS=$(ps -o rss= -p "$BB_PID" 2>/dev/null | awk '{printf "%.1f", $1/1024}')
    echo -e "${BOLD}Process${RESET}"
    echo "  bb-avm PID:  $BB_PID"
    echo "  RSS:         ${RSS:-?} MiB"
    echo ""
  fi

  # Recent activity (last 5 log lines with timing)
  echo -e "${BOLD}Recent Activity${RESET}"
  grep -E 'construct_proof|oink breakdown|gemini breakdown|CircuitProve' "$LOG_FILE" 2>/dev/null | tail -5 | while read -r line; do
    echo "  $(echo "$line" | cut -c1-120)"
  done

  sleep "$REFRESH_INTERVAL"
done

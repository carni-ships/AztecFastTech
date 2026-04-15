#!/bin/bash
# prover-monitor.sh — Aztec prover watchdog with auto-restart, git auto-commit, and push-approval DMs.
#
# Checks if the Aztec prover is running (process + health endpoint), restarts it if not.
# Auto-commits any local changes and DMs for push approval if there are unpushed commits.
#
# Env vars required for DMs:
#   TELEGRAM_BOT_TOKEN  — Botfather token (e.g. 123456789:ABCdef...)
#   TELEGRAM_USER_ID    — Your Telegram user ID (get via @userinfobot)
#
# Usage:
#   ./scripts/prover-monitor.sh               # run once and exit
#   ./scripts/prover-monitor.sh --daemon      # loop every 5 minutes
#   ./scripts/prover-monitor.sh --follow      # tail the prover log after checks

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$BASE_DIR/.prover-data/prover.log"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[prover-monitor]${RESET} $*"; }
warn() { echo -e "${YELLOW}[prover-monitor] WARN:${RESET} $*" >&2; }
err()  { echo -e "${RED}[prover-monitor] ERROR:${RESET} $*" >&2; }

# ── Telegram DM ──────────────────────────────────────────────────────────────
send_tg() {
  local msg="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_USER_ID:-}" ]]; then
    warn "TELEGRAM_BOT_TOKEN or TELEGRAM_USER_ID not set — skipping DM"
    return
  fi
  curl -s -o /dev/null -w "%{http_code}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_USER_ID}" \
    -d "text=${msg}" \
    -d "parse_mode=HTML" \
    --max-time 15 || warn "Telegram DM failed (curl exit $?)"
}

# ── Git helpers ───────────────────────────────────────────────────────────────
cd "$BASE_DIR"

has_uncommitted() {
  git status --porcelain 2>/dev/null | grep -q .
}

unpushed_count() {
  git log @{u}..HEAD --oneline 2>/dev/null | wc -l | tr -d ' '
}

commit_and_push() {
  log "Uncommitted changes detected — committing all..."
  git add -A
  if git commit -m "$(date '+%Y-%m-%d %H:%M:%S') auto-commit: prover state snapshot" 2>&1; then
    log "Changes committed."
  else
    log "Nothing to commit (or commit failed)."
    return 0
  fi

  local unpushed
  unpushed=$(unpushed_count)
  if [[ "$unpushed" -gt 0 ]]; then
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    local plural="s"
    [[ "$unpushed" -eq 1 ]] && plural=""

    local commit_lines
    commit_lines=$(git log @{u}..HEAD --oneline 2>/dev/null | head -5 | sed 's/^/  • /')

    local suffix=""
    if [[ "$unpushed" -gt 5 ]]; then
      suffix=$'\n'"  … and $((unpushed-5)) more"
    fi

    # Build message parts without mixing $'...' inside double-quoted assignments
    local msg1="📤 Unpushed commits on ${branch} (${unpushed} commit${plural})"
    local msg2="${commit_lines}${suffix}"
    local msg3="⚠️ Push blocked — reply with PUSH to approve."
    send_tg "${msg1}"$'\n'"${msg2}"$'\n'"${msg3}"
  fi
}

# ── Process check ─────────────────────────────────────────────────────────────
is_prover_running() {
  local count
  count=$(ps aux | grep -E "aztec start.*prover" | grep -v grep | wc -l | tr -d ' ')
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8180/status 2>/dev/null || echo "000")
  [[ "$count" -gt 0 ]] && [[ "$http_code" != "000" ]] && [[ "$http_code" != "004" ]]
}

# ── Restart ───────────────────────────────────────────────────────────────────
do_restart() {
  warn "Prover not running — attempting restart..."

  pkill -f "aztec start.*prover" 2>/dev/null || true
  sleep 2

  if [[ -d "$BASE_DIR/.prover-data-mainnet" ]]; then
    log "Detected mainnet — using start-prover-mainnet.sh"
    ./scripts/start-prover-mainnet.sh >> "$LOG" 2>&1 &
  else
    log "Detected testnet — using start-prover.sh"
    ./scripts/start-prover.sh >> "$LOG" 2>&1 &
  fi

  log "Restart initiated (pid $!). Waiting for health endpoint..."

  for i in $(seq 1 12); do
    sleep 5
    if is_prover_running; then
      log "Prover is back up (health endpoint responding after ~$((i*5))s)."
      send_tg "✅ Prover restarted — back up after ~$((i*5))s"
      return 0
    fi
    log "  Still waiting... ($((i*5))s elapsed)"
  done

  err "Restart failed — prover did not come back within 60s."
  send_tg "🚨 Prover restart FAILED — manual intervention required."
  return 1
}

# ── Status summary ─────────────────────────────────────────────────────────────
print_status() {
  echo ""
  echo "=== Prover Monitor ($(date '+%Y-%m-%d %H:%M:%S')) ==="

  echo ""
  echo "--- Processes ---"
  local proc_count
  proc_count=$(ps aux | grep -E "aztec|bb msgpack|bb prove|bb-avm" | grep -v grep | wc -l | tr -d ' ')
  if [[ "$proc_count" -gt 0 ]]; then
    ps aux | grep -E "aztec|bb msgpack|bb prove|bb-avm" | grep -v grep | \
      awk '{printf "  PID %-6s RSS %-6dMB CPU %-5s %s\n", $2, $6/1024, $3, $11}'
  else
    echo "  No prover processes running."
  fi

  echo ""
  echo "--- Health Endpoints ---"
  local node_code
  node_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8180/status 2>/dev/null || echo "DOWN")
  local broker_code
  broker_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8079/ 2>/dev/null || echo "DOWN")
  echo "  Node   (8180): $node_code"
  echo "  Broker (8079): $broker_code"

  echo ""
  echo "--- Resources ---"
  local swap_used
  swap_used=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}')
  echo "  Swap: ${swap_used:-unknown}"
  local free_pages
  free_pages=$(vm_stat 2>/dev/null | awk '/Pages free|Pages inactive/ {gsub(/\./,"",$NF); sum+=$NF} END {print sum}')
  local page_size
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  local free_gb
  free_gb=$(echo "$free_pages $page_size" | awk '{printf "%.1f", ($1 * $2) / 1073741824}')
  echo "  Free+inactive RAM: ${free_gb} GiB"

  echo ""
  echo "--- Git Status ---"
  if has_uncommitted; then
    echo "  Uncommitted changes: YES"
    git status --short 2>/dev/null | head -5 | sed 's/^/  /'
  else
    echo "  Uncommitted changes: no"
  fi

  local unpushed
  unpushed=$(unpushed_count)
  if [[ "$unpushed" -gt 0 ]]; then
    echo "  Unpushed commits: $unpushed"
  else
    echo "  Unpushed commits: no"
  fi

  if [[ -f "$LOG" ]]; then
    echo ""
    echo "--- Prover Log ---"
    local total_lines
    total_lines=$(wc -l < "$LOG")
    local errors
    errors=$(grep -c "ERROR" "$LOG" 2>/dev/null || echo 0)
    local started
    started=$(grep -cE "Starting proof|CircuitProve|construct_proof|prove.*start" "$LOG" 2>/dev/null || echo 0)
    local completed
    completed=$(grep -cE "Proof saved|proof.*success|fulfilled" "$LOG" 2>/dev/null || echo 0)
    local failed
    failed=$(grep -cE "proof.*fail|verification failed|rejected" "$LOG" 2>/dev/null || echo 0)
    echo "  Log lines : $total_lines"
    echo "  Errors    : $errors"
    echo "  Started   : $started"
    echo "  Completed : $completed"
    echo "  Failed    : $failed"
    echo ""
    echo "  Recent activity (last 5 non-broker lines):"
    grep -v "^\[broker\]" "$LOG" 2>/dev/null | tail -5 | sed 's/^/  /'
  fi
}

# ── Handle PUSH reply (Telegram DM approval) ──────────────────────────────────
wait_for_push_approval() {
  local timeout_sec="${1:-300}"
  local end_time
  end_time=$(($(date +%s) + timeout_sec))
  local last_update_id=0

  log "Waiting up to ${timeout_sec}s for PUSH approval via Telegram DM..."

  while [[ $(date +%s) -lt $end_time ]]; do
    local updates
    updates=$(curl -s --max-time 10 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" \
      -d "offset=$((last_update_id + 1))" \
      -d "timeout=30" 2>/dev/null || echo '{"result":[]}')

    local ids
    ids=$(echo "$updates" | python3 -c "import sys,json; [print(u['update_id']) for u in json.load(sys.stdin)['result'] if 'message' in u]" 2>/dev/null || true)
    local texts
    texts=$(echo "$updates" | python3 -c "import sys,json; [print(u['message']['text']) for u in json.load(sys.stdin)['result'] if 'message' in u]" 2>/dev/null || true)

    if [[ -n "$ids" ]]; then
      last_update_id=$(echo "$ids" | tail -1)
    fi

    if echo "$texts" | grep -qi "^PUSH$"; then
      log "PUSH approval received — pushing."
      git push && log "Push succeeded." || log "Push failed."
      send_tg "🚀 Pushed!"
      return 0
    fi

    sleep 5
  done

  warn "Push approval timeout — not pushed."
  send_tg "⏱️ Push timeout — you didn't reply with PUSH in time. Run manually when ready."
  return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
MODE="once"
if [[ "${1:-}" == "--daemon" ]]; then
  MODE="daemon"
elif [[ "${1:-}" == "--follow" ]]; then
  MODE="follow"
elif [[ "${1:-}" == "--wait-push" ]]; then
  MODE="wait-push"
  WAIT_PUSH_TIMEOUT="${2:-300}"
fi

if [[ "$MODE" == "wait-push" ]]; then
  wait_for_push_approval "$WAIT_PUSH_TIMEOUT"
  exit $?
fi

# Git: auto-commit
if has_uncommitted; then
  commit_and_push
fi

# Prover health check
RESTART_NEEDED=false
if is_prover_running; then
  log "Prover is running."
else
  warn "Prover is NOT running."
  RESTART_NEEDED=true
fi

# Status report
print_status

if [[ "$RESTART_NEEDED" == "true" ]]; then
  do_restart
fi

if [[ "$MODE" == "follow" ]]; then
  echo ""
  echo "=== Following prover log (Ctrl+C to stop) ==="
  tail -f "$LOG" | grep --line-buffered -E "prove|ERROR|epoch|CircuitProve|construct_proof|archiver.*sync|checkpoint"
fi

if [[ "$MODE" == "daemon" ]]; then
  log "Sleeping 5 minutes before next check..."
  sleep 300
  exec "$0" --daemon
fi

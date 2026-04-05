#!/bin/bash
#
# compact-archiver.sh
#
# Compacts the Aztec prover's archiver LMDB database to reclaim disk space.
# Intended as a pre-start maintenance step after log purges or extended operation.
#
# Uses mdb_copy -c (LMDB's built-in compaction tool) to create a defragmented
# copy, then atomically swaps it into place. Falls back to Python lmdb if
# mdb_copy is not available.
#
# Prerequisites:
#   - The prover must NOT be running (LMDB does not support concurrent writers)
#   - mdb_copy (from lmdb-libs/Homebrew lmdb) OR Python 3 with lmdb package
#
# Usage:
#   ./scripts/compact-archiver.sh                  # compact only
#   ./scripts/compact-archiver.sh --purge-logs     # purge logs first, then compact
#   ./scripts/compact-archiver.sh --dry-run        # report sizes without changes
#   ./scripts/compact-archiver.sh --db-path PATH   # custom archiver DB path
#
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_DB_DIR="$BASE_DIR/.prover-data/archiver"

# --- Parse arguments ---
DRY_RUN=0
PURGE_LOGS=0
DB_DIR="$DEFAULT_DB_DIR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --purge-logs) PURGE_LOGS=1; shift ;;
    --db-path)    DB_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--purge-logs] [--db-path PATH]"
      echo ""
      echo "  --dry-run      Report DB sizes and potential savings without changes"
      echo "  --purge-logs   Run purge-archiver-logs.js before compacting"
      echo "  --db-path DIR  Path to archiver LMDB directory (default: .prover-data/archiver)"
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

DATA_FILE="$DB_DIR/data.mdb"
LOCK_FILE="$DB_DIR/lock.mdb"

# --- Validate database exists ---
if [[ ! -f "$DATA_FILE" ]]; then
  echo "Error: database not found at $DATA_FILE" >&2
  exit 1
fi

# --- Safety: check that prover is not running ---
# Check for aztec/node processes that would hold an LMDB writer lock
check_prover_running() {
  # Check for aztec node / prover processes
  if pgrep -f "aztec.*start.*--prover" >/dev/null 2>&1; then
    return 0
  fi
  if pgrep -f "aztec.*prover" >/dev/null 2>&1; then
    return 0
  fi
  # Check if LMDB has active readers (mdb_stat shows "Number of readers used")
  if command -v mdb_stat >/dev/null 2>&1; then
    local readers
    readers=$(mdb_stat -e "$DB_DIR" 2>/dev/null | grep "Number of readers used" | awk '{print $NF}')
    if [[ -n "$readers" && "$readers" -gt 0 ]]; then
      return 0
    fi
  fi
  return 1
}

if check_prover_running; then
  echo "Error: the prover appears to be running. Stop it before compacting." >&2
  echo "  (Detected active aztec/prover process or LMDB readers)" >&2
  exit 1
fi

# --- Helpers ---
human_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    echo "$(echo "scale=1; $bytes / 1073741824" | bc) GB"
  elif (( bytes >= 1048576 )); then
    echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
  elif (( bytes >= 1024 )); then
    echo "$(echo "scale=1; $bytes / 1024" | bc) KB"
  else
    echo "$bytes B"
  fi
}

SIZE_BEFORE=$(stat -f%z "$DATA_FILE" 2>/dev/null || stat -c%s "$DATA_FILE" 2>/dev/null)
echo "=== Archiver LMDB Compaction ==="
echo "Database:     $DB_DIR"
echo "Current size: $(human_size "$SIZE_BEFORE") ($SIZE_BEFORE bytes)"
echo ""

# --- Dry run: report stats and estimate savings ---
if [[ $DRY_RUN -eq 1 ]]; then
  if command -v mdb_stat >/dev/null 2>&1; then
    echo "LMDB environment stats:"
    mdb_stat -e "$DB_DIR" 2>/dev/null | grep -E "(Page size|pages used|Map size)" | sed 's/^/  /'
    PAGE_SIZE=$(mdb_stat -e "$DB_DIR" 2>/dev/null | grep "Page size" | awk '{print $NF}')
    PAGES_USED=$(mdb_stat -e "$DB_DIR" 2>/dev/null | grep "pages used" | awk '{print $NF}')
    # Free pages are pages allocated but no longer in use (reclaimable by compaction)
    FREE_PAGES=$(mdb_stat -ef "$DB_DIR" 2>/dev/null | grep "Free pages" | awk '{print $NF}')
    FREE_PAGES=${FREE_PAGES:-0}
    if [[ -n "$PAGE_SIZE" && -n "$PAGES_USED" ]]; then
      LIVE_PAGES=$((PAGES_USED - FREE_PAGES))
      LIVE_BYTES=$((PAGE_SIZE * LIVE_PAGES))
      FREE_BYTES=$((PAGE_SIZE * FREE_PAGES))
      echo ""
      echo "Total pages:  $PAGES_USED ($LIVE_PAGES live + $FREE_PAGES free)"
      echo "Data in use:  $(human_size "$LIVE_BYTES")"
      echo "Reclaimable:  $(human_size "$FREE_BYTES") ($FREE_PAGES free pages)"
      if (( SIZE_BEFORE > 0 )); then
        PCT=$(echo "scale=1; $FREE_BYTES * 100 / $SIZE_BEFORE" | bc)
        echo "Fragmentation: ${PCT}%"
      fi
    fi
  else
    echo "(mdb_stat not available; install lmdb for detailed stats)"
  fi
  if [[ $PURGE_LOGS -eq 1 ]]; then
    echo ""
    echo "Log purge estimate (--purge-logs):"
    node "$BASE_DIR/scripts/purge-archiver-logs.js" --dry-run --db-path "$DB_DIR" 2>&1 | tail -5
  fi
  echo ""
  echo "Dry run complete. No changes made."
  exit 0
fi

# --- Optional: purge logs first ---
if [[ $PURGE_LOGS -eq 1 ]]; then
  echo "--- Running log purge ---"
  node "$BASE_DIR/scripts/purge-archiver-logs.js" --db-path "$DB_DIR"
  echo ""
  # Re-read size after purge (LMDB file won't shrink but pages are freed)
  SIZE_AFTER_PURGE=$(stat -f%z "$DATA_FILE" 2>/dev/null || stat -c%s "$DATA_FILE" 2>/dev/null)
  echo "Size after purge (before compaction): $(human_size "$SIZE_AFTER_PURGE")"
  echo ""
fi

# --- Compact ---
COMPACT_DIR="${DB_DIR}.compact.$$"
BACKUP_DIR="${DB_DIR}.pre-compact.$$"

cleanup() {
  rm -rf "$COMPACT_DIR" 2>/dev/null || true
  rm -rf "$BACKUP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$COMPACT_DIR"

echo "--- Compacting database ---"

if command -v mdb_copy >/dev/null 2>&1; then
  echo "Using: mdb_copy -c"
  # mdb_copy -c performs a compacted copy: rewrites pages contiguously,
  # eliminating free pages and fragmentation.
  # -n flag means "open env with MDB_NOSUBDIR" -- we do NOT use it since
  # the archiver uses the standard subdir layout (data.mdb inside a directory).
  if ! mdb_copy -c "$DB_DIR" "$COMPACT_DIR"; then
    echo "Error: mdb_copy failed" >&2
    exit 1
  fi
else
  echo "mdb_copy not found, falling back to Python lmdb"
  python3 -c "
import lmdb, sys
env = lmdb.open('$DB_DIR', readonly=True, max_dbs=10,
                map_size=2*1024*1024*1024, subdir=True)
env.copy('$COMPACT_DIR', compact=True)
env.close()
print('Python lmdb compaction complete')
"
fi

# Verify the compacted copy exists and is non-empty
COMPACT_DATA="$COMPACT_DIR/data.mdb"
if [[ ! -f "$COMPACT_DATA" ]]; then
  echo "Error: compacted data.mdb not found at $COMPACT_DATA" >&2
  exit 1
fi

SIZE_COMPACTED=$(stat -f%z "$COMPACT_DATA" 2>/dev/null || stat -c%s "$COMPACT_DATA" 2>/dev/null)
if [[ "$SIZE_COMPACTED" -lt 4096 ]]; then
  echo "Error: compacted database is suspiciously small ($SIZE_COMPACTED bytes)" >&2
  exit 1
fi

# Verify compacted DB is readable
if command -v mdb_stat >/dev/null 2>&1; then
  if ! mdb_stat -e "$COMPACT_DIR" >/dev/null 2>&1; then
    echo "Error: compacted database fails mdb_stat validation" >&2
    exit 1
  fi
fi

# --- Atomic swap ---
echo "Swapping databases..."

# 1. Move original to backup location
mkdir -p "$BACKUP_DIR"
mv "$DATA_FILE" "$BACKUP_DIR/data.mdb"
if [[ -f "$LOCK_FILE" ]]; then
  mv "$LOCK_FILE" "$BACKUP_DIR/lock.mdb"
fi

# 2. Move compacted data into place
mv "$COMPACT_DATA" "$DATA_FILE"
# Remove stale lock file from compacted copy if present; a fresh one will be
# created when the DB is next opened.
if [[ -f "$COMPACT_DIR/lock.mdb" ]]; then
  rm -f "$COMPACT_DIR/lock.mdb"
fi

# 3. Preserve db_version file (not part of LMDB, Aztec metadata)
# It stays in place since we only moved data.mdb/lock.mdb.

# 4. Clean up backup (only after successful swap)
rm -rf "$BACKUP_DIR"

SIZE_AFTER=$(stat -f%z "$DATA_FILE" 2>/dev/null || stat -c%s "$DATA_FILE" 2>/dev/null)
SAVED=$((SIZE_BEFORE - SIZE_AFTER))

echo ""
echo "=== Compaction Complete ==="
echo "Before:  $(human_size "$SIZE_BEFORE")"
echo "After:   $(human_size "$SIZE_AFTER")"
if (( SAVED > 0 )); then
  echo "Saved:   $(human_size "$SAVED") ($(echo "scale=1; $SAVED * 100 / $SIZE_BEFORE" | bc)%)"
elif (( SAVED == 0 )); then
  echo "Saved:   0 B (database was already fully compacted)"
else
  echo "Note:    compacted file is $(human_size $((-SAVED))) larger (normal for low-fragmentation DBs)"
fi

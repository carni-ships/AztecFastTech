#!/bin/bash
# Tear down the BB scratch RAM disk.
#
# Safety: refuses to unmount if any bb/bb-avm processes are still running,
# unless --force is passed.
#
# Usage:
#   ./scripts/teardown-ramdisk.sh           # safe teardown
#   ./scripts/teardown-ramdisk.sh --force   # force even if bb is running

set -e

VOLUME_NAME="BBScratch"
MOUNT_PATH="/Volumes/$VOLUME_NAME"
FORCE=0

if [ "$1" = "--force" ]; then
  FORCE=1
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script is macOS-only."
  exit 1
fi

# Check if mounted
if ! mount | grep -q "$MOUNT_PATH"; then
  echo "No RAM disk mounted at $MOUNT_PATH. Nothing to do."
  exit 0
fi

# Safety: check for running bb processes
BB_PIDS=$(pgrep -f 'bb(-avm)?\b' 2>/dev/null || true)
if [ -n "$BB_PIDS" ] && [ "$FORCE" -eq 0 ]; then
  echo "ERROR: bb processes still running (PIDs: $(echo $BB_PIDS | tr '\n' ' '))."
  echo "  These may have open files on the RAM disk."
  echo "  Stop the prover first, or use --force to detach anyway."
  exit 1
fi

# Check for any open files on the volume
OPEN_COUNT=$(lsof +D "$MOUNT_PATH" 2>/dev/null | wc -l || echo "0")
if [ "$OPEN_COUNT" -gt 1 ] && [ "$FORCE" -eq 0 ]; then
  echo "WARNING: $((OPEN_COUNT - 1)) open files on $MOUNT_PATH."
  echo "  Use --force to detach anyway."
  lsof +D "$MOUNT_PATH" 2>/dev/null | head -5
  exit 1
fi

# Show what we're cleaning up
USED=$(df -h "$MOUNT_PATH" 2>/dev/null | tail -1 | awk '{print $3}')
echo "Ejecting RAM disk at $MOUNT_PATH (${USED} used)..."

if [ "$FORCE" -eq 1 ]; then
  hdiutil detach "$MOUNT_PATH" -force 2>/dev/null
else
  hdiutil detach "$MOUNT_PATH" 2>/dev/null
fi

if mount | grep -q "$MOUNT_PATH"; then
  echo "ERROR: Failed to detach RAM disk."
  exit 1
fi

echo "RAM disk ejected. Memory reclaimed."

# Remind about TMPDIR
if [ "${TMPDIR:-}" = "$MOUNT_PATH" ]; then
  echo ""
  echo "NOTE: TMPDIR is still set to $MOUNT_PATH (now invalid)."
  echo "  Run: unset TMPDIR"
fi

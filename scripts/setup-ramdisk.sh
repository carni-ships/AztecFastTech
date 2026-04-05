#!/bin/bash
# Create a RAM disk for BB polynomial scratch files on macOS.
#
# The prover (BB_SLOW_LOW_MEMORY=1) writes mmap'd temp files via
# std::filesystem::temp_directory_path(). On macOS this reads TMPDIR.
# A RAM disk eliminates filesystem/SSD overhead for these scratch files.
#
# Usage:
#   ./scripts/setup-ramdisk.sh              # 4 GiB (default)
#   ./scripts/setup-ramdisk.sh 2048         # 2 GiB
#   ./scripts/setup-ramdisk.sh 6144         # 6 GiB
#
# After creation, set TMPDIR to redirect BB scratch:
#   export TMPDIR=/Volumes/BBScratch
#
# Or use BB_RAMDISK_SIZE_MB in start-prover.sh for automatic setup.

set -e

SIZE_MB="${1:-4096}"
VOLUME_NAME="BBScratch"
MOUNT_PATH="/Volumes/$VOLUME_NAME"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script is macOS-only (uses hdiutil/diskutil)."
  exit 1
fi

# Check if already mounted
if mount | grep -q "$MOUNT_PATH"; then
  echo "RAM disk already mounted at $MOUNT_PATH"
  df -h "$MOUNT_PATH" | tail -1
  echo ""
  echo "To use: export TMPDIR=$MOUNT_PATH"
  exit 0
fi

# Validate size: minimum 512 MiB, maximum half of physical RAM
TOTAL_MEM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
MAX_MB=$(( TOTAL_MEM_MB / 2 ))

if [ "$SIZE_MB" -lt 512 ]; then
  echo "ERROR: Minimum RAM disk size is 512 MiB (requested ${SIZE_MB} MiB)."
  exit 1
fi

if [ "$SIZE_MB" -gt "$MAX_MB" ]; then
  echo "ERROR: Requested ${SIZE_MB} MiB exceeds half of physical RAM (${MAX_MB} MiB)."
  echo "  Using more than half for a RAM disk leaves insufficient memory for the prover."
  exit 1
fi

# Check available memory before creating
FREE_PAGES=$(vm_stat | awk '/Pages free|Pages inactive/ {gsub(/\./,"",$NF); sum+=$NF} END {print sum}')
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
FREE_MB=$(( FREE_PAGES * PAGE_SIZE / 1048576 ))

if [ "$SIZE_MB" -gt "$FREE_MB" ]; then
  echo "WARNING: Requesting ${SIZE_MB} MiB but only ${FREE_MB} MiB free+inactive."
  echo "  This may cause memory pressure and swap. Proceeding anyway..."
fi

# Create the RAM disk
# hdiutil uses 512-byte sectors, so sectors = MiB * 2048
SECTORS=$(( SIZE_MB * 2048 ))

echo "Creating ${SIZE_MB} MiB RAM disk..."
DISK_DEV=$(hdiutil attach -nomount "ram://$SECTORS" 2>&1)
if [ $? -ne 0 ] || [ -z "$DISK_DEV" ]; then
  echo "ERROR: Failed to create RAM disk device."
  echo "  hdiutil output: $DISK_DEV"
  exit 1
fi

# Clean whitespace from device path
DISK_DEV=$(echo "$DISK_DEV" | tr -d '[:space:]')

# Format as HFS+ (required for macOS mmap compatibility)
echo "Formatting as HFS+ on $DISK_DEV..."
if ! diskutil erasevolume HFS+ "$VOLUME_NAME" "$DISK_DEV" >/dev/null 2>&1; then
  echo "ERROR: Failed to format RAM disk. Detaching device..."
  hdiutil detach "$DISK_DEV" 2>/dev/null || true
  exit 1
fi

# Verify mount
if ! mount | grep -q "$MOUNT_PATH"; then
  echo "ERROR: RAM disk formatted but not mounted at expected path."
  hdiutil detach "$DISK_DEV" 2>/dev/null || true
  exit 1
fi

echo ""
echo "RAM disk ready:"
df -h "$MOUNT_PATH" | tail -1
echo ""
echo "Device: $DISK_DEV"
echo "Mount:  $MOUNT_PATH"
echo "Size:   ${SIZE_MB} MiB"
echo ""
echo "To redirect BB scratch files to the RAM disk:"
echo "  export TMPDIR=$MOUNT_PATH"
echo ""
echo "Or set BB_RAMDISK_SIZE_MB=$SIZE_MB in start-prover.sh (handles this automatically)."
echo ""
echo "To tear down: ./scripts/teardown-ramdisk.sh"

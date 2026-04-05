#!/bin/bash
# Track per-epoch proving times and calculate buffer vs epoch window.
# Usage: ./scripts/track-epoch-timing.sh [log_file]
# Runs once against the log, or tail -f for live tracking.

LOG_FILE="${1:-.prover-data/prover.log}"
EPOCH_WINDOW_S=1200  # 20 minutes

python3 - "$LOG_FILE" "$EPOCH_WINDOW_S" <<'PYEOF'
import re, sys, json
from collections import defaultdict
from datetime import datetime

log_file = sys.argv[1]
epoch_window = int(sys.argv[2])

log = open(log_file).read()

# Extract proof completions with timestamps and epoch IDs
# Pattern: [HH:MM:SS.mmm] INFO: bb-prover Generated proof for X in Y ms
proofs = re.findall(
    r'\[(\d+:\d+:\d+)\.\d+\].*?Generated proof for (\w+) in (\d+) ms.*?"circuitSize":(\d+)',
    log
)

# Extract epoch job starts to map jobs to epochs
# Pattern: Starting job id=EPOCH:TYPE:HASH
job_epochs = {}
for m in re.finditer(r'Starting job id=(\d+):(\w+):(\w+)', log):
    epoch, jtype, jhash = m.groups()
    job_epochs[f"{jtype}:{jhash}"] = int(epoch)

# Extract epoch start/end events
epoch_starts = {}
for m in re.finditer(r'Starting pre-processing for checkpoint \d+ \(epoch (\d+)', log):
    epoch = int(m.group(1))
    if epoch not in epoch_starts:
        epoch_starts[epoch] = True

# Group proofs by epoch (best effort — use job IDs where available)
# For now, group by the epoch we can identify
epoch_proofs = defaultdict(list)
for ts, name, dur_ms, size in proofs:
    epoch_proofs["current"].append({
        "time": ts,
        "circuit": name,
        "duration_ms": int(dur_ms),
        "size": int(size)
    })

# Also try to group by actual epoch from job completions
job_completions = re.findall(
    r'Job id=(\d+):(\w+):\w+ type=\w+ completed',
    log
)
epoch_completion_counts = defaultdict(int)
for epoch, jtype in job_completions:
    epoch_completion_counts[int(epoch)] += 1

print("=== Epoch Proving Time Tracker ===")
print()

# Per-circuit breakdown
circuit_stats = defaultdict(lambda: {"count": 0, "total_ms": 0, "max_ms": 0, "sizes": set()})
for p in epoch_proofs["current"]:
    c = p["circuit"]
    circuit_stats[c]["count"] += 1
    circuit_stats[c]["total_ms"] += p["duration_ms"]
    circuit_stats[c]["max_ms"] = max(circuit_stats[c]["max_ms"], p["duration_ms"])
    circuit_stats[c]["sizes"].add(p["size"])

print(f"{'Circuit':<35} {'Count':>5} {'Avg':>8} {'Max':>8} {'Size':>6}")
print("-" * 68)
for name, stats in sorted(circuit_stats.items(), key=lambda x: -x[1]["total_ms"]):
    avg = stats["total_ms"] / stats["count"]
    sizes = ",".join(f"2^{s}" for s in sorted(stats["sizes"]))
    print(f"{name:<35} {stats['count']:>5} {avg/1000:>7.1f}s {stats['max_ms']/1000:>7.1f}s {sizes:>6}")

total_ms = sum(p["duration_ms"] for p in epoch_proofs["current"])
total_proofs = len(epoch_proofs["current"])

print("-" * 68)
print(f"{'Total':<35} {total_proofs:>5} {total_ms/1000:>7.1f}s")
print()

# Epoch completion summary
print("Epoch Job Completions:")
for epoch in sorted(epoch_completion_counts.keys()):
    count = epoch_completion_counts[epoch]
    print(f"  Epoch {epoch}: {count} jobs completed")
print()

# Wall-clock estimate: first proof start to last proof end
if proofs:
    times = []
    for ts, _, _, _ in proofs:
        h, m, s = ts.split(":")
        times.append(int(h)*3600 + int(m)*60 + int(s))
    first = min(times)
    last = max(times)
    wall_s = last - first
    print(f"Wall-clock span (first→last proof): {wall_s}s ({wall_s/60:.1f} min)")
else:
    wall_s = 0

# Buffer calculation
if total_proofs > 0:
    # For a full epoch (~98 jobs), extrapolate from what we have
    avg_proof_ms = total_ms / total_proofs
    full_epoch_serial = avg_proof_ms * 98 / 1000
    # Root rollup adds ~300s on top
    full_epoch_serial_with_root = full_epoch_serial + 300

    print()
    print("--- Projections for Full Epoch (98 jobs) ---")
    print(f"  Avg proof time:          {avg_proof_ms/1000:.1f}s")
    print(f"  Serial sum (no root):    {full_epoch_serial:.0f}s ({full_epoch_serial/60:.1f} min)")
    print(f"  + Root rollup (~300s):   {full_epoch_serial_with_root:.0f}s ({full_epoch_serial_with_root/60:.1f} min)")
    print()
    for agents in [1, 2, 3]:
        # Parallel time ≈ serial/agents + root_rollup (root runs solo)
        parallel_s = (full_epoch_serial / agents) + 300
        buffer_s = epoch_window - parallel_s
        pct = parallel_s / epoch_window * 100
        status = "OK" if buffer_s > 0 else "OVER"
        print(f"  {agents} agent(s): ~{parallel_s:.0f}s ({parallel_s/60:.1f} min) | buffer: {buffer_s:.0f}s ({buffer_s/60:.1f} min) | {pct:.0f}% [{status}]")

    print()
    print(f"  Epoch window: {epoch_window}s ({epoch_window/60:.0f} min)")
    print()
    print("NOTE: These are projections. Wait for a complete epoch for actual numbers.")
    print("Root rollup (2^24, 13M gates) estimate: ~300s based on prior epochs.")

PYEOF

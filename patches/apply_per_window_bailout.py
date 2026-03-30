#!/usr/bin/env python3
"""Add per-window bucket imbalance bailout to metal_msm.mm.
The existing bailout only checks global max bucket count (>25%).
This adds a per-window check: if any window has >10% of points in one bucket,
the MSM is likely structured data that causes GPU reduce pathology.
Bail out to CPU where Pippenger handles this efficiently."""
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Find the bailout check and add per-window check before it
OLD = '''                // Fall back for pathological cases (>25% in one bucket).
                // Even though bucket 0 is skipped by GPU kernels, large non-zero buckets
                // cause catastrophic thread divergence in the reduce kernel (sequential
                // point additions stall entire SIMD groups for seconds).
                if (!skip_imbalance_check && max_bucket_count > n2 / 4) {
                    fprintf(stderr, "[GPU_MSM] extreme bucket imbalance (max=%u, n=%zu), falling back to CPU\\n",
                            max_bucket_count, n2);
                    return false;
                }'''

NEW = '''                // Per-window imbalance check: if any window has >10% of points in one bucket,
                // the data is structured enough to trigger GPU reduce pathology (1000ms+ stalls).
                // CPU Pippenger handles this efficiently with its tree-based reduction.
                // skip_imbalance_check bypasses both per-window and global checks (e.g. Gemini fold
                // polynomials with benign ~18% imbalance from random linear combinations).
                if (!skip_imbalance_check) {
                    for (size_t w = 0; w < n_windows; w++) {
                        size_t w_off = w * n_buckets;
                        uint32_t w_max = 0;
                        for (size_t b = 0; b < n_buckets; b++) {
                            if (all_counts[w_off + b] > w_max) w_max = all_counts[w_off + b];
                        }
                        if (w_max > n2 / 10) {
                            fprintf(stderr, "[GPU_MSM] per-window imbalance (w=%zu, max=%u, n=%zu), falling back to CPU\\n",
                                    w, w_max, n2);
                            return false;
                        }
                    }
                }

                // Also fall back for truly pathological cases (>25% in one non-zero bucket)
                if (!skip_imbalance_check && max_bucket_count > n2 / 4) {
                    fprintf(stderr, "[GPU_MSM] extreme bucket imbalance (max=%u, n=%zu), falling back to CPU\\n",
                            max_bucket_count, n2);
                    return false;
                }'''

if OLD in content:
    content = content.replace(OLD, NEW)
    with open(filepath, 'w') as f:
        f.write(content)
    print("  [4] Per-window bucket bailout (>10% per window)")
else:
    print("ERROR: Could not find bailout block in metal_msm.mm", file=sys.stderr)
    sys.exit(1)

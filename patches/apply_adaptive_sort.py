#!/usr/bin/env python3
"""Apply adaptive bucket sort optimization to metal_msm.mm.
Detects bucket imbalance via coefficient of variation before sorting.
Skips count-sorted mapping for uniform distributions (random scalars)."""
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Anchor: find the exact block between these two markers
START_MARKER = '            // Fall back to CPU only for truly pathological cases (>25% in one bucket).\n            {'
END_MARKER = '            }\n\n            auto _gpu_t3'

start_idx = content.find(START_MARKER)
end_idx = content.find(END_MARKER)

if start_idx < 0 or end_idx < 0:
    print(f"ERROR: Could not find target block (start={start_idx}, end={end_idx})", file=sys.stderr)
    sys.exit(1)

# Extract everything between start and end (inclusive of the closing brace)
old_block = content[start_idx:end_idx + len('            }')]

new_block = '''            // Adaptive count-sorted mapping: detect bucket imbalance before sorting.
            // Skip sorting for uniformly distributed data (random scalars) to avoid overhead.
            {
                auto* csm = static_cast<uint32_t*>([count_sorted_map_buffer contents]);
                uint32_t max_bucket_count = 0;

                // Compute coefficient of variation to detect imbalance
                bool needs_sorting = false;
                for (size_t w = 0; w < n_windows && !needs_sorting; w++) {
                    size_t w_off = w * n_buckets;
                    uint64_t sum = 0, sum_sq = 0;
                    for (size_t b = 0; b < n_buckets; b++) {
                        uint64_t c = all_counts[w_off + b];
                        sum += c;
                        sum_sq += c * c;
                    }
                    double mean = static_cast<double>(sum) / n_buckets;
                    double mean_sq = static_cast<double>(sum_sq) / n_buckets;
                    double cv_sq = (mean_sq - mean * mean) / (mean * mean + 1e-10);
                    if (cv_sq > 0.5) needs_sorting = true;
                }

                if (!needs_sorting) {
                    // Identity mapping: uniform distribution, no reordering needed
                    size_t total = n_buckets * n_windows;
                    for (size_t i = 0; i < total; i++) {
                        csm[i] = static_cast<uint32_t>(i);
                    }
                } else {
                    for (size_t w = 0; w < n_windows; w++) {
                        size_t w_off = w * n_buckets;

                        // Find max count for histogram sizing
                        uint32_t wmax = 0;
                        for (size_t b = 0; b < n_buckets; b++) {
                            uint32_t c = all_counts[w_off + b];
                            if (c > wmax) wmax = c;
                        }
                        if (wmax > max_bucket_count) max_bucket_count = wmax;

                        // Histogram of bucket counts
                        std::vector<uint32_t> hist(wmax + 1, 0);
                        for (size_t b = 0; b < n_buckets; b++) {
                            hist[all_counts[w_off + b]]++;
                        }

                        // Prefix sum descending: position[c] = where buckets with count c start
                        std::vector<uint32_t> pos(wmax + 1, 0);
                        uint32_t running = 0;
                        for (uint32_t c = wmax + 1; c > 0; c--) {
                            pos[c - 1] = running;
                            running += hist[c - 1];
                        }

                        // Scatter: map sorted position to original (window-global) bucket index
                        for (size_t b = 0; b < n_buckets; b++) {
                            uint32_t c = all_counts[w_off + b];
                            csm[w_off + pos[c]] = static_cast<uint32_t>(w_off + b);
                            pos[c]++;
                        }
                    }
                }

                // Only fall back for truly pathological cases (>25% in one non-zero bucket)
                if (needs_sorting && max_bucket_count > n2 / 4) {
                    fprintf(stderr, "[GPU_MSM] extreme bucket imbalance (max=%u, n=%zu), falling back to CPU\\n",
                            max_bucket_count, n2);
                    return false;
                }
            }'''

content = content[:start_idx] + new_block + content[start_idx + len(old_block):]
with open(filepath, 'w') as f:
    f.write(content)
print("  [3] Adaptive bucket sort: skip sorting for uniform distributions")

# Analysis tooling


Python tools for converting `pgbench --log` output into HdrHistogram artifacts
and producing the comparison plots used in the blog post. Managed via
[`uv`](https://github.com/astral-sh/uv) — no system Python required.



## Setup

```sh
cd analysis
uv sync
```

This installs the four console scripts into `.venv/bin/`:

- `pgbench-log-to-hdr` — convert pgbench logs to `.hgrm` + `.percentiles.json`
- `plot-tps`           — TPS-over-time line plot
- `plot-latency-pct`   — percentile-over-percentile plot (canonical HdrHistogram view)
- `compare-scenarios`  — full campaign comparison (TPS, latency, summary tables)



## Examples

```sh
# Convert a single run's logs:
uv run pgbench-log-to-hdr /opt/bench/runs/nvme-ext4/tpcb/20260509T140000Z/pgbench

# Plot TPS for two scenarios:
uv run plot-tps \
    results/2026-05-XX/nvme-ext4/tpcb/20260509T140000Z \
    results/2026-05-XX/zerofs/tpcb/20260509T160000Z \
    --label NVMe --label "S3 (ZeroFS)" -o tps.png

# Full campaign comparison:
uv run compare-scenarios results/2026-05-XX/
```



## File formats

Each pgbench run directory will contain:

```
pgbench.<pid>.<thread>          # pgbench --log raw output (one per worker)
pgbench.elapsed.csv             # produced: per-txn elapsed (µs) — flat CSV
pgbench.hgrm                    # produced: HdrHistogram percentile distribution
pgbench.percentiles.json        # produced: p50/p95/p99/p99.9/p99.99/max summary
```

The `.hgrm` files open directly in
[HistogramLogAnalyzer](https://github.com/HdrHistogram/HistogramLogAnalyzer)
for ad-hoc inspection.



## Why HdrHistogram (and not just numpy percentiles)?

For 60-minute runs at >10k TPS we have ~36 million samples per scenario.
A naive sort+percentile is fine in numpy but the HdrHistogram representation:

- Lets you merge multiple runs without keeping all raw samples.
- Produces a percentile-distribution file that's universally consumable
  (Java / Python / C analyzers).
- Compresses the per-µs distribution to ~10 KB while preserving 3 sig figs
  out to p99.9999.

If you only need a quick look, `plot-latency-pct` accepts the raw `.elapsed.csv`
files too — HdrHistogram is recommended but not required.

"""Convert pgbench --log files into HdrHistogram artifacts.

Inputs : a pgbench-log prefix (e.g. /opt/bench/runs/<scenario>/<workload>/<ts>/pgbench)
Outputs:
  - <prefix>.hgrm        — HdrHistogram interval-log file (consumable by HistogramLogAnalyzer)
  - <prefix>.percentiles.json — JSON summary with p50/p95/p99/p99.9/p99.99/max
  - <prefix>.elapsed.csv — raw per-txn elapsed-microsecond timings (one per line)

Usage:
  pgbench-log-to-hdr <prefix>...
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable

from hdrh.histogram import HdrHistogram

from .pgbench_log import collect_elapsed_us, discover_log_prefixes


# 1 µs to 60 s, 3 significant digits.
HDR_LOWEST = 1
HDR_HIGHEST = 60_000_000
HDR_SIGFIG = 3

PERCENTILES = (50.0, 90.0, 95.0, 99.0, 99.9, 99.99)


def build_histogram(elapsed: Iterable[int]) -> HdrHistogram:
    h = HdrHistogram(HDR_LOWEST, HDR_HIGHEST, HDR_SIGFIG)
    overflow = 0
    underflow = 0
    for v in elapsed:
        if v < HDR_LOWEST:
            underflow += 1
            v = HDR_LOWEST
        elif v > HDR_HIGHEST:
            overflow += 1
            v = HDR_HIGHEST
        h.record_value(v)
    if overflow or underflow:
        print(
            f"  warning: {overflow} samples > {HDR_HIGHEST} us, "
            f"{underflow} samples < {HDR_LOWEST} us — clamped",
            file=sys.stderr,
        )
    return h


def write_artifacts(prefix: Path, hist: HdrHistogram, raw_csv_count: int) -> None:
    hgrm_path = Path(f"{prefix}.hgrm")
    json_path = Path(f"{prefix}.percentiles.json")

    with hgrm_path.open("wb") as fh:
        # output_percentile_distribution writes the canonical HdrHistogram
        # tabular format; HistogramLogAnalyzer GUI reads it directly. The
        # scaling ratio is 1.0 because our samples are already in the unit
        # we want to display (microseconds).
        hist.output_percentile_distribution(
            fh,
            output_value_unit_scaling_ratio=1.0,
            ticks_per_half_distance=5,
        )

    summary = {
        "count": hist.get_total_count(),
        "min_us": hist.get_min_value(),
        "max_us": hist.get_max_value(),
        "mean_us": hist.get_mean_value(),
        "stddev_us": hist.get_stddev(),
        "percentiles_us": {
            f"p{p:g}": hist.get_value_at_percentile(p) for p in PERCENTILES
        },
        "raw_csv_count": raw_csv_count,
    }
    with json_path.open("w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    print(f"  wrote {hgrm_path.name} and {json_path.name}", file=sys.stderr)


def write_raw_csv(prefix: Path, elapsed: Iterable[int]) -> int:
    csv_path = Path(f"{prefix}.elapsed.csv")
    count = 0
    with csv_path.open("w") as fh:
        fh.write("elapsed_us\n")
        for v in elapsed:
            fh.write(f"{v}\n")
            count += 1
    print(f"  wrote {csv_path.name} ({count} samples)", file=sys.stderr)
    return count


def process_prefix(prefix: Path) -> None:
    print(f"Processing prefix: {prefix}", file=sys.stderr)

    # First pass — write raw CSV and count.
    count = write_raw_csv(prefix, collect_elapsed_us(prefix))
    if count == 0:
        print(f"  no records found for {prefix}", file=sys.stderr)
        return

    # Second pass — build histogram.
    hist = build_histogram(collect_elapsed_us(prefix))
    write_artifacts(prefix, hist, count)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "targets",
        nargs="+",
        help="pgbench --log-prefix paths, OR run-directory paths (auto-discovered).",
    )
    args = p.parse_args()

    prefixes: list[Path] = []
    for t in args.targets:
        path = Path(t)
        if path.is_dir():
            discovered = discover_log_prefixes(path)
            if not discovered:
                print(f"WARNING: no pgbench logs in {path}", file=sys.stderr)
            prefixes.extend(discovered)
        else:
            prefixes.append(path)

    for prefix in prefixes:
        process_prefix(prefix)

    return 0


if __name__ == "__main__":
    sys.exit(main())

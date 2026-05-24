"""Percentile-over-percentile latency plot — the canonical HdrHistogram view.

x-axis: percentile (log scale, 1 → 99.999)
y-axis: latency in microseconds (log scale)

Accepts either:
 - run directories — auto-discovers pgbench logs and builds a histogram on the fly
 - existing .elapsed.csv files (raw timings)
 - existing .percentiles.json summaries (only the listed percentiles plotted)

Usage:
  plot-latency-pct <run_dir>... -o latency.png
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from hdrh.histogram import HdrHistogram

from .pgbench_log import collect_elapsed_us, discover_log_prefixes
from .pgbench_log_to_hdr import HDR_HIGHEST, HDR_LOWEST, HDR_SIGFIG


# Percentiles plotted. The far tail benefits from very fine-grained sampling
# because the value at p99.99 is materially different from p99 in the S3
# scenarios.
_PERCENTILES = np.concatenate(
    [
        np.linspace(0, 90, 91),
        np.linspace(90, 99, 91)[1:],
        np.linspace(99, 99.99, 100)[1:],
    ]
)


def hist_from_run(run_dir: Path) -> HdrHistogram | None:
    prefixes = discover_log_prefixes(run_dir)
    if not prefixes:
        return None
    h = HdrHistogram(HDR_LOWEST, HDR_HIGHEST, HDR_SIGFIG)
    for prefix in prefixes:
        for v in collect_elapsed_us(prefix):
            v = max(HDR_LOWEST, min(HDR_HIGHEST, v))
            h.record_value(v)
    return h if h.get_total_count() > 0 else None


def hist_from_csv(csv_path: Path) -> HdrHistogram:
    h = HdrHistogram(HDR_LOWEST, HDR_HIGHEST, HDR_SIGFIG)
    with csv_path.open("r") as fh:
        next(fh, None)  # header
        for line in fh:
            try:
                v = int(line.strip())
            except ValueError:
                continue
            v = max(HDR_LOWEST, min(HDR_HIGHEST, v))
            h.record_value(v)
    return h


def label_for(p: Path) -> str:
    parts = p.parts
    if p.is_dir() and len(parts) >= 3:
        return f"{parts[-3]}/{parts[-2]}"
    return p.stem


def percentile_curve(hist: HdrHistogram) -> tuple[np.ndarray, np.ndarray]:
    xs = _PERCENTILES
    ys = np.array([hist.get_value_at_percentile(p) for p in xs])
    return xs, ys


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "inputs",
        nargs="+",
        type=Path,
        help="Run directories or .elapsed.csv files.",
    )
    p.add_argument("--label", action="append", default=[])
    p.add_argument("--output", "-o", type=Path, default=Path("latency_percentiles.png"))
    p.add_argument("--title", default="Latency percentiles (HdrHistogram)")
    args = p.parse_args()

    fig, ax = plt.subplots(figsize=(12, 7))
    any_data = False

    for i, src in enumerate(args.inputs):
        if src.is_dir():
            hist = hist_from_run(src)
        elif src.suffix == ".csv":
            hist = hist_from_csv(src)
        else:
            print(f"WARNING: unsupported input {src}", file=sys.stderr)
            continue

        if hist is None or hist.get_total_count() == 0:
            print(f"WARNING: no data in {src}", file=sys.stderr)
            continue

        xs, ys = percentile_curve(hist)
        any_data = True
        label = args.label[i] if i < len(args.label) else label_for(src)
        # Plot against log-scale "percentile distance from 100": 1 / (1 - p/100)
        # — the canonical HdrHistogram x-axis. p=99 → 100, p=99.9 → 1000, etc.
        x_log = 1.0 / (1.0 - xs / 100.0)
        ax.plot(x_log, ys, label=label, linewidth=1.5)

    if not any_data:
        print("ERROR: no data to plot.", file=sys.stderr)
        return 1

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Percentile (log scale: 10 = p90, 100 = p99, 1000 = p99.9)")
    ax.set_ylabel("Latency (µs, log scale)")
    ax.set_title(args.title)
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best")

    # Overlay textual percentile markers.
    for pct, x in [(90, 10), (99, 100), (99.9, 1000), (99.99, 10000)]:
        ax.axvline(x, color="grey", alpha=0.2, linewidth=0.5)
        ax.text(
            x,
            ax.get_ylim()[1],
            f"p{pct}",
            ha="center",
            va="top",
            fontsize=9,
            color="grey",
        )

    fig.tight_layout()
    fig.savefig(args.output, dpi=120)
    print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""TPS-over-time plot from pgbench per-transaction logs.

Aggregates by 1-second bins, plots one line per scenario.

Usage:
  plot-tps <run_dir>...                      # one line per run
  plot-tps --label NVMe <dir1> --label S3 <dir2>   # custom labels
  plot-tps --output tps.png <run_dirs>...
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt

from .pgbench_log import discover_log_prefixes, iter_logs


def tps_per_second(prefix: Path) -> tuple[list[int], list[int]]:
    counts: dict[int, int] = defaultdict(int)
    for rec in iter_logs(prefix):
        counts[rec.time_epoch] += 1
    if not counts:
        return [], []
    t0 = min(counts)
    return (
        sorted(t - t0 for t in counts),
        [counts[t] for t in sorted(counts)],
    )


def label_for(run_dir: Path, override: str | None) -> str:
    if override:
        return override
    # Default label: <scenario>/<workload> from path components
    # /opt/bench/runs/<scenario>/<workload>/<ts>/  →  scenario/workload
    parts = run_dir.parts
    if len(parts) >= 3:
        return f"{parts[-3]}/{parts[-2]}"
    return run_dir.name


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "runs",
        nargs="+",
        type=Path,
        help="One or more run directories (each containing pgbench-prefixed log files).",
    )
    p.add_argument("--label", action="append", default=[], help="Custom label, in run order.")
    p.add_argument("--output", "-o", type=Path, default=Path("tps.png"))
    p.add_argument("--title", default="TPS over time")
    args = p.parse_args()

    fig, ax = plt.subplots(figsize=(12, 6))
    any_data = False

    for i, run_dir in enumerate(args.runs):
        prefixes = discover_log_prefixes(run_dir)
        if not prefixes:
            print(f"WARNING: no pgbench logs in {run_dir}", file=sys.stderr)
            continue

        # Concatenate all prefixes' tps within this run dir (typically just one).
        merged: dict[int, int] = defaultdict(int)
        for prefix in prefixes:
            for rec in iter_logs(prefix):
                merged[rec.time_epoch] += 1
        if not merged:
            continue

        t0 = min(merged)
        xs = sorted(t - t0 for t in merged)
        ys = [merged[t + t0] for t in xs]
        any_data = True

        label = args.label[i] if i < len(args.label) else label_for(run_dir, None)
        ax.plot(xs, ys, label=label, linewidth=1)

    if not any_data:
        print("ERROR: no data to plot.", file=sys.stderr)
        return 1

    ax.set_xlabel("Elapsed seconds")
    ax.set_ylabel("Transactions per second")
    ax.set_title(args.title)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")
    fig.tight_layout()
    fig.savefig(args.output, dpi=120)
    print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

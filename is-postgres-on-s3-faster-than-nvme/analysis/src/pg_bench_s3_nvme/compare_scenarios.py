"""Side-by-side scenario comparison driver.

Walks a campaign directory of the form

    results/<campaign>/<scenario>/<workload>/<timestamp>/

and emits:

  - tps_<workload>.png           (one line per scenario)
  - latency_<workload>.png       (percentile-over-percentile)
  - summary_<workload>.csv       (one row per scenario × percentile)
  - summary_<workload>.md        (markdown table for the blog)

Usage:
  compare-scenarios <campaign_dir>
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import matplotlib.pyplot as plt
from hdrh.histogram import HdrHistogram

import numpy as np

from .pgbench_log import collect_elapsed_us, discover_log_prefixes, iter_logs, open_text


def _path_or_zst(p: Path) -> Path | None:
    """Return whichever of `p` or `p.zst` exists, else None."""
    if p.exists():
        return p
    z = Path(str(p) + ".zst")
    if z.exists():
        return z
    return None
from .pgbench_log_to_hdr import HDR_HIGHEST, HDR_LOWEST, HDR_SIGFIG, PERCENTILES
from .plot_latency_pct import percentile_curve


SCENARIO_ORDER = [
    "nvme-ext4",
    "nvme-zfs", "nvme-zfs-fpi", "nvme-zfs-rec32k",
]
WORKLOADS = ("tpcb", "mixed")
# Percentiles for the bar chart — the "usual suspects" most readers expect.
BAR_PERCENTILES = (50.0, 90.0, 95.0, 99.0, 99.9, 99.99)


@dataclass
class RunData:
    scenario: str
    workload: str
    run_dir: Path
    histogram: HdrHistogram
    tps_series: list[tuple[int, int]]                          # (rel_seconds, tps)
    summary_tps: float | None                                  # from pgbench_summary.log
    checkpoints: list[tuple[float, str]] = field(default_factory=list)   # (rel_s, "starting"|"complete")
    wal_fpi_total: int | None = None                           # cumulative FPIs over steady-state
    wal_records_total: int | None = None
    wal_bytes_total: int | None = None
    steady_state_secs: int = 0                                 # duration of steady-state phase
    wal_samples: list[tuple[float, float, float]] = field(default_factory=list)  # (rel_s, fpi/s, wal MB/s)


def parse_pgbench_summary(run_dir: Path) -> float | None:
    summary = run_dir / "pgbench_summary.log"
    if not summary.exists():
        return None
    for line in summary.read_text().splitlines():
        # pgbench prints e.g.: "tps = 12345.67 (without initial connection time)"
        if line.lstrip().startswith("tps ="):
            try:
                return float(line.split("=")[1].split()[0])
            except (IndexError, ValueError):
                pass
    return None


_STEADY_STATE_LINE = re.compile(r"\[(\d{2}):(\d{2}):(\d{2})Z\] Steady-state:")
_CHECKPOINT_LINE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.\d+)? \w+ \[\d+\] LOG:\s+checkpoint (starting|complete):"
)


def _parse_steady_state_start(run_dir: Path) -> datetime | None:
    """Pull the absolute UTC datetime when the steady-state phase began.

    run.log carries the time-only `[HH:MM:SSZ]` marker; the date is the
    run-dir name prefix (e.g. `20260510T184754Z` → 2026-05-10). For the
    edge case where steady-state crosses midnight UTC, we still get the
    earlier date — that's fine, parse_checkpoints handles it by date.
    """
    run_log = run_dir / "run.log"
    if not run_log.exists():
        return None
    m_time = None
    for line in run_log.read_text().splitlines():
        if "Steady-state:" in line:
            m_time = _STEADY_STATE_LINE.search(line)
            if m_time:
                break
    if not m_time:
        return None
    h, mn, s = (int(g) for g in m_time.groups())
    # Date from run-dir name `YYYYMMDDTHHMMSSZ`.
    name = run_dir.name
    if len(name) < 8 or not name[:8].isdigit():
        return None
    return datetime(
        year=int(name[0:4]),
        month=int(name[4:6]),
        day=int(name[6:8]),
        hour=h, minute=mn, second=s,
        tzinfo=timezone.utc,
    )


def parse_checkpoints(run_dir: Path) -> list[tuple[float, str]]:
    """Extract checkpoint start/complete events as (rel_seconds_from_steady_state, kind).

    Events landing before steady-state start (i.e. during the warmup or
    pgbench -i) are filtered out — they aren't useful for the TPS-over-time
    plot which begins at t=0 = steady-state start.
    """
    server_log = _path_or_zst(run_dir / "postgresql.log.tail")
    if server_log is None:
        return []
    t0 = _parse_steady_state_start(run_dir)
    if t0 is None:
        return []
    events: list[tuple[float, str]] = []
    with open_text(server_log) as fh:
        for line in fh:
            m = _CHECKPOINT_LINE.match(line)
            if not m:
                continue
            date_s, time_s, kind = m.groups()
            try:
                dt = datetime.strptime(f"{date_s} {time_s}", "%Y-%m-%d %H:%M:%S").replace(
                    tzinfo=timezone.utc
                )
            except ValueError:
                continue
            rel = (dt - t0).total_seconds()
            if rel < 0:
                continue
            events.append((rel, kind))
    return events


def parse_wal_samples(run_dir: Path) -> list[tuple[float, float, float]]:
    """Parse pg_stat_wal_samples.tsv and compute per-interval rates.

    Returns a list of (rel_seconds_from_steady_state_start, fpi_per_s, wal_mb_per_s)
    tuples — one per sampling interval. Samples taken during the warmup
    have negative rel_seconds and are kept for context; the plot decides
    what range to show.

    Counters are cumulative since the Phase 2 Postgres restart, so the
    rate of any column = delta / interval. Empty list if the file is
    missing or has <2 samples.
    """
    f = _path_or_zst(run_dir / "pg_stat_wal_samples.tsv")
    if f is None:
        return []
    t0 = _parse_steady_state_start(run_dir)
    if t0 is None:
        return []
    t0_epoch = t0.timestamp()

    samples: list[tuple[float, int, int, int]] = []
    with open_text(f) as fh:
        next(fh, None)  # header
        for line in fh:
            parts = line.strip().split("\t")
            if len(parts) != 4:
                continue
            try:
                epoch = float(parts[0])
                wr = int(parts[1])
                fp = int(parts[2])
                wb = int(parts[3])
            except ValueError:
                continue
            samples.append((epoch, wr, fp, wb))

    if len(samples) < 2:
        return []

    rates: list[tuple[float, float, float]] = []
    for prev, cur in zip(samples, samples[1:]):
        dt = cur[0] - prev[0]
        if dt <= 0:
            continue
        fpi_per_s = (cur[2] - prev[2]) / dt
        wal_mb_per_s = (cur[3] - prev[3]) / dt / (1024 * 1024)
        # Plot the rate at the midpoint of the interval.
        mid_epoch = (prev[0] + cur[0]) / 2
        rates.append((mid_epoch - t0_epoch, fpi_per_s, wal_mb_per_s))
    return rates


def parse_pg_stat_wal(run_dir: Path) -> tuple[int | None, int | None, int | None]:
    """Return (wal_records, wal_fpi, wal_bytes) from the end-of-run pg_stat_wal.tsv."""
    f = run_dir / "pg_stat_wal.tsv"
    if not f.exists():
        return (None, None, None)
    try:
        lines = f.read_text().strip().splitlines()
        if len(lines) < 2:
            return (None, None, None)
        header = lines[0].split("\t")
        values = lines[1].split("\t")
        row = dict(zip(header, values))
        return (
            int(row.get("wal_records", 0)) or None,
            int(row.get("wal_fpi", 0)) or None,
            int(row.get("wal_bytes", 0)) or None,
        )
    except (ValueError, OSError):
        return (None, None, None)


# --- runsum cache --------------------------------------------------------
# A run's parsed RunData is ~50-100 KB serialized vs ~370 MB of raw pgbench
# logs that produced it (a ~4000× reduction). Caching the parsed form means
# subsequent plot regenerations (different cuts, different styling) don't
# need to re-pull or re-parse the raw logs.
#
# Schema version is embedded so older caches are rejected automatically if
# we ever change the shape.

_RUNSUM_VERSION = 1


def _runsum_path(run_dir: Path) -> Path:
    return run_dir / "runsum.json"


def _save_runsum(run: RunData) -> None:
    obj = {
        "version": _RUNSUM_VERSION,
        "scenario": run.scenario,
        "workload": run.workload,
        "summary_tps": run.summary_tps,
        "tps_series": [list(p) for p in run.tps_series],
        "checkpoints": [[t, k] for t, k in run.checkpoints],
        "wal_fpi_total": run.wal_fpi_total,
        "wal_records_total": run.wal_records_total,
        "wal_bytes_total": run.wal_bytes_total,
        "steady_state_secs": run.steady_state_secs,
        "wal_samples": [list(s) for s in run.wal_samples],
        # HdrHistogram serialized to compressed base64 bytes; decode back via
        # HdrHistogram.decode_and_add() into a fresh, equal-bounds histogram.
        "histogram_b64": run.histogram.encode().decode("ascii"),
    }
    _runsum_path(run.run_dir).write_text(json.dumps(obj))


def _load_runsum(scenario: str, workload: str, run_dir: Path) -> RunData | None:
    p = _runsum_path(run_dir)
    if not p.exists():
        return None
    try:
        obj = json.loads(p.read_text())
    except json.JSONDecodeError:
        return None
    if obj.get("version") != _RUNSUM_VERSION:
        return None
    hist = HdrHistogram(HDR_LOWEST, HDR_HIGHEST, HDR_SIGFIG)
    hist.decode_and_add(obj["histogram_b64"].encode("ascii"))
    return RunData(
        scenario=obj.get("scenario", scenario),
        workload=obj.get("workload", workload),
        run_dir=run_dir,
        histogram=hist,
        tps_series=[(int(t), int(v)) for t, v in obj["tps_series"]],
        summary_tps=obj.get("summary_tps"),
        checkpoints=[(float(t), str(k)) for t, k in obj.get("checkpoints", [])],
        wal_fpi_total=obj.get("wal_fpi_total"),
        wal_records_total=obj.get("wal_records_total"),
        wal_bytes_total=obj.get("wal_bytes_total"),
        steady_state_secs=int(obj.get("steady_state_secs", 0)),
        wal_samples=[
            (float(t), float(f), float(b)) for t, f, b in obj.get("wal_samples", [])
        ],
    )


def load_run(scenario: str, workload: str, run_dir: Path) -> RunData | None:
    # Fast path: cached parsed form. ~30 KB JSON read + base64 decode of the
    # histogram, vs decompressing + parsing hundreds of MB of pgbench logs.
    cached = _load_runsum(scenario, workload, run_dir)
    if cached is not None:
        return cached

    prefixes = discover_log_prefixes(run_dir)
    if not prefixes:
        print(f"  no logs in {run_dir}", file=sys.stderr)
        return None

    hist = HdrHistogram(HDR_LOWEST, HDR_HIGHEST, HDR_SIGFIG)
    counts: dict[int, int] = defaultdict(int)
    for prefix in prefixes:
        for rec in iter_logs(prefix):
            v = max(HDR_LOWEST, min(HDR_HIGHEST, rec.elapsed_us))
            hist.record_value(v)
            counts[rec.time_epoch] += 1

    if hist.get_total_count() == 0:
        return None

    t0 = min(counts)
    tps_series = sorted((t - t0, counts[t]) for t in counts)
    steady_state_secs = (max(counts) - t0) if counts else 0

    wal_records, wal_fpi, wal_bytes = parse_pg_stat_wal(run_dir)

    run = RunData(
        scenario=scenario,
        workload=workload,
        run_dir=run_dir,
        histogram=hist,
        tps_series=tps_series,
        summary_tps=parse_pgbench_summary(run_dir),
        checkpoints=parse_checkpoints(run_dir),
        wal_fpi_total=wal_fpi,
        wal_records_total=wal_records,
        wal_bytes_total=wal_bytes,
        steady_state_secs=steady_state_secs,
        wal_samples=parse_wal_samples(run_dir),
    )
    # Write the cache for next time. Best-effort; a write failure (e.g. r/o
    # mount during a regression test) shouldn't abort the analysis.
    try:
        _save_runsum(run)
    except OSError:
        pass
    return run


def find_runs(campaign_dir: Path) -> list[RunData]:
    runs: list[RunData] = []
    for scenario_dir in sorted(campaign_dir.iterdir()):
        if not scenario_dir.is_dir():
            continue
        scenario = scenario_dir.name
        for workload in WORKLOADS:
            wl_dir = scenario_dir / workload
            if not wl_dir.is_dir():
                continue
            # Pick the most-recent timestamped run.
            ts_dirs = sorted([d for d in wl_dir.iterdir() if d.is_dir()])
            if not ts_dirs:
                continue
            run = load_run(scenario, workload, ts_dirs[-1])
            if run:
                runs.append(run)
    return runs


def plot_tps_annotated(runs: list[RunData], workload: str, out: Path) -> None:
    """TPS-over-time annotated with checkpoint events and total FPI counts.

    The post-checkpoint FPI storm is the classic FPW=on signature: TPS
    drops at each `checkpoint starting:` event (red dashed vertical) and
    climbs back as the FPI rate decays through the cycle (because pages
    don't need a fresh full-page image after their first mod since the
    last RedoRecPtr). For FPW=off scenarios there are no FPIs and the
    chain-saw shape flattens.

    One subplot per scenario so checkpoint markers stay readable when the
    campaign grows — overlaying 6+ scenarios on a single axis with
    annotations would be unreadable.
    """
    relevant = [r for r in runs if r.workload == workload]
    relevant.sort(
        key=lambda r: SCENARIO_ORDER.index(r.scenario)
        if r.scenario in SCENARIO_ORDER
        else 999
    )
    if not relevant:
        return

    n = len(relevant)
    # Per-subplot height = 4 in (curve area) + the annotation strip below.
    fig, axes = plt.subplots(n, 1, figsize=(12, 4.0 * n), sharex=True, squeeze=False)

    have_wal_samples = False
    for i, run in enumerate(relevant):
        ax = axes[i][0]
        if run.tps_series:
            xs = [t for t, _ in run.tps_series]
            ys = [tps for _, tps in run.tps_series]
            ax.plot(xs, ys, color="tab:blue", linewidth=1, label="TPS", zorder=3)

        # Checkpoint markers: red dashed for starting, green dotted for complete.
        starts = [t for t, kind in run.checkpoints if kind == "starting"]
        completes = [t for t, kind in run.checkpoints if kind == "complete"]
        for t in starts:
            ax.axvline(t, color="tab:red", linestyle="--", linewidth=1, alpha=0.7, zorder=1)
        for t in completes:
            ax.axvline(t, color="tab:green", linestyle=":", linewidth=1, alpha=0.7, zorder=1)

        # FPI rate overlay on a secondary y-axis (only if the run has samples).
        # This is the smoking-gun for the FPI-storm hypothesis: when FPW=on
        # the rate spikes at checkpoint start and decays through the cycle.
        if run.wal_samples:
            have_wal_samples = True
            ax2 = ax.twinx()
            xs = [t for t, _, _ in run.wal_samples if t >= -60]  # include last min of warmup
            fpi = [f for t, f, _ in run.wal_samples if t >= -60]
            ax2.plot(xs, fpi, color="tab:orange", linewidth=1, alpha=0.8,
                     label="FPI/s", zorder=2)
            ax2.set_ylabel("FPI / s", color="tab:orange")
            ax2.tick_params(axis="y", labelcolor="tab:orange")
            ax2.set_ylim(bottom=0)

        # Per-panel annotation summarizing the run.
        annotations: list[str] = []
        if run.wal_fpi_total is not None and run.steady_state_secs > 0:
            fpi_per_s = run.wal_fpi_total / run.steady_state_secs
            annotations.append(
                f"FPI total: {run.wal_fpi_total:,} ({fpi_per_s:,.0f}/s avg)"
            )
        if run.wal_bytes_total is not None and run.steady_state_secs > 0:
            mb_per_s = run.wal_bytes_total / run.steady_state_secs / (1024 * 1024)
            annotations.append(f"WAL: {run.wal_bytes_total / 1e9:.1f} GB ({mb_per_s:,.0f} MB/s)")
        annotations.append(f"{len(starts)} ckpt starts")
        if run.summary_tps is not None:
            annotations.append(f"avg TPS {run.summary_tps:,.0f}")

        # Annotation goes BELOW the subplot (not overlapping the curve).
        # Negative y in axes coords + clip_on=False puts it just under
        # the x-axis tick labels; matched up with subplot_adjust(hspace).
        ax.text(
            0.5, -0.25,
            "  •  ".join(annotations),
            transform=ax.transAxes,
            ha="center", va="top", fontsize=9,
            bbox={"boxstyle": "round,pad=0.4", "facecolor": "#f4f4f4", "edgecolor": "#bbb"},
            clip_on=False,
        )

        ax.set_ylabel("TPS", color="tab:blue")
        ax.tick_params(axis="y", labelcolor="tab:blue")
        ax.set_title(f"{run.scenario}  —  {workload}", loc="left", fontsize=10)
        ax.grid(True, alpha=0.3)

    # Legend on the first subplot only.
    handles = [
        plt.Line2D([0], [0], color="tab:blue", label="TPS"),
        plt.Line2D([0], [0], color="tab:red", linestyle="--", label="checkpoint starting"),
        plt.Line2D([0], [0], color="tab:green", linestyle=":", label="checkpoint complete"),
    ]
    if have_wal_samples:
        handles.insert(1, plt.Line2D([0], [0], color="tab:orange", label="FPI / s"))
    axes[0][0].legend(handles=handles, loc="lower right", fontsize=8)
    axes[-1][0].set_xlabel("Elapsed seconds (relative to steady-state start)")

    fig.suptitle(f"TPS with checkpoint markers — {workload}", fontsize=12)
    # tight_layout doesn't know about our off-axis annotation; reserve
    # vertical room manually so the annotation strip doesn't get clipped
    # and adjacent subplots don't collide with each other's annotations.
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.subplots_adjust(hspace=0.55)
    fig.savefig(out, dpi=120, bbox_inches="tight")
    plt.close(fig)


def plot_tps(runs: list[RunData], workload: str, out: Path) -> None:
    fig, ax = plt.subplots(figsize=(12, 6))
    plotted = False
    for run in (r for r in runs if r.workload == workload):
        if not run.tps_series:
            continue
        xs = [t for t, _ in run.tps_series]
        ys = [tps for _, tps in run.tps_series]
        ax.plot(xs, ys, label=run.scenario, linewidth=1)
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed seconds")
    ax.set_ylabel("Transactions per second")
    ax.set_title(f"TPS over time — {workload}")
    ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0)
    ax.legend(loc="best")
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def _format_latency(us: float) -> str:
    """Render a microsecond latency as the most readable unit."""
    if us < 1000:
        return f"{us:.0f}µs"
    if us < 1_000_000:
        return f"{us / 1000:.1f}ms"
    return f"{us / 1_000_000:.2f}s"


def plot_latency_bars(runs: list[RunData], workload: str, out: Path) -> None:
    """Grouped bar chart at the canonical percentiles (p50, p90, p95, p99, p99.9, p99.99).

    Y-axis is log-scaled because p99.99 can be 10-100× p50 — linear would
    crush the lower percentiles to invisibility. Each bar is labelled with
    its exact value (auto-unit µs / ms / s) for at-a-glance reading.
    """
    relevant = [r for r in runs if r.workload == workload]
    relevant.sort(
        key=lambda r: SCENARIO_ORDER.index(r.scenario)
        if r.scenario in SCENARIO_ORDER
        else 999
    )
    if not relevant:
        return

    n_scenarios = len(relevant)
    n_pcts = len(BAR_PERCENTILES)
    x = np.arange(n_pcts)
    bar_width = 0.8 / max(n_scenarios, 1)

    fig, ax = plt.subplots(figsize=(12, 7))

    for i, run in enumerate(relevant):
        values = [
            float(run.histogram.get_value_at_percentile(p))
            for p in BAR_PERCENTILES
        ]
        positions = x + (i - (n_scenarios - 1) / 2) * bar_width
        bars = ax.bar(positions, values, bar_width, label=run.scenario)
        for bar, val in zip(bars, values):
            ax.annotate(
                _format_latency(val),
                xy=(bar.get_x() + bar.get_width() / 2, val),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=8,
            )

    ax.set_xticks(x)
    ax.set_xticklabels([f"p{p:g}" for p in BAR_PERCENTILES])
    ax.set_ylabel("Latency (µs, log scale)")
    ax.set_yscale("log")
    ax.set_title(f"Latency percentiles — {workload}")
    ax.legend(loc="best")
    ax.grid(True, axis="y", which="both", alpha=0.3)
    # Generous top margin so annotations don't clip.
    ymin, ymax = ax.get_ylim()
    ax.set_ylim(ymin, ymax * 1.6)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def plot_latency(runs: list[RunData], workload: str, out: Path) -> None:
    fig, ax = plt.subplots(figsize=(12, 7))
    plotted = False
    for run in (r for r in runs if r.workload == workload):
        xs, ys = percentile_curve(run.histogram)
        x_log = 1.0 / (1.0 - xs / 100.0)
        ax.plot(x_log, ys, label=run.scenario, linewidth=1.5)
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Percentile (log scale: 10 = p90, 100 = p99, 1000 = p99.9)")
    ax.set_ylabel("Latency (µs, log scale)")
    ax.set_title(f"Latency percentiles — {workload}")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best")
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def write_summary(runs: list[RunData], workload: str, out_csv: Path, out_md: Path) -> None:
    rows = []
    relevant = [r for r in runs if r.workload == workload]
    relevant.sort(
        key=lambda r: SCENARIO_ORDER.index(r.scenario)
        if r.scenario in SCENARIO_ORDER
        else 999
    )
    for r in relevant:
        h = r.histogram
        row = {
            "scenario": r.scenario,
            "workload": r.workload,
            "samples": h.get_total_count(),
            "tps_summary": f"{r.summary_tps:.2f}" if r.summary_tps else "",
            "min_us": h.get_min_value(),
            "mean_us": int(h.get_mean_value()),
            **{f"p{p:g}_us": h.get_value_at_percentile(p) for p in PERCENTILES},
            "max_us": h.get_max_value(),
        }
        rows.append(row)

    if not rows:
        return

    with out_csv.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    with out_md.open("w") as fh:
        fh.write(f"# Summary — workload `{workload}`\n\n\n")
        cols = list(rows[0].keys())
        fh.write("| " + " | ".join(cols) + " |\n")
        fh.write("| " + " | ".join(["---"] * len(cols)) + " |\n")
        for row in rows:
            fh.write("| " + " | ".join(str(row[c]) for c in cols) + " |\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("campaign_dir", type=Path)
    p.add_argument("--out-dir", type=Path, default=None)
    args = p.parse_args()

    out_dir = args.out_dir or args.campaign_dir
    out_dir.mkdir(exist_ok=True, parents=True)

    runs = find_runs(args.campaign_dir)
    if not runs:
        print(f"ERROR: no runs found under {args.campaign_dir}", file=sys.stderr)
        return 1

    for workload in WORKLOADS:
        if not any(r.workload == workload for r in runs):
            continue
        plot_tps(runs, workload, out_dir / f"tps_{workload}.png")
        # Per-scenario TPS with checkpoint markers + FPI/WAL annotations —
        # this is the chart that tells the FPW story directly.
        plot_tps_annotated(runs, workload, out_dir / f"tps_annotated_{workload}.png")
        # Headline latency view — bars at p50/p90/p95/p99/p99.9/p99.99.
        plot_latency_bars(runs, workload, out_dir / f"latency_{workload}.png")
        # Technical view — canonical HdrHistogram percentile-over-percentile curve.
        plot_latency(runs, workload, out_dir / f"latency_curve_{workload}.png")
        write_summary(
            runs,
            workload,
            out_dir / f"summary_{workload}.csv",
            out_dir / f"summary_{workload}.md",
        )

    print(f"wrote artifacts to {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

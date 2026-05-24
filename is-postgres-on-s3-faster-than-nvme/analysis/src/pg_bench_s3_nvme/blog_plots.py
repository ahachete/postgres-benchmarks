"""Blog-post-shaped plots.

Generates a curated set of comparison plots organized around the three
narrative dimensions used in the post:

  1. ext4 vs ZFS (FPW=off)
  2. ZFS FPW on vs off
  3. single-node vs 3-AZ HA  (per filesystem)

Plus a checkpoint-focus side panel:

  2. checkpoint effect on TPS — one panel per filesystem, with checkpoint
     start→complete bands shaded and (only on ext4) the FPI/sec rate on a
     secondary y-axis. ZFS panels omit the FPI axis entirely (it's 0).

All plots use the existing `compare_scenarios.RunData` and helper
functions for parsing pgbench logs + checkpoints + pg_stat_wal samples.
TPS-over-time and latency-bar plots reuse `plot_tps()` and
`plot_latency_bars()` unchanged so style stays consistent across the
post.

Input layout (campaign root):
    <root>/phase1/<scenario>/<workload>/<ts>/...
    <root>/phase2/<scenario>/<workload>/<ts>/...

Output layout:
    <out>/d1-ext4-vs-zfs/{tps,latency}_{tpcb,mixed}.png
    <out>/d2-checkpoint/tps_{ext4,zfs}_{tpcb,mixed}.png
    <out>/d3-zfs-fpw/{tps,latency}_{tpcb,mixed}.png
    <out>/d4-single-vs-ha/{tps,latency}_{ext4,zfs}_{tpcb,mixed}.png
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt

from .compare_scenarios import (
    RunData,
    find_runs,
    plot_latency_bars,
    plot_tps,
)


# Scenario names used throughout. The campaign data uses these literals.
SCEN_EXT4 = "nvme-ext4"
SCEN_ZFS_FPWOFF = "nvme-zfs"
SCEN_ZFS_FPWON = "nvme-zfs-fpi"


@dataclass
class TaggedRun:
    phase: str  # "phase1" (single-node) or "phase2" (3-AZ HA)
    run: RunData


def find_runs_tagged(campaign_root: Path) -> list[TaggedRun]:
    """Walks campaign_root/phase{1,2}/ and returns each run with its phase tag."""
    out: list[TaggedRun] = []
    for phase_dir in sorted(campaign_root.glob("phase*")):
        if not phase_dir.is_dir():
            continue
        for run in find_runs(phase_dir):
            out.append(TaggedRun(phase=phase_dir.name, run=run))
    return out


def filter_runs(
    tagged: list[TaggedRun],
    *,
    scenarios: set[str] | None = None,
    phases: set[str] | None = None,
) -> list[RunData]:
    """Pick runs matching the given scenario / phase filters."""
    out: list[RunData] = []
    for tr in tagged:
        if scenarios is not None and tr.run.scenario not in scenarios:
            continue
        if phases is not None and tr.phase not in phases:
            continue
        out.append(tr.run)
    return out


def relabel(run: RunData, new_scenario: str) -> RunData:
    """Return a shallow copy of `run` with a new `scenario` label.

    Used so that single-node vs HA comparisons of the SAME scenario show
    up in plot legends as e.g. "single-node" / "3-AZ HA" instead of both
    just being "nvme-ext4".
    """
    r = copy.copy(run)
    r.scenario = new_scenario
    return r


# ---------------------------------------------------------------------------
# Custom plot: TPS-over-time with checkpoint bands + optional FPI overlay.
# ---------------------------------------------------------------------------

def plot_tps_with_checkpoint_bands(
    run: RunData,
    out: Path,
    *,
    show_fpi: bool,
    title: str | None = None,
) -> None:
    """Single-scenario TPS line + shaded checkpoint bands (start→complete).

    Differs from the campaign-wide `plot_tps_annotated`:
      - One scenario per chart (not stacked).
      - Checkpoint events drawn as vertical SHADED BANDS spanning start to
        complete, not just lines — shows checkpoint duration too.
      - FPI/sec overlay is opt-in (`show_fpi=True`). On FPW=off scenarios,
        passing show_fpi=False hides the secondary axis entirely (instead
        of drawing a flat-zero line + axis label).
    """
    fig, ax = plt.subplots(figsize=(12, 5))

    if not run.tps_series:
        plt.close(fig)
        return

    # TPS line.
    xs = [t for t, _ in run.tps_series]
    ys = [tps for _, tps in run.tps_series]
    ax.plot(xs, ys, color="tab:blue", linewidth=1.2, label="TPS", zorder=3)

    # Checkpoint bands. Pair up consecutive "starting"/"complete" events.
    # The captured log can be out-of-order when checkpointer is busy, so
    # we sort and pair by appearance — for each "starting" find the next
    # "complete" after it. Bands are translucent so the TPS line stays
    # readable through them.
    events_sorted = sorted(run.checkpoints, key=lambda x: x[0])
    pending_starts: list[float] = []
    bands: list[tuple[float, float]] = []
    for t, kind in events_sorted:
        if kind == "starting":
            pending_starts.append(t)
        elif kind == "complete" and pending_starts:
            bands.append((pending_starts.pop(0), t))
    # Any unmatched starts (checkpoint still running at end of capture) get
    # drawn as a band from start to the last TPS sample — same visual treatment
    # as a completed checkpoint, since the checkpoint was still active.
    run_end = xs[-1] if xs else 0.0
    for t in pending_starts:
        if run_end > t:
            bands.append((t, run_end))

    for s, e in bands:
        ax.axvspan(s, e, color="tab:red", alpha=0.12, zorder=1)

    # FPI/sec overlay (opt-in, only meaningful when FPW=on).
    if show_fpi and run.wal_samples:
        ax2 = ax.twinx()
        wxs = [t for t, _, _ in run.wal_samples if t >= 0]
        fpi = [f for t, f, _ in run.wal_samples if t >= 0]
        ax2.plot(wxs, fpi, color="tab:orange", linewidth=1.2,
                 alpha=0.85, label="FPI / s", zorder=2)
        ax2.set_ylabel("FPI / s", color="tab:orange")
        ax2.tick_params(axis="y", labelcolor="tab:orange")
        ax2.set_ylim(bottom=0)

    ax.set_xlabel("Elapsed seconds (relative to steady-state start)")
    ax.set_ylabel("Transactions per second", color="tab:blue")
    ax.tick_params(axis="y", labelcolor="tab:blue")
    ax.set_title(title or f"{run.scenario} — {run.workload}")
    ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0)

    # Custom legend so the checkpoint band is described correctly.
    handles = [
        plt.Line2D([0], [0], color="tab:blue", label="TPS"),
        plt.Rectangle((0, 0), 1, 1, color="tab:red", alpha=0.12,
                      label="checkpoint (start → complete)"),
    ]
    if show_fpi and run.wal_samples:
        handles.append(plt.Line2D([0], [0], color="tab:orange", label="FPI / s"))
    ax.legend(handles=handles, loc="best", fontsize=9)

    fig.tight_layout()
    fig.savefig(out, dpi=120, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Per-dimension drivers.
# ---------------------------------------------------------------------------

def render_d1_ext4_vs_zfs(tagged: list[TaggedRun], out_dir: Path) -> None:
    """Dimension 1: single-node, ext4 vs ZFS (both FPW-safe defaults)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    runs = filter_runs(
        tagged,
        scenarios={SCEN_EXT4, SCEN_ZFS_FPWOFF},
        phases={"phase1"},
    )
    for wl in ("tpcb", "mixed"):
        plot_tps(runs, wl, out_dir / f"tps_{wl}.png")
        plot_latency_bars(runs, wl, out_dir / f"latency_{wl}.png")


def render_d2_checkpoint(tagged: list[TaggedRun], out_dir: Path) -> None:
    """Dimension 2: checkpoint impact on TPS, per filesystem.

    For ext4 (FPW=on): overlay FPI/s on secondary y-axis. The FPI rate
    spikes at each checkpoint start and decays through the cycle — the
    smoking gun for the post-checkpoint chain-saw.
    For ZFS (FPW=off): hide the FPI axis (it's identically zero).
    Both workloads.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    for fs_label, scen, show_fpi in [
        ("ext4", SCEN_EXT4, True),
        ("zfs",  SCEN_ZFS_FPWOFF, False),
    ]:
        scen_runs = filter_runs(tagged, scenarios={scen}, phases={"phase1"})
        for wl in ("tpcb", "mixed"):
            wl_run = next((r for r in scen_runs if r.workload == wl), None)
            if wl_run is None:
                continue
            plot_tps_with_checkpoint_bands(
                wl_run,
                out_dir / f"tps_{fs_label}_{wl}.png",
                show_fpi=show_fpi,
                title=f"{fs_label} — {wl} (checkpoint effect on TPS)",
            )


def render_d3_zfs_fpw(tagged: list[TaggedRun], out_dir: Path) -> None:
    """Dimension 3: ZFS FPW on vs off, single-node."""
    out_dir.mkdir(parents=True, exist_ok=True)
    runs = filter_runs(
        tagged,
        scenarios={SCEN_ZFS_FPWOFF, SCEN_ZFS_FPWON},
        phases={"phase1"},
    )
    for wl in ("tpcb", "mixed"):
        plot_tps(runs, wl, out_dir / f"tps_{wl}.png")
        plot_latency_bars(runs, wl, out_dir / f"latency_{wl}.png")


def render_d4_single_vs_ha(tagged: list[TaggedRun], out_dir: Path) -> None:
    """Dimension 4: single-node vs HA, per filesystem.

    For each FS we relabel the two runs ("single-node" / "3-AZ HA") so
    the existing plot_tps and plot_latency_bars legends are
    self-explanatory.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    for fs_label, scen in [
        ("ext4", SCEN_EXT4),
        ("zfs",  SCEN_ZFS_FPWOFF),
    ]:
        single = filter_runs(tagged, scenarios={scen}, phases={"phase1"})
        ha     = filter_runs(tagged, scenarios={scen}, phases={"phase2"})
        for wl in ("tpcb", "mixed"):
            single_wl = next((r for r in single if r.workload == wl), None)
            ha_wl     = next((r for r in ha     if r.workload == wl), None)
            if single_wl is None or ha_wl is None:
                continue
            pair = [
                relabel(single_wl, "single-node"),
                relabel(ha_wl,     "3-AZ HA"),
            ]
            plot_tps(pair, wl, out_dir / f"tps_{fs_label}_{wl}.png")
            plot_latency_bars(pair, wl, out_dir / f"latency_{fs_label}_{wl}.png")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render blog-post plots.")
    parser.add_argument(
        "campaign_root",
        type=Path,
        help="Campaign root with phase1/ and phase2/ subdirectories.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output directory (default: <campaign_root>/blog/).",
    )
    args = parser.parse_args()

    out_root = args.out or (args.campaign_root / "blog")
    out_root.mkdir(parents=True, exist_ok=True)

    print(f"==> Loading runs from {args.campaign_root}")
    tagged = find_runs_tagged(args.campaign_root)
    if not tagged:
        print("✗ No runs found.")
        return 1
    by_phase = {p: 0 for p in {tr.phase for tr in tagged}}
    for tr in tagged:
        by_phase[tr.phase] += 1
    for p, n in sorted(by_phase.items()):
        print(f"    {p}: {n} runs")

    print(f"==> Rendering plots into {out_root}/")
    render_d1_ext4_vs_zfs(tagged, out_root / "d1-ext4-vs-zfs")
    render_d2_checkpoint  (tagged, out_root / "d2-checkpoint")
    render_d3_zfs_fpw     (tagged, out_root / "d3-zfs-fpw")
    render_d4_single_vs_ha(tagged, out_root / "d4-single-vs-ha")

    print("==> Done. Files:")
    for f in sorted(out_root.rglob("*.png")):
        print(f"    {f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

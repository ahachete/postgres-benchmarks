"""Parsing utilities for `pgbench --log` per-transaction logs.

pgbench writes one line per completed transaction in the form:

    client_id transaction_no time script_no time_epoch time_us [schedule_lag_us]

where:
- `time` is the elapsed time of the transaction in microseconds
- `time_epoch` is the Unix timestamp (seconds) at which the transaction completed
- `time_us` is the fractional-second portion of `time_epoch` in microseconds
- `schedule_lag_us` only appears when `--rate` is used (it isn't here)

When `--log-prefix=PFX` is given, pgbench writes one file per worker:
PFX.<pid> for single-thread, PFX.<pid>.<thread_id> for multi-thread.
This module aggregates them, transparently handling `.zst`-compressed
files (run.sh compresses pgbench logs > 100 KB before S3 upload).
"""
from __future__ import annotations

import io
import subprocess
from contextlib import contextmanager
from dataclasses import dataclass
from glob import glob
from pathlib import Path
from typing import Iterable, Iterator


@dataclass(frozen=True, slots=True)
class TxnRecord:
    client_id: int
    transaction_no: int
    elapsed_us: int
    script_no: int
    time_epoch: int
    time_us: int

    @property
    def completion_time(self) -> float:
        return self.time_epoch + self.time_us / 1_000_000.0


@contextmanager
def open_text(path: Path):
    """Open a text file, transparently decompressing `.zst` via the `zstd`
    CLI. Avoids a hard Python dep on `zstandard`; `zstd` is already in
    the project's shell.nix and the bake-time apt list.
    """
    if str(path).endswith(".zst"):
        proc = subprocess.Popen(
            ["zstd", "-dc", "--", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        text = io.TextIOWrapper(proc.stdout, encoding="utf-8", errors="replace")
        try:
            yield text
        finally:
            text.close()
            proc.wait()
    else:
        with path.open("r") as fh:
            yield fh


def _strip_zst(name: str) -> str:
    return name[:-4] if name.endswith(".zst") else name


def iter_log_file(path: Path) -> Iterator[TxnRecord]:
    with open_text(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 6:
                continue
            try:
                yield TxnRecord(
                    client_id=int(parts[0]),
                    transaction_no=int(parts[1]),
                    elapsed_us=int(parts[2]),
                    script_no=int(parts[3]),
                    time_epoch=int(parts[4]),
                    time_us=int(parts[5]),
                )
            except ValueError:
                continue


def iter_logs(prefix: str | Path) -> Iterator[TxnRecord]:
    """Yield TxnRecords from every pgbench log file matching `prefix.*`.

    The `prefix` may include directory components. We glob `<prefix>*` and
    skip non-log files (e.g. `prefix_summary.log`) by checking the suffix
    is purely numeric (worker pid / thread id). `.zst`-compressed worker
    logs are picked up too — we strip `.zst` before the digit check.
    """
    prefix_str = str(prefix)
    for fname in sorted(glob(prefix_str + "*")):
        path = Path(fname)
        # Suffix relative to the prefix, with optional .zst stripped before
        # the digit check (the file itself is opened as-is and decompressed
        # transparently by open_text).
        rel = path.name[len(Path(prefix_str).name):].lstrip(".")
        rel = _strip_zst(rel)
        suffix_parts = rel.split(".")
        if not suffix_parts or not all(p.isdigit() for p in suffix_parts if p):
            continue
        yield from iter_log_file(path)


def discover_log_prefixes(run_dir: Path) -> list[Path]:
    """Find all pgbench log prefixes in a run directory.

    Each prefix corresponds to one pgbench invocation. With our run.sh,
    there's a single steady-state prefix `<run_dir>/pgbench`. Handles
    both raw and `.zst`-compressed worker files.
    """
    prefixes: list[Path] = []
    seen: set[str] = set()
    for fname in sorted(run_dir.glob("pgbench*")):
        # Strip .zst before the structural check; the prefix doesn't include
        # the compression suffix.
        name = _strip_zst(fname.name)
        parts = name.split(".")
        if len(parts) < 2 or not parts[-1].isdigit():
            continue
        # Walk back while parts are all digits (handles .pid.thread).
        stem_end = len(parts) - 1
        while stem_end > 0 and parts[stem_end].isdigit():
            stem_end -= 1
        prefix_str = ".".join(parts[: stem_end + 1])
        full = run_dir / prefix_str
        if str(full) not in seen:
            seen.add(str(full))
            prefixes.append(full)
    return prefixes


def collect_elapsed_us(prefix: str | Path) -> Iterable[int]:
    for rec in iter_logs(prefix):
        yield rec.elapsed_us

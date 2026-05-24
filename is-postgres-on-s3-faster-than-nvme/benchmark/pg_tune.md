# Postgres tuning rationale



## Run-time methodology

Each `make bench` invocation goes through **three phases**, orchestrated by `scripts/bench-run.sh` so the measurement phase starts from a completely cold, deterministic state:

**Phase 1 — Pristine dataset load.**
1. `sync && echo 3 > /proc/sys/vm/drop_caches` (Linux page cache, dentries, inodes).
2. `pgbench -i -s 15000 --no-vacuum --foreign-keys` — drops + recreates + bulk-loads the tables.
3. For `mixed`: `init_mixed.sql` (creates `bench_inserts`).
4. `VACUUM (ANALYZE)` on every pgbench table + `CHECKPOINT`.

**Phase 2 — Cold restart.**
5. `systemctl stop postgresql@18-main` — flushes `shared_buffers`.
6. `sync && echo 3 > /proc/sys/vm/drop_caches` — flushes Linux caches again (Phase 1 repopulated them).
7. `systemctl start postgresql@18-main` + `pg_isready` poll until it accepts connections.

After phase 2, both `shared_buffers` and the OS page cache are **empty** with a freshly-loaded dataset on disk. This is the cold-start state every workload begins from.

**Phase 3 — Measurement.**
8. `pg_stat_reset()` + `pg_stat_statements_reset()` (defensive; the restart already zeroed them).
9. Start background collectors (`iostat`, `vmstat`, `zpool iostat` where applicable).
10. **5-minute warmup** (`-T 300`) — results discarded — driving SB and OS PC to the workload-appropriate state via the workload's own access pattern.
11. `pg_stat_reset()` again, so the captured `pg_stat_*` snapshots reflect only the steady-state interval.
12. **30-minute steady-state** (`-T 1800`) with `--log` per-transaction timings.
13. Capture `pg_stat_io / pg_stat_wal / pg_stat_bgwriter / pg_stat_statements`, server-log tail, rendered `postgresql.conf`, `scenario.json`.
14. **Zstd-compress** large text artifacts (pgbench `--log` worker files, iostat, vmstat, server-log tail; files > 100 KB only). Each ~95 MB pgbench worker log shrinks 4-6× — total run dir goes from ~1.6 GB → ~300-400 MB.
15. Upload everything (compressed where applicable) to `s3://<results-bucket>/results/<scenario>/<workload>/<ts>/`. `bench-fetch.sh` decompresses on the operator side before the analysis stage.

Cross-workload contamination is impossible: each run sees an identical dataset on disk and an identical cold-cache start. The only difference between two `make bench` invocations on the same scenario is the workload script.






All values in [`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml) and
[`ansible/roles/postgres/templates/postgresql.conf.j2`](../ansible/roles/postgres/templates/postgresql.conf.j2)
are justified here. Anything that varies per scenario is in the `scenario_tuning`
map keyed by scenario name; anything constant lives at the top level.



## Memory (constant across scenarios)

| GUC | Value | Why |
|---|---|---|
| [`shared_buffers`](https://postgresqlco.nf/doc/en/param/shared_buffers/) | `32GB` (25% of 128 GB RAM) | The standard rule of thumb. Going higher hurts on Linux because the OS page cache can no longer help and double-buffering becomes a memory waste. |
| [`effective_cache_size`](https://postgresqlco.nf/doc/en/param/effective_cache_size/) | `96GB` (75% of RAM) | Planner hint: how much data we expect to be cached (shared_buffers + page cache). Affects index plan choices. |
| [`work_mem`](https://postgresqlco.nf/doc/en/param/work_mem/) | `32MB` | Conservative: pgbench rarely needs sorts > a few MB; higher values risk OOM with 64 concurrent clients. |
| [`maintenance_work_mem`](https://postgresqlco.nf/doc/en/param/maintenance_work_mem/) | `2GB` | Speeds up vacuum on the ~225 GB dataset. |
| [`huge_pages`](https://postgresqlco.nf/doc/en/param/huge_pages/) | `on` | Strict — Postgres refuses to start if the kernel hugepage pool is undersized. The `common` role reserves 2 MiB pages for `shared_buffers + 6%` via `vm.nr_hugepages`. At this RAM size hugepages give a meaningful TLB-miss reduction; `try` would silently fall back to 4K pages on memory pressure, which is the wrong failure mode for a benchmark. |



## WAL & checkpoints (constant across scenarios)

| GUC | Value | Why |
|---|---|---|
| [`wal_level`](https://postgresqlco.nf/doc/en/param/wal_level/) | `logical` | Production-realistic — most real Postgres deployments leave room for logical replication / CDC tooling. Adds a small (~2-3%) WAL-volume overhead vs `replica`, but represents what a real operator would set. |
| [`wal_buffers`](https://postgresqlco.nf/doc/en/param/wal_buffers/) | `128MB` | Default of 16 MB is the well-known bottleneck for high-concurrency write workloads. 128 MB removes WAL-buffer-full stalls without measurable downside. |
| [`wal_compression`](https://postgresqlco.nf/doc/en/param/wal_compression/) | `on` | Production default — compresses full-page-images in WAL records. Reduces WAL volume meaningfully on FPW=on scenarios. The FPW on/off difference is still visible (FPW=off skips FPIs entirely); compression only changes the absolute magnitude. |
| [`max_wal_size`](https://postgresqlco.nf/doc/en/param/max_wal_size/) | `96GB` | Sized so 30-min steady-state at full write load (~187 MB/s WAL) hits `checkpoint_timeout`, not size-triggered checkpoints. The original `16GB` setting caused a checkpoint storm (38 checkpoints in 27 min, mostly size-triggered mid-write of the previous one) which masked the post-checkpoint write-cliff signal. 96 GB × 1 cycle / 67 GB-per-6min-at-187MB/s gives ~40% margin. |
| [`checkpoint_timeout`](https://postgresqlco.nf/doc/en/param/checkpoint_timeout/) | `6min` | A 30-min steady-state gives 5 full cycles — enough to see the post-checkpoint write cliff repeatedly in TPS-over-time plots. |
| [`checkpoint_completion_target`](https://postgresqlco.nf/doc/en/param/checkpoint_completion_target/) | `0.9` | Standard. Spreads checkpoint writes over 90% of the interval. |
| [`synchronous_commit`](https://postgresqlco.nf/doc/en/param/synchronous_commit/) | `on` | We are explicitly testing durable Postgres; `off` would make the comparison meaningless. |



## Per-scenario overrides

| GUC | nvme-ext4 | nvme-zfs |
|---|---|---|
| [`full_page_writes`](https://postgresqlco.nf/doc/en/param/full_page_writes/) | `on` | `off` |
| [`random_page_cost`](https://postgresqlco.nf/doc/en/param/random_page_cost/) | `1.1` | `1.1` |
| [`effective_io_concurrency`](https://postgresqlco.nf/doc/en/param/effective_io_concurrency/) | `200` | `200` |

### `full_page_writes`
On ZFS, when `recordsize` is greater than or equal to Postgres's page size
(8K by default), every Postgres page write fits within a single ZFS record
and is atomic at the device level (copy-on-write — either the new pointer
is committed via uberblock swap, or the old one stands; the page can never
be half-written). Postgres' torn-page guard via FPW becomes redundant. On ext4 the underlying
NVMe sector size (typically 4 KB) is smaller than Postgres' 8 KB page, so
half-writes are possible after a crash; FPW must stay on.

Disabling FPW roughly halves WAL volume on write-heavy workloads. This is one
of the headline numbers in the blog post.

### `random_page_cost`
S3-via-NBD has much higher variance and tail latency than local NVMe; the
planner should bias toward sequential plans (sequential reads benefit more
from ZeroFS's block-level prefetching). 4.0 is the historical "spinning rust"
default and a reasonable proxy.

### `effective_io_concurrency`
ZeroFS upstream documents 64 as a working point. Local NVMe can fan out
much wider — 200 is the value most pg-tuning guides use for direct-attached
SSDs and matches our testing.



## Background writer

| GUC | Value | Why |
|---|---|---|
| [`bgwriter_delay`](https://postgresqlco.nf/doc/en/param/bgwriter_delay/) | `50ms` | Default 200ms is too lazy for `shared_buffers=32GB` under heavy writes — dirty pages accumulate, then the checkpoint has too much to flush at once and creates a write cliff. 4× more frequent passes keeps the dirty-page pool small. |
| [`bgwriter_lru_maxpages`](https://postgresqlco.nf/doc/en/param/bgwriter_lru_maxpages/) | `8000` | Up from the default 100. At 50ms cadence this is ~1.28 GB/s of bgwriter throughput. First-pass tuning had 4000 here, but a real run hit `maxwritten_clean=3988/4000` — bgwriter was pinned at the cap. 8000 gives headroom so dirty pages drain between checkpoints instead of dumping on the checkpointer. |
| [`bgwriter_lru_multiplier`](https://postgresqlco.nf/doc/en/param/bgwriter_lru_multiplier/) | `10.0` | Aggressive lookahead — write 10× the recent allocation rate, so the writer is always ahead of demand. |
| [`bgwriter_flush_after`](https://postgresqlco.nf/doc/en/param/bgwriter_flush_after/) | `512kB` | Trigger writeback every 512 KB of bgwriter writes so the kernel flushes dirty pages to the device promptly rather than letting them pile up in the OS cache. |



## Replication (cluster phase only)

| GUC | Value | Why |
|---|---|---|
| [`synchronous_standby_names`](https://postgresqlco.nf/doc/en/param/synchronous_standby_names/) | `'ANY 1 (replica1, replica2)'` | Quorum sync of size 1: at least one peer has the WAL on durable storage at COMMIT, while one slow/down replica doesn't stall the primary. |
| [`commit_delay`](https://postgresqlco.nf/doc/en/param/commit_delay/) / [`commit_siblings`](https://postgresqlco.nf/doc/en/param/commit_siblings/) | defaults (`0` / `5`) | Deliberately *not* tuned. Setting `commit_delay > 0` adds latency to every commit by design — exactly the metric this benchmark exists to measure. Group-commit batching is a tail-throughput optimization that distorts the latency distribution we want to compare. |

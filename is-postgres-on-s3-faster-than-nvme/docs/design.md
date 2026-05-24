# Design — Part I: Postgres on NVMe baseline

This document captures the rationale behind every non-obvious choice in the
Part I benchmark. It's deliberately a working document — readable on its own,
but its primary audience is "future me wondering why I picked this knob".

For the published findings, see the [companion blog
post](https://ongres.com/blog/is-postgres-on-s3-faster-than-nvme-part1-ext4-vs-zfs-single-node-vs-ha-fpw-on-off/).


## 1. Context

The larger question motivating this benchmark series is **"Is Postgres on S3
faster than Postgres on NVMe?"** — a literal response to recent claims of S3
beating local storage on Postgres write workloads.

Before that question can be answered honestly, **"Postgres on NVMe" needs to
be defined**. Naïvely it sounds like one thing; in practice the answer depends
on:

- the filesystem (ext4 vs ZFS),
- whether [`full_page_writes`](https://postgresqlco.nf/doc/en/param/full_page_writes/)
  is on or off,
- whether the deployment is single-node or 3-AZ sync-replicated.

If we don't pin those choices first, Part II's S3 numbers risk being compared
against an arbitrary NVMe strawman. Hence Part I.


## 2. Critical decisions

| Decision | Choice | Rationale |
|---|---|---|
| EC2 instance | `i7i.4xlarge` | 16 vCPU Sapphire Rapids, 128 GB RAM, 1× 3.75 TB local Nitro SSD. Recent-gen Xeon for a benchmark that'll be public for years. |
| OS | Ubuntu 24.04 LTS | First-class packages for Postgres 18 (PGDG), ZFS (`zfsutils-linux`), and Python (uv). |
| Postgres | 18 (PGDG apt) | Latest stable at run time. |
| Region | `us-east-2` | Multiple AZs for Phase 2; S3 gateway endpoint = $0 in-region S3 traffic for the result-artifact path; fewer high-profile incidents than us-east-1. |
| Filesystems | ext4 + ZFS | The two filesystems anyone actually deploys Postgres on. mdadm RAID-0 was ruled out (i7i.4xlarge has a single NVMe device, not two). |
| ZFS `recordsize` | 32K (primary), with 8K / 128K probes | 32K won on both tail latency and read-heavy throughput in a recordsize-sensitivity comparison (see §6). |
| `full_page_writes` | `on` for ext4-NVMe; `off` for ZFS-NVMe | ZFS at `recordsize ≥ 8K` guarantees atomic page writes (copy-on-write), making FPW redundant. ext4 has no such guarantee. |
| Workloads | pgbench TPC-B + custom 75/5/20 mixed | TPC-B is write-heavy, standard, directly comparable. Mixed is read-dominated with realistic inserts. |
| Latency capture | `pgbench --log` (per-txn) → [HdrHistogram](https://hdrhistogram.github.io/HdrHistogram/) | Cheap percentile compute over hundreds of millions of samples. |
| Phasing | Phase 1: single-node. Phase 2: 3-node sync-replicated across 3 AZs. | Phase 1 isolates storage effects; Phase 2 measures the "production durability" cost. |


## 3. Scenarios

| Name | Description | FS | `recordsize` | FPW |
|---|---|---|---|---|
| `nvme-ext4` | ext4 on the bare NVMe device, `noatime` | ext4 | n/a | on |
| `nvme-zfs` | ZFS pool on the NVMe device, `compression=off`, `atime=off`, `logbias=throughput` | ZFS | 32K | off |
| `nvme-zfs-fpi` | Same as `nvme-zfs` but FPW=on — quantifies what FPW costs when redundant | ZFS | 32K | on |
| `nvme-zfs-rec32k` | Explicit alias for the 32K default; documents the choice in the scenario name | ZFS | 32K | off |
| `nvme-zfs-rec128k` | Probe larger recordsize (smoke only — full campaign found no improvement over 32K) | ZFS | 128K | off |

The Phase 1 / Phase 2 split:
- **Phase 1 (single-node)**: `nvme-ext4`, `nvme-zfs`, `nvme-zfs-fpi` are
  run as the canonical campaign; `nvme-zfs-rec32k` and `nvme-zfs-rec128k`
  are kept as sensitivity probes (smoke-scale).
- **Phase 2 (3-AZ HA)**: `nvme-ext4` and `nvme-zfs` only. The FPW=on cost
  in HA is well-approximated by the single-node FPW result; recordsize
  *does* interact with replication topology (the HA write path on ZFS is
  sensitive to per-record fsync amplification — see the blog post) but
  characterising that interaction at smoke scale is left for a follow-up.


## 4. Why `i7i.4xlarge`?

The earlier draft of this benchmark targeted `m5ad.4xlarge` (2018-era Naples
EPYC). For a public benchmark with a multi-year shelf life, that felt dated.
`i7i.4xlarge` is the smallest current-gen instance with:
- A modern Intel CPU (Sapphire Rapids).
- Local Nitro SSD NVMe (not EBS).
- 128 GB RAM (enough for a `shared_buffers=32GB` Postgres + working room).

The single 3.75 TB NVMe is the right size for `pgbench -s 15000` (~225 GB
data, plenty of room for WAL, checkpoint workspace, ZFS metadata).


## 5. Why `pgbench -s 15000`, `-c 64`, 30-min steady-state, `checkpoint_timeout=6min`?

- **Scale factor 15000** → ~225 GB dataset. That's 1.75× the 128 GB host RAM
  and ~7× the configured `shared_buffers`. The point is to ensure the working
  set genuinely exceeds the OS page cache so reads hit storage. Smaller scale
  fits in RAM and measures buffer-cache throughput, not storage.
- **64 clients × 16 jobs**: 16 = one job per core; 64 clients = 4 per job. At
  this concurrency:
  - Single-node is CPU-bound on the hot path, exposing storage tail behavior
    in the trough between checkpoints.
  - 3-AZ HA gives commits enough pipelining headroom to hide the cross-AZ
    RTT under Little's Law arithmetic (see blog post). Lower concurrency
    (e.g. 16 clients) caps throughput at `1 / cross-AZ-RTT` per client and
    makes HA look catastrophically worse than it actually is at production
    concurrency.
- **30 min steady-state**: long enough to see ≥ 4 checkpoint cycles at
  `checkpoint_timeout=6min`. With shorter runs the chainsaw effect (post-
  checkpoint TPS recovery) gets aliased by where the run window starts.
- **5 min warmup**, discarded: buffer cache + L1/L2 of any caching layer
  needs a few minutes to reach steady-state.
- **`checkpoint_timeout=6min`** (the Postgres default is 5 min): chosen so the
  blog plots show ~5 checkpoint cycles in the 30-min window — enough to make
  the pattern visible without dominating the chart.


## 6. Why `full_page_writes = off` on ZFS?

Postgres FPW protects against [torn page writes](https://www.postgresql.org/docs/current/wal-reliability.html):
if a crash interrupts a page write mid-flight, the on-disk page can be a
mix of old and new bytes. FPW guards against this by writing the entire 8K
page to WAL after the first dirtying since the last checkpoint, so the
crash-recovery code can restore the page from WAL rather than reading the
torn version.

ZFS, however, is copy-on-write at `recordsize` granularity. A write to an
existing record allocates a new block, writes the new content there, and
swaps the indirect pointer via uberblock update. Either the swap commits
and the new content is visible, or it doesn't and the old content stands;
the page can never be half-written. As long as `recordsize ≥` Postgres's
page size (8K by default), every page write fits in a single ZFS record and
gets that atomicity guarantee, and FPW becomes redundant WAL bloat.

The `nvme-zfs` vs `nvme-zfs-fpi` pair quantifies what FPW costs when
redundant. (Hint: ~18% TPS on write-heavy workloads, near-zero on
read-heavy.)

**Critical caveat**: do NOT apply this `FPW=off` setting to ext4, EBS, or
any storage that doesn't provide atomic-page-write guarantees. ext4 in
particular has no such guarantee; running it with FPW=off risks silent
corruption on crash.


## 7. ZFS `recordsize` choice

Postgres uses an 8K page size by default. The obvious choice is to match it
with `recordsize=8K`. The actual data:

| `recordsize` | TPC-B TPS (single-node) | p50 lat | p99.99 lat |
|---|---|---|---|
| 8K | within noise of 32K | +5% | +24% |
| **32K** | **baseline** | baseline | baseline |
| 128K (smoke only) | no improvement over 32K | — | — |

At 8K, ZFS pays its per-record overhead (checksum, copy-on-write bookkeeping,
atomic-write metadata) once per Postgres page write. At 32K, that overhead
is amortized across four pages. The write amplification of touching a full
32K record per 8K Postgres write is real, but the per-record overhead
appears to dominate it on this hardware.

For reads, larger `recordsize` causes read amplification but is effectively
free if the extra bytes pre-warm the OS page cache for sequential follow-on
reads. 128K showed no measurable benefit over 32K, so 32K is the chosen
default.


## 8. Phase 1 — single-node

### 8.1 Infrastructure

Terraform creates per-scenario, ephemeral infrastructure:
- 1 EC2 instance (`i7i.4xlarge` by default, spot by default).
- VPC with public subnet in a single AZ.
- IAM instance profile with R/W to the results bucket only.
- S3 gateway endpoint on the route table → $0 in-region traffic.
- Spot vs on-demand controlled by `var.use_spot` (default true).

The long-lived **results bucket** lives in a separate Terraform root
(`terraform/persistent/`) so it survives `make down`. Only `make destroy`
removes it.


### 8.2 Bake-once / run-many provisioning

A baked AMI is the runtime path. The flow:
1. `make bake` provisions a one-shot EC2 instance, runs `ansible/bake.yml`
   (apt install Postgres + ZFS + benchmark deps + uv), then snapshots the
   AMI.
2. The AMI ID is written to `terraform/ami.auto.tfvars` and consumed by
   subsequent `make up`'s.
3. Per-scenario `make up` only runs the **storage** + **scenario** roles
   (which take seconds), since common deps are already baked.

This cuts provisioning from ~6-7 min per scenario to ~30 s, which makes
multi-scenario campaigns affordable on spot.


### 8.3 Provisioning (Ansible)

Single playbook `ansible/site.yml` with five plays:
1. **`common`** — kernel tuning (`vm.swappiness=1`, dirty-page ratios,
   transparent_hugepage=madvise), apt prep, NVMe device discovery.
2. **storage role** — picked by scenario via `storage_role_for_scenario`
   in `group_vars/all.yml`. One of `nvme-ext4`, `nvme-zfs`. Creates the
   pool/filesystem, mounts at `/mnt/pgdata`, symlinks
   `/var/lib/postgresql/18/main` → mount.
3. **`postgres`** — apt-pins PG18, renders `postgresql.conf.j2` against the
   scenario's tuning (FPW, random_page_cost, effective_io_concurrency),
   starts the cluster.
4. **`replica`** — only in cluster mode. Sets `primary_conninfo`,
   `hot_standby`, runs `pg_basebackup` from the primary.
5. **`benchmark`** — installs pgbench + run scripts on the primary.


### 8.4 Run shape (per scenario × workload)

1. `pgbench -i -s 15000` → ~225 GB dataset on the chosen storage.
2. `VACUUM ANALYZE` + `CHECKPOINT` — clean slate.
3. Drop kernel page cache + restart Postgres → warmup starts cold.
4. **5-min warmup** — discarded.
5. **30-min steady-state**: `pgbench -c 64 -j 16 -T 1800 --log
   --log-prefix=run`. Per-transaction logs for histogram precision.
6. Capture during the steady-state window:
   - `pg_stat_io` snapshot (before + after).
   - `pg_stat_statements` top-50 (before + after).
   - Postgres server log.
   - `iostat -x 1` for the run window.
   - `pg_stat_wal` samples at 5 s intervals.
7. Compress per-txn logs with zstd and upload everything to
   `s3://${results_bucket}/results/${scenario}/${workload}/${ts}/`.


### 8.5 Latency analysis (HdrHistogram)

`analysis/src/pg_bench_s3_nvme/pgbench_log.py` parses pgbench `--log` output
and feeds per-transaction times (in µs) into an
[HdrHistogram](https://hdrhistogram.github.io/HdrHistogram/) (1µs–60s
range, 3 sig figs).

From the histogram we derive p50 / p90 / p95 / p99 / p99.9 / p99.99 / max
latencies; per-second TPS comes from rolling the per-txn timestamps into
1-second buckets. `compare_scenarios.py` renders summary tables (CSV + MD)
and side-by-side plots; `blog_plots.py` produces the post-shaped four
"dimensions" of plots (ext4-vs-ZFS, checkpoint focus, FPW on/off, single
vs HA).


## 9. Phase 2 — 3-node sync-replicated cluster

### 9.1 Topology

- 3 × `i7i.4xlarge`, one per AZ.
- 1 primary + 2 streaming physical replicas.
- `synchronous_standby_names = 'ANY 1 (replica1, replica2)'` — quorum sync
  of size 1: at least one peer must have the WAL durably on its NVMe at
  COMMIT, and the primary tolerates one replica being slow or down without
  stalling.
- `synchronous_commit = on`. `commit_delay` / `commit_siblings` are left at
  Postgres defaults (`0` / `5`) — deliberately not tuned. Setting
  `commit_delay > 0` would add latency to every commit by design, which is
  exactly the metric the benchmark is measuring. Group-commit batching is
  a tail-throughput optimization that would distort the latency
  distribution being compared.

### 9.2 Scenarios

`nvme-ext4` (FPW on) and `nvme-zfs` (FPW off). The FPW=on ZFS variant and
the recordsize probes are not re-run in HA in this campaign — the FPW=on
cost in HA is well-approximated by the single-node FPW result, and the
recordsize probes are left for follow-up work. Note that recordsize *does*
interact with replication topology (see the blog post's discussion of the
ZFS HA tax) — characterising that interaction at smoke scale is on the
TODO list.

### 9.3 Deltas from Phase 1

- 3 EC2 instances + intra-SG WAL traffic on 5432.
- `replica` role with `primary_conninfo`, `hot_standby = on`,
  `hot_standby_feedback = on`, and a `pg_basebackup` step from the
  pre-seeded primary.
- Per-replica `application_name` matching the `synchronous_standby_names`
  list.
- Run-shape is unchanged. The benchmark runs on the primary only; latency
  now includes sync-replica acknowledgement, which is the whole point.


## 10. Threats to validity

- **N=1 run per cell**. The benchmark is expensive enough (~14 h wallclock
  for the full Phase 1 + Phase 2 matrix) that we only ran each cell once.
  Large deltas (20%+ TPS, multi-ms tail-latency moves) are directionally
  reliable. Single-digit percentage moves and small p99.99 anomalies
  should be read as observations, not conclusions.
- **Spot interruptions**. We use spot by default. The campaign script
  retries once on `make up` failure. Spot capacity for `i7i.4xlarge` in
  some `us-east-2` AZs can be intermittently dry — Phase 2 sometimes
  requires falling back to on-demand (`USE_SPOT=false`).
- **Single AZ for Phase 1**. The single-node Phase 1 lives in one AZ.
  Phase 2's HA topology spans 3 AZs and pays the cross-AZ RTT cost on
  every commit. Phase 1 numbers therefore don't include cross-AZ network
  latency — but Phase 2 explicitly measures that delta.
- **Workload concurrency choice**. The HA cost is heavily concurrency-
  dependent: at 16 clients the cross-AZ RTT swamps throughput; at 64
  clients commits pipeline well and the cost drops to ~24%. The blog post
  is explicit about this; readers running their own benchmarks should pick
  a concurrency representative of their actual workload.
- **AWS Nitro SSDs are not "the" NVMe**. The throughput / latency ceiling
  measured here reflects i7i.4xlarge's single Nitro SSD specifically.
  Higher-end NVMe (on bare metal, NVMe-over-PCIe Gen5, multi-disk RAID-0)
  can be considerably faster.


## 11. Verification (smoke test)

`make smoke` runs a ~20-minute end-to-end check at production concurrency
but scale=1000: full provision, init, run, fetch. Useful for verifying a
fresh AWS account before committing to a full campaign.

`scripts/cluster-smoke.sh` is the cluster equivalent — same shape but with
`CLUSTER=true`.

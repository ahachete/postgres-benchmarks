# Is Postgres on S3 faster than Postgres on NVMe? — Part I: NVMe baseline

> Part of [**postgres-benchmarks**](../README.md), an OnGres-maintained collection of reproducible Postgres benchmarks.

This benchmark answers the **Part I** question: how does Postgres perform on local
NVMe under different filesystem and durability choices? It establishes the NVMe
baseline against which Part II's "Postgres on S3" results will be compared.

Companion blog post: [Is Postgres on S3 faster than NVMe? Part I](https://ongres.com/blog/is-postgres-on-s3-faster-than-nvme-part1-ext4-vs-zfs-single-node-vs-ha-fpw-on-off/).


## Scope

This Part I commit set covers **NVMe-only** scenarios. Part II will extend the
infrastructure and analysis with S3-backed storage paths; that code is held
back until Part II is published.


## Scenarios

| # | Name | Description | FS | ZFS `recordsize` | FPW | Phase 1 | Phase 2 (HA) |
|---|---|---|---|---|---|---|---|
| 1 | `nvme-ext4` | ext4 directly on local NVMe — the high-throughput baseline | ext4 | n/a | on | ✓ | ✓ |
| 2 | `nvme-zfs` | ZFS striped pool on local NVMe, FPW=off | ZFS | 32K | off | ✓ | ✓ |
| 3 | `nvme-zfs-fpi` | Same as `nvme-zfs` but FPW=on — the FPW-cost control | ZFS | 32K | on | ✓ | — |
| 4 | `nvme-zfs-rec32k` | Same as `nvme-zfs` (32K is the default); kept as an explicit alias | ZFS | 32K | off | ✓ | — |
| 5 | `nvme-zfs-rec128k` | ZFS recordsize sensitivity probe | ZFS | 128K | off | smoke | — |

Phase 1 is single-node. Phase 2 adds a 3-AZ sync-replication cluster (primary +
2 replicas, `synchronous_standby_names = 'ANY 1 (replica1, replica2)'`).


### Why ZFS + FPW=off on NVMe?

[`full_page_writes`](https://postgresqlco.nf/doc/en/param/full_page_writes/) protects
against torn pages on crash. On a ZFS dataset where `recordsize >= ` Postgres's
page size (8K by default), every Postgres page write is contained in a single
ZFS record, which copy-on-write writes atomically — so torn pages are
structurally impossible, and FPW becomes redundant WAL bloat. `nvme-zfs-fpi`
runs the same setup with FPW=on so you can quantify what FPW costs when it
isn't actually buying anything.

**Do not copy `FPW=off` to ext4, EBS, or any storage that doesn't provide
atomic page writes.** ext4 in particular has no atomic-page guarantee; torn
pages are a real failure mode.


## Quickstart

Prerequisites: an AWS account, `AWS_PROFILE` exported, `nix` installed.

```bash
nix-shell                              # pulls OpenTofu, Ansible, AWS CLI, Python (uv), …

# One-time, per AWS account:
make bootstrap                         # creates the long-lived results S3 bucket
make bake                              # bakes a base AMI (~6 min); subsequent up's reuse it

# Run a single scenario × workload:
make up   SCENARIO=nvme-zfs CLUSTER=false
make bench WORKLOAD=tpcb               # defaults: 64 clients, 16 jobs, scale=15000, 30 min steady-state
make bench WORKLOAD=mixed
make down
```

The 3-AZ HA cluster variant:

```bash
make up   SCENARIO=nvme-zfs CLUSTER=true
make bench WORKLOAD=tpcb
make bench WORKLOAD=mixed
make down
```

To reproduce the full blog campaign (all NVMe scenarios × both workloads × both
phases — ~14 h, ~$25 on spot):

```bash
bash scripts/campaign-blog.sh
```


## Results & analysis

Per-run artifacts (pgbench logs, server log, `iostat`, `pg_stat_wal` samples)
land in S3 at `s3://pgbench-results-<account>-<region>/results/<scenario>/<workload>/<ts>/`.
The results bucket persists across `make down`; only `make destroy` removes it.

To render plots and summary tables for a finished campaign on an in-region EC2 box
(no large S3 downloads to your laptop):

```bash
bash scripts/analysis-run.sh campaign-blog-<timestamp>
```

This brings up a small analysis instance, parses the runs, computes
[HdrHistogram](https://hdrhistogram.github.io/HdrHistogram/) percentiles, renders
TPS-over-time and latency-percentile plots (per-scenario and side-by-side), writes
everything to `results/<campaign>/analysis/`, and tears the instance down.

Re-rendering from already-parsed data is fast (the script writes `runsum.json`
parsed-cache files alongside the raw logs):

```bash
cd analysis
LD_LIBRARY_PATH= uv run blog-plots ../results/<campaign>
```

(On Ubuntu 20.04 with Nix `shell.nix` active, `LD_LIBRARY_PATH=` is needed so
matplotlib finds system libs instead of the Nix gcc-15 libstdc++; see
`analysis/README.md`.)


## Hardware and cost

- **EC2**: `i7i.4xlarge` — 16 vCPU Intel Sapphire Rapids, 128 GB RAM, 1× 3.75 TB
  local Nitro SSD. Spot pricing ~$0.34/h, on-demand ~$1.41/h (us-east-2).
- **Full Phase 1 + Phase 2 campaign**: ~14 h wallclock.
  - Spot: ~$25 (assumes a Phase 2 retry; spot capacity for `i7i.4xlarge` can
    be intermittently dry in some AZs).
  - On-demand: ~$70.
- **vCPU quota**: Phase 2 launches 3 × i7i.4xlarge simultaneously (48 vCPU).
  Default service quotas may be 32 — request the **on-demand i7i vCPU**
  (`L-1216C47A`) increase to ≥48 before running Phase 2 on-demand.
- **NVMe is ephemeral**: every `make down` destroys the data along with the
  instance. The results bucket (created by `make bootstrap`) is the durable
  store.


## Workloads

- **`tpcb`** — pgbench's built-in TPC-B-like script (write-heavy: per txn
  UPDATE × 3, INSERT, SELECT).
- **`mixed`** — custom 75% SELECT / 5% UPDATE / 20% INSERT against a sibling
  `bench_inserts` table sized to keep WAL volume realistic. Defined in
  `benchmark/workloads/mixed_75_5_20.sql`; init lives in `init_mixed.sql`.

Dataset: `pgbench -s 15000` → ~225 GB. That's 1.75× the host RAM and ~7× the
configured `shared_buffers` — exceeds the OS page cache so reads consistently
hit storage.

Run shape (per scenario × workload):

1. `pgbench -i -s 15000` (clean slate each run).
2. `VACUUM ANALYZE` + force a checkpoint.
3. Drop kernel caches and restart Postgres so warmup begins cold.
4. 5 min warmup (discarded).
5. 30 min steady-state, 16 jobs, 64 concurrent clients, per-txn `pgbench --log`.
6. Capture `pg_stat_io`, `pg_stat_statements` top-50, server log, `iostat -x 1`,
   `pg_stat_wal` samples (5 s interval).
7. Compress logs (zstd) and upload to the persistent results bucket.

See [`docs/design.md`](docs/design.md) for the rationale behind every tuning knob.


## Repository layout

```
is-postgres-on-s3-faster-than-nvme/
├── docs/
│   └── design.md                   # design rationale (Part I)
├── terraform/
│   ├── (root: per-scenario infra: VPC, EC2, IAM, security group, S3 endpoint)
│   ├── persistent/                 # long-lived results bucket — survives `make down`
│   └── analysis/                   # the in-region analysis workstation
├── ansible/
│   ├── site.yml + inventory.py
│   ├── group_vars/all.yml
│   └── roles/
│       ├── common/                 # OS prep, kernel tuning, deps, baked-image step
│       ├── nvme-ext4/              # ext4 directly on NVMe
│       ├── nvme-zfs/               # ZFS pool, dataset, recordsize/atime/logbias
│       ├── postgres/               # apt-pin PG18, tuned postgresql.conf, init the cluster
│       ├── replica/                # primary_conninfo, hot_standby, base-backup wiring
│       └── benchmark/              # pgbench install + scripts on the primary
├── benchmark/
│   ├── run.sh                      # canonical per-run orchestrator (on-host)
│   ├── pg_tune.md                  # GUC-by-GUC justification
│   └── workloads/{init_mixed,mixed_75_5_20}.sql
├── scripts/
│   ├── _lib.sh
│   ├── bench-{up,down,run,fetch,bake,bootstrap,destroy,status}.sh
│   ├── campaign-blog.sh            # Part-I campaign driver
│   ├── cluster-smoke.sh
│   └── analysis-{up,down,shell,run,on-box}.sh
├── analysis/                       # uv-managed Python project
│   └── src/pg_bench_s3_nvme/       # pgbench-log parser, HdrHistogram, plotters
├── Makefile                        # top-level developer entrypoints
└── shell.nix                       # pulls OpenTofu, Ansible, AWS CLI, uv, …
```


## License

Apache 2.0 — see [`../LICENSE`](../LICENSE).

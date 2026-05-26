# Design and full plan


This document is the canonical reference for the benchmark — both the *why*
(rationale, threats to validity) and the *what/how* (repo layout, Phase 1
single-node steps, Phase 2 cluster steps, verification). The
[top-level README](../README.md) is the operator-facing quickstart;
[`benchmark/pg_tune.md`](../benchmark/pg_tune.md) drills into the GUC choices.



## 1. Context

This repo backs the blog post **"Is Postgres on S3 faster than Postgres on
NVMe?"**. The blog post is aiming and answer, in the most possible literal
sense, [the question posted on X recently by
Nikita](https://x.com/nikitabase/status/2052538740669858230), which in
turn references the [Databricks Lakebase
post](https://www.databricks.com/blog/how-lakebase-architecture-delivers-5x-faster-postgres-writes).
claiming a 5× write speedup for Postgres on S3-backed storage.

This benchmark is not intended to confirm or deny those claims. but rather
**to try to compare as objectively as possible Postgres on NVMe and
Postgres on S3**. No other systems or layers involved.

Goal: produce **reproducible, open-source** results comparing Postgres
performance across the local-NVMe and S3-backed paths a user can actually
deploy themselves on AWS today.


## 2. Critical decisions (resolved)

| Decision | Choice |
|---|---|
| EC2 instance | `i7i.4xlarge` (16 vCPU Intel Xeon 5th-gen, 128 GB RAM, 1× 3,750 GB Nitro SSD) |
| Postgres version | 18 (latest stable) |
| OS | Ubuntu 24.04 LTS |
| S3 paths | ZeroFS and SlateDB-NBD, each in two storage-class variants (Standard, Express One Zone) + Mountpoint (failure mode) |
| NVMe layouts | (a) ext4 directly on the 3,750 GB Nitro SSD; (b) ZFS single-vdev pool on the same disk |
| ZFS recordsize | 8 KB (matches Postgres page size; enables `full_page_writes=off`) |
| `full_page_writes` | **on** for ext4-NVMe; **off** for all ZFS-backed scenarios |
| Provisioning | Terraform (infra) + Ansible (software), run locally |
| Workloads | pgbench TPC-B (write-heavy default) + custom 75/5/20 read/update/insert |
| Run shape | 5 min warmup (discarded) + **30 min** steady-state, `checkpoint_timeout = 6min` (5 checkpoint cycles per run) |
| Latency capture | `pgbench --log` per-txn → HdrHistogram via `hdrh` Python lib |
| Region | `us-east-2` (Ohio — fewer high-profile incidents than us-east-1, S3 Express GA, S3 gateway endpoint = $0 in-region traffic) |
| Cost guard | AWS Budgets alarm at $30 (configurable), notifies if blown |
| Phasing | Phase 1: single node. Phase 2: 3-node sync-replica cluster across 3 AZs (S3 Express only — see §4b) |



## 3. Why these seven scenarios?

The naive comparison "Postgres on NVMe vs Postgres on S3" hides three
confounding variables: the **filesystem** layer, the
**[`full_page_writes`](https://postgresqlco.nf/doc/en/param/full_page_writes/)**
GUC, and the **S3 storage class**. To answer *which factor matters*, the
matrix includes:

| # | Name | Backing storage | Filesystem | `full_page_writes` | Used in |
|---|---|---|---|---|---|
| 1 | `nvme-ext4` | EC2 NVMe (single 3.75 TB Nitro SSD, ext4) | ext4 | on | Phase 1 + 2 |
| 2 | `nvme-zfs` | EC2 NVMe (single-vdev ZFS pool on same disk) | ZFS, `recordsize=8K` | off | Phase 1 + 2 |
| 3 | `nvme-zfs-fpi` | Same as `nvme-zfs` but with `full_page_writes=on` (the FPW-impact control) | ZFS, `recordsize=8K` | **on** | Phase 1 only |
| 4 | `zerofs-standard` | S3 Standard via [ZeroFS](https://github.com/Barre/zerofs) → NBD | ZFS, `recordsize=8K` | off | Phase 1 only |
| 5 | `zerofs-express` | [S3 Express One Zone](https://aws.amazon.com/s3/storage-classes/express-one-zone/) via ZeroFS → NBD | ZFS, `recordsize=8K` | off | Phase 1 + 2 |
| 6 | `slatedb-nbd-standard` | S3 Standard via [slatedb-nbd](https://github.com/john-parton/slatedb-nbd) → NBD | ZFS, `recordsize=8K` | off | Phase 1 only |
| 7 | `slatedb-nbd-express` | S3 Express One Zone via slatedb-nbd → NBD | ZFS, `recordsize=8K` | off | Phase 1 + 2 |
| 8 | `mountpoint` | S3 Standard via [Mountpoint for S3](https://github.com/awslabs/mountpoint-s3) | FUSE | n/a — `initdb` fails by design | Phase 1 only |

The `nvme-zfs-fpi` scenario is a tangential-but-illuminating control: same
ZFS storage as `nvme-zfs`, only `full_page_writes` differs. It quantifies
exactly what the FPW=off optimization buys you on a CoW filesystem. Same
story Neon told in ["Get rid of your write-ahead log"](https://neon.tech/blog/get-rid-of-your-writeahead-log)
— here we measure it directly.

The independent stories the post can tell:

1. **`nvme-ext4` vs `nvme-zfs`** — what does ZFS itself cost/gain on identical hardware?
2. **`nvme-zfs` vs `zerofs-*` / `slatedb-nbd-*`** — the controlled S3-vs-NVMe answer with the filesystem held constant.
3. **`nvme-ext4` vs `zerofs-*` / `slatedb-nbd-*`** — the headline answer in its most natural form (each side using the most natural FS for its substrate).
4. **`*-standard` vs `*-express`** — the cost/latency story of the S3 storage class itself, holding everything else constant. This pair is its own chart in the post.

The `mountpoint` scenario is included as a documented failure: S3 Mountpoint
[explicitly cannot modify existing files and lacks file locking](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint.html),
both required by Postgres. Showing why is part of the point. Mountpoint *does*
support directory buckets (Express), but the failure mode is the same — we
capture it once on Standard and note that Express has the same limitation.



## 4b. Why S3 Express One Zone is the architecturally correct S3 path

Standard S3 buys 11×9s durability via cross-AZ replication of every PUT.
Express One Zone (directory buckets) is single-AZ — ~1-2 ms PUT latency
vs ~30-100 ms for Standard, and roughly half the per-request price.

The catch is durability: a single AZ outage can lose a Standard-S3 bucket's
worth of data only after a multi-region disaster, but an Express bucket is
gone the moment its AZ is. **However**, in our 3-node Postgres cluster
(Phase 2), each node uses *its own* Express bucket *in its own AZ*, and
Postgres' `synchronous_standby_names = 'ANY 1 (replica1, replica2)'`
guarantees ≥ 2 AZs have committed every WAL record at COMMIT time.
Cross-AZ durability is now provided by the Postgres cluster itself —
Standard S3's cross-AZ replication becomes pure overhead.

So:

- **Phase 1 single-node** runs *both* Standard and Express variants. Standard
  is what most "naive" Postgres-on-S3 deployments would actually use; Express
  is the tuned-for-performance option. The pair shows the cost of the
  durability/latency trade-off.
- **Phase 2 cluster** runs *only* Express. Running Standard there would mean
  paying twice for the same property; the comparison wouldn't be fair to S3.

Mountpoint for S3 supports directory buckets via `mount-s3 --azid`, but the
fundamental write/locking limitations apply equally to Standard and Express.
We capture the failure once on Standard.



## 4. Why `i7i.4xlarge`?

- Local NVMe is required (no NVMe-less instance is fair to NVMe).
- 5th-gen Intel Xeon (Sapphire Rapids) + 3rd-gen AWS Nitro SSD = the fastest
  NVMe currently on EC2; we want the comparison to be against the *best*
  NVMe, not a handicapped baseline.
- 128 GB RAM lets us pick a scale factor (`-s 15000` ≈ 225 GB) where the
  working set genuinely exceeds RAM — the only setting where storage matters.
- Modern AMD-with-NVMe (`m6ad`, `m7ad`, `c7ad`) does not exist on EC2; the
  newest AMD-with-NVMe is `m5ad` (2018-era EPYC Naples), which would unfairly
  handicap one side.



## 5. Why `pgbench -s 15000`, `-c 64`, 30-min steady-state, `checkpoint_timeout=6min`?

- `-s 15000` ≈ 225 GB on disk → 1.75× RAM, 7× `shared_buffers`. Smaller
  scales end up RAM-bound and obscure storage differences. Larger scales fit
  comfortably in the 3.75 TB local NVMe and the ZeroFS / slatedb-nbd object
  budget.
- `-c 64` on 16 vCPUs is the regime where CPU is not the bottleneck and WAL
  flush concurrency is fully exercised.
- **30-minute steady-state with a 5-minute discarded warmup** plus
  `checkpoint_timeout = 6min` gives **5 full checkpoint cycles** — enough to
  see the post-checkpoint write cliff that dominates real-world Postgres,
  while keeping S3 API costs and EC2 wallclock under control. A more
  frequent checkpoint cadence than the textbook 15-minute default also
  surfaces the worst-case behavior more visibly in TPS-over-time plots,
  which is more interesting for the post.
- ~12M latency samples per scenario at ~10k TPS — still > 10k samples in
  the worst HdrHistogram bucket at p99.9, plenty for stable tail percentiles.



## 6. Why `full_page_writes = off` on ZFS?

[`full_page_writes`](https://postgresqlco.nf/doc/en/param/full_page_writes/)
guards against torn pages: a partial 8 KB write that leaves a heap page
half-old, half-new after a crash. On ext4 over NVMe (4 KB sector atomicity),
half-writes are possible after a crash and FPW must stay on.

ZFS is copy-on-write at the record level. With `recordsize=8K` matching
Postgres' page size, every page write either lands fully (committed via the
next uberblock pointer swap) or doesn't land at all. A torn page is not
possible. Disabling FPW on ZFS scenarios:

- Halves WAL volume on average for write-heavy workloads.
- Should increase steady-state TPS.
- Is the only setting where ZeroFS / slatedb-nbd have a realistic chance,
  since S3 PUT latency dominates large-WAL workloads.

Turning FPW *on* on ZFS scenarios would itself be a configuration error —
the safety it provides is redundant.



## 7. Repository layout

```
postgres-benchmark-s3-nvme/
├── README.md                 # operator quickstart
├── Makefile                  # canonical entry points (up / bench / fetch / down)
├── docs/
│   ├── design.md             # this file
│   ├── results-single-node.md
│   └── results-cluster.md
├── terraform/
│   ├── main.tf               # provider, tags, naming
│   ├── variables.tf          # scenario, cluster, region, instance_type
│   ├── outputs.tf            # ansible_inventory + helpers
│   ├── network.tf            # VPC, 3-AZ subnets, IGW, S3 gateway endpoint
│   ├── security.tf           # SG: SSH from operator IP, intra-cluster 5432
│   ├── iam.tf                # role + bench bucket r/w policy
│   ├── ec2.tf                # i7i.4xlarge × 1 or × 3
│   ├── s3.tf                 # bench bucket
│   └── ssh-key.tf            # locally-generated ed25519 keypair
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.py          # dynamic, reads `terraform output -json`
│   ├── group_vars/all.yml    # PG version, tunables, scenario_tuning map
│   ├── site.yml              # entry play; routes to scenario role
│   ├── requirements.yml      # community.general, ansible.posix
│   └── roles/
│       ├── common/           # apt, kernel tuning, NVMe discovery, ZFS, NBD
│       ├── postgres/         # PG18 from PGDG, pg_createcluster on scenario mount
│       ├── nvme-ext4/        # ext4 directly on the single Nitro SSD
│       ├── nvme-zfs/         # ZFS single-vdev pool, recordsize=8K
│       ├── zerofs/           # ZeroFS → NBD → ZFS pool with L2ARC on local NVMe
│       ├── slatedb-nbd/      # slatedb-nbd → NBD → ZFS pool
│       ├── mountpoint/       # mount-s3 + initdb attempt + failure capture
│       ├── replica/          # Phase 2: pg_basebackup, sync replication
│       ├── benchmark/        # ships run.sh + workloads onto host
├── benchmark/
│   ├── postgresql.conf.j2    # not here (template lives in roles/postgres/templates/)
│   ├── workloads/
│   │   ├── mixed_75_5_20.sql # custom mixed workload
│   │   └── init_mixed.sql    # one-time bench_inserts table setup
│   ├── run.sh                # canonical orchestrator: warmup + steady-state
│   └── pg_tune.md            # per-GUC rationale
├── analysis/
│   ├── pyproject.toml        # uv-managed
│   └── src/pg_bench_s3_nvme/
│       ├── pgbench_log.py            # parser
│       ├── pgbench_log_to_hdr.py     # → .hgrm + .percentiles.json
│       ├── plot_tps.py               # tps-over-time
│       ├── plot_latency_pct.py       # canonical HdrHistogram view
│       └── compare_scenarios.py      # campaign-wide
├── scripts/
│   ├── _lib.sh
│   ├── bench-up.sh
│   ├── bench-run.sh
│   ├── bench-fetch.sh
│   └── bench-down.sh
└── results/                  # campaigns land here, timestamped
```



## 8. Phase 1 — Single-node benchmark


### 8.1 Infrastructure (Terraform)

- VPC `10.42.0.0/16` with one public subnet per AZ × 3 AZs (Phase 1 uses
  AZ 0 only; Phase 2 uses all three).
- Single `i7i.4xlarge` per scenario, named `pgbench-{scenario}-{rand}-primary`.
- S3 gateway endpoint on the route table → zero-cost S3 traffic from EC2.
- One S3 bucket `pgbench-{scenario}-{rand}-data` — used both as the ZeroFS /
  SlateDB-NBD backing store and as the result-artifact destination.
- IAM instance profile: read/write on the bench bucket(s) **plus** the AWS
  managed `AmazonSSMManagedInstanceCore` policy. Operator access uses AWS SSM
  Session Manager — no SSH keys, no port 22 ingress, no public-IP
  requirement (we keep one for diagnostics, but everything works on
  private-only instances). The role also has `CloudWatchAgentServerPolicy`
  so the on-host CloudWatch agent (installed at AMI bake time) can ship
  memory / disk-usage / per-device diskio / netstat metrics and the
  postgres server log + run.log to CloudWatch Logs (7-day retention).
  EC2 detailed monitoring (`monitoring = true`) provides 1-minute granularity
  on CPU / network / EBS metrics for at-a-glance health during long campaigns.
- Security group: only intra-VPC 5432 for replication; egress all (SSM
  agent, apt, S3, PGDG).
- Ansible connects via the `community.aws.aws_ssm` connection plugin; `run.sh`
  is invoked through `aws ssm send-command`; result artifacts move via S3
  rather than rsync.
- State stored locally; readers `terraform init` from scratch — keeps the
  repo cloud-account-agnostic.


### 8.1b Bake-once / run-many provisioning

Ansible-over-SSM has ~6s of round-trip overhead per task — at ~50 tasks the
full provision takes 6-7 minutes even when nothing changes. For a campaign
that touches 7 scenarios × multiple reruns × 3 nodes in Phase 2, that's hours
of avoidable wait. We split the recipe into a **bake half** (apt installs,
kernel-extra modules, persistent sysctl, systemd unit overrides) and a
**runtime half** (per-instance kernel-module load, hugepage verification,
NVMe discovery, scenario role, cluster create on the scenario mount,
benchmark file ship).

The operator runs the bake half **once per recipe change** via `make bake`,
which:

1. Provisions a fresh Ubuntu 24.04 EC2 (Terraform → SSM-managed).
2. Runs `ansible/bake.yml` — only the bake-half tasks of `common` + `postgres`.
3. Cleans transient state (auto-cluster, fstab entries, scenario.json).
4. Writes the sentinel `/etc/pgbench/baked` to the box.
5. `aws ec2 create-image --no-reboot` → waits for the AMI to become available.
6. Writes the resulting AMI id to `terraform/ami.auto.tfvars` (gitignored).

Subsequent `make up SCENARIO=…` calls use that AMI id (Terraform's
`base_ami_id` variable). Each role's `tasks/main.yml` does a
`stat /etc/pgbench/baked` and skips `bake.yml` import on the baked path —
only `runtime.yml` runs. Provisioning drops from ~6.5 min to ~1.5 min.

The bake artifact is region-locked (us-east-2) and per-operator (each AWS
account holds its own snapshot). The Ansible recipe is the canonical source
of truth; the AMI is just a cache derived from it. `make bake` is idempotent
modulo timestamping.



### 8.2 Provisioning (Ansible)

`common` role, applied to every scenario:

- Install: Postgres 18 (apt), `mdadm`, `nbd-client`, `zfsutils-linux`,
  `zfs-dkms`, `awscli`, `cargo`, `git`, `linux-modules-extra-aws`, `sysstat`.
- Sysctl: `vm.swappiness=1`, `vm.dirty_background_ratio=2`, `vm.dirty_ratio=10`,
  `transparent_hugepage=madvise`, `LimitNOFILE=65536`.
- Disable unattended-upgrades during the benchmark window.
- Enumerate ephemeral NVMe disks (size > 1 TB) and assert the expected count.

Per-scenario role builds the data directory at `/mnt/pgdata` on top of:

| Scenario | Data dir backing | FPW |
|---|---|---|
| `nvme-ext4` | ext4 directly on the single 3,750 GB NVMe (`noatime,nodiratime,nobarrier`) | on |
| `nvme-zfs` | `zpool create -O recordsize=8K -O atime=off -O compression=off bench <nvme>` (single vdev) | off |
| `zerofs-{standard,express}` | ZeroFS daemon → NBD → ZFS pool on `/dev/nbd0`. The single NVMe is partitioned: p1 (~200 GB) = ZeroFS local disk cache; p2 (~3.5 TB) = ZFS L2ARC. The `-express` variant points at the regional Express endpoint and a directory bucket in the same AZ as the EC2 | off |
| `slatedb-nbd-{standard,express}` | slatedb-nbd daemon → NBD → ZFS pool on `/dev/nbd0`. Same single-NVMe partition split (p1 = daemon cache, p2 = L2ARC) | off |
| `mountpoint` | `mount-s3` mounts the Standard bucket at `/mnt/pgdata`; we attempt `initdb` and capture the failure | n/a |

`postgres` role applies the tuned `postgresql.conf` (jinja-templated against
the scenario's I/O profile — see [`benchmark/pg_tune.md`](../benchmark/pg_tune.md))
and uses Debian-idiomatic `pg_createcluster` to relocate the data directory
onto the scenario mount.


### 8.3 Benchmark workloads

- **Workload A — pgbench TPC-B**: built-in `pgbench` `-b tpcb-like`. Standard,
  directly comparable to public claims.
- **Workload B — Mixed 75/5/20**:
  [`benchmark/workloads/mixed_75_5_20.sql`](../benchmark/workloads/mixed_75_5_20.sql).
  Within a single transaction, picks one of three branches by random
  weighting:
  - 75% — `SELECT abalance FROM pgbench_accounts WHERE aid = :aid`
  - 5% — `UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid`
  - 20% — `INSERT INTO bench_inserts (...)` (sibling table created in init)

Scale factor: **`-s 15000`** (~225 GB → 1.75× RAM).


### 8.4 Run shape (per scenario × workload)

1. `pgbench -i -s 15000 --no-vacuum --foreign-keys` to initialize.
2. `VACUUM ANALYZE` and force a checkpoint.
3. **Warmup**: 5 minutes — discarded.
4. **Steady-state**: 30 minutes with `-c 64 -j 16 -T 1800 --log
   --log-prefix=…/pgbench`.
5. Capture: pgbench logs, `pg_stat_io`, `pg_stat_wal`, `pg_stat_bgwriter`,
   `pg_stat_statements` top-50, server log, `iostat -x 1`, `vmstat 1`,
   `zpool iostat -v` (where applicable), the rendered `postgresql.conf`,
   and `scenario.json` metadata.
6. On-host: `run.sh` uploads the run directory to
   `s3://<results-bucket>/results/<scenario>/<workload>/<ts>/`.
7. Operator-side: `bench-fetch.sh` syncs from S3 to `results/<tag>/<scenario>/`,
   then runs `pgbench-log-to-hdr` (HdrHistogram compression) and
   `compare-scenarios` to produce campaign-wide TPS / latency / summary artifacts.
   All Python analysis runs locally via `uv` — the EC2 stays minimal.

Total wallclock per scenario × workload: ~45 min (init ~5 + warmup 5 +
steady-state 30 + housekeeping ~5). With 6 working scenarios + 1
expected-fail × 2 workloads: ~9 hours of EC2 wallclock per single-node
campaign (~$5 spot, ~$15 on-demand). S3 API spend across all S3 scenarios:
estimated ~$3–8 (see §11b).


### 8.5 Latency analysis (HdrHistogram)

`analysis/src/pg_bench_s3_nvme/pgbench_log_to_hdr.py`:

- Reads pgbench `--log` files (whitespace-delimited).
- Feeds elapsed-µs into an [`hdrh.histogram.HdrHistogram`](https://github.com/HdrHistogram/HdrHistogram_py)
  (range 1 µs — 60 s, 3 sig figs).
- Emits `.hgrm` (HdrHistogram interval-log format, openable in
  [HistogramLogAnalyzer](https://github.com/HdrHistogram/HistogramLogAnalyzer)),
  `.percentiles.json`, and `.elapsed.csv` (raw timings for the
  HdrHistogram-skeptic).

`plot_latency_pct.py` produces the canonical percentile-over-percentile plot
(log-log: x = `1 / (1 - p/100)`, y = µs). One plot per workload, all
scenarios overlaid.

`plot_tps.py` reads the per-second tps stream, plots tps-over-time.

`compare_scenarios.py` wraps both for a whole campaign, plus a markdown
summary table.



## 9. Phase 2 — 3-node sync-replication cluster

Goal: address the elephant in the room — local NVMe is **ephemeral**. A
fair "durable Postgres on NVMe" deployment needs replicas in different AZs.


### 9.1 Topology

- 3 × `i7i.4xlarge`, one per AZ (`us-east-2a`/`b`/`c`).
- 1 primary, 2 streaming physical replicas.
- `synchronous_standby_names = 'ANY 1 (replica1, replica2)'` — quorum sync of
  size 1 guarantees at least one peer has the WAL on durable storage at
  COMMIT, while one slow/down replica doesn't stall the primary.
- `synchronous_commit = on`. `commit_delay` / `commit_siblings` are left at
  Postgres defaults (`0` / `5`) — deliberately not tuned. Setting
  `commit_delay > 0` would add latency to every commit by design, which is
  exactly the metric the benchmark is measuring. Group-commit batching is
  a tail-throughput optimization that would distort the latency
  distribution being compared.


### 9.2 Scenarios

Phase 2 runs the four scenarios where running on a 3-node cluster makes
architectural sense:

- `nvme-ext4` — local NVMe + sync replication = durable across AZs
- `nvme-zfs` — same with ZFS
- `zerofs-express` — per-AZ Express bucket, durability provided by Postgres sync repl (see §4b)
- `slatedb-nbd-express` — same with slatedb-nbd

Standard-S3 variants are dropped here: in a 3-node sync-replicated cluster,
Standard's cross-AZ durability is redundant with the cluster's own — we'd be
paying twice for the same property. Mountpoint is dropped since its failure
was already established in Phase 1.


### 9.3 Deltas from Phase 1

- `replica` Ansible role: creates a replication user + replication slot on
  the primary, wipes the replica's data dir, runs `pg_basebackup
  --slot=slot_<host> --write-recovery-conf`, sets `application_name` to
  `replica1`/`replica2` in `primary_conninfo` so the quorum sync clause
  matches, starts the replica.
- Terraform: 3 EC2 instances + intra-SG 5432 traffic.
- `run.sh` runs only on the primary; latency now includes sync-replica
  acknowledgement, which is the whole point of the cluster comparison.



## 10. Critical files & patterns

- A single `postgresql.conf.j2` template, parameterized by `scenario`, holds
  all per-scenario tuning (random_page_cost, effective_io_concurrency, FPW)
  via the `scenario_tuning` map in `group_vars/all.yml`.
- `inventory.py` reads `terraform output -json ansible_inventory` so Ansible
  always reflects current infra without a separate inventory checkin.
- A single `run.sh` orchestrator parameterized by `--scenario` and
  `--workload` rather than N runner scripts.
- A small `Makefile` at repo root with the canonical commands (`up`,
  `provision`, `bench`, `fetch`, `down`) so the README quickstart is 5 lines.

External pins (TODO: replace `main` with commit SHAs after first successful campaign):

- ZeroFS: [github.com/Barre/zerofs](https://github.com/Barre/zerofs) — pinned in `roles/zerofs/defaults/main.yml`.
- slatedb-nbd: [github.com/john-parton/slatedb-nbd](https://github.com/john-parton/slatedb-nbd) — pinned in `roles/slatedb-nbd/defaults/main.yml`.
- Mountpoint for S3: [github.com/awslabs/mountpoint-s3](https://github.com/awslabs/mountpoint-s3) — installed from upstream `.deb` (URL in `group_vars/all.yml`).
- HdrHistogram Python: [hdrh on PyPI](https://pypi.org/project/hdrh/) / [HdrHistogram_py](https://github.com/HdrHistogram/HdrHistogram_py).
- HistogramLogAnalyzer GUI: [HdrHistogram/HistogramLogAnalyzer](https://github.com/HdrHistogram/HistogramLogAnalyzer).



## 11. Verification (smoke test)

Cheap end-to-end check (~15 min, ~$0.50):

```sh
# Bring up nvme-ext4 + provision
make up SCENARIO=nvme-ext4

# 1-minute mini-bench at scale 100
make bench SCENARIO=nvme-ext4 WORKLOAD=tpcb \
    SCALE=100 DURATION=60 WARMUP=30 CLIENTS=8 JOBS=4

# Pull results, render plots
make fetch SCENARIO=nvme-ext4

# Tear down
make down
```

If the smoke test passes, run the full 60-minute campaign for each scenario
× workload and produce the blog-ready plots.

Per-scenario sanity checks during the full run:

- `iostat -x 1` shows the NVMe scenarios sustaining >100k IOPS; ZeroFS /
  SlateDB-NBD show ZFS L2ARC hit ratio (`zpool iostat -v` + `arc_summary`)
  climbing as the cache warms.
- `pg_stat_io` confirms the working set is exceeding `shared_buffers`
  (non-trivial `read` counts on `pgbench_accounts`).
- `pg_stat_wal`: WAL volume per scenario — expect ext4-NVMe to write the most
  WAL (FPW on); ZFS scenarios noticeably less. This is a key blog chart.
- `pg_stat_replication` (Phase 2) confirms `sync_state = sync` for at least
  one peer and `flush_lag` stays under 50 ms.
- Mountpoint scenario: structured failure log captured at the expected step
  (`initdb` errors with a permission/locking message); blog post can quote
  it verbatim.



## 11b. S3 cost monitoring

S3 API costs are dominated by:

- **WAL flushes through ZeroFS / SlateDB-NBD LSM** — at ~50 MB/s sustained
  WAL volume (FPW=off, write-heavy), batched into ~64 MB SST PUTs:
  ~3-5k PUTs per 30-min run.
- **LSM compaction churn** — typically 5–10× write amplification: a few
  thousand additional PUTs and a similar number of GETs per run.
- **Working-set cache misses** — bounded by the ARC + L2ARC + ZeroFS disk
  cache; only material during the warmup window.

Back-of-envelope per 30-min S3-backed run on Standard:
~$0.30–$1.00 (PUT @ $0.005/1k, GET @ $0.0004/1k). Express is ~half
the request cost but ~7× the storage cost; for short benchmark campaigns
the request savings dominate, so Express runs cost roughly the same or
less in absolute terms.

**Three-line guard**:

1. **AWS Budgets alarm** at $30/month (override via
   `terraform apply -var='budget_limit_usd=…'`), with optional email
   notification when 80% / 100% is reached. Created in
   `terraform/budget.tf`; survives `terraform destroy` only if
   `keep_bucket=true` is also set, otherwise it cleans up with the rest.
2. **Per-run reckoning**: `run.sh` records `aws s3api list-objects-v2
   --bucket "$BUCKET" --no-paginate | jq '.Contents | length'` plus
   total bucket size before and after each run, into the run directory.
   If a scenario churns out an order of magnitude more objects than
   expected, it shows up in the summary.
3. **Pre-flight calibration** (optional): run a 5-min mini-bench at the
   target scale, extrapolate the post-run object count linearly, and
   abort the full campaign if projected cost is > 2× the budget.



## 12. Threats to validity

### S3 endpoint location and warmup
ZeroFS and slatedb-nbd cache aggressively. We intentionally include a
10-minute warmup *and* a 60-minute steady-state run so the cold-cache effect
is amortized. We also explicitly capture warmup TPS — the cold-cache result
is itself interesting because that's what a post-failover replica will face.

### Single AZ for Phase 1
Phase 1 keeps everything in one AZ to keep the storage signal clean. Phase 2
(3 AZs, sync replication) is where cross-AZ network costs become part of
the comparison.

### NVMe is ephemeral
Phase 1 does not pretend otherwise — its job is to measure raw storage
performance. Phase 2 addresses durability with sync replication, which is
the industry-standard way to make ephemeral local storage durable.

### `pgbench` is synthetic
Acknowledged. We chose pgbench because it's the de-facto standard cited by
every comparable benchmark including the Lakebase post, it's trivially
reproducible, and `--log` gives per-txn timings suitable for HdrHistogram.
A future post may add HammerDB / TPC-C.

### Spot vs on-demand
On-demand for the published numbers (predictable performance). The README
mentions spot for cost-conscious reproductions; the comparison itself isn't
affected.



## 13. Reproducibility checklist

- ZeroFS pinned to a specific commit SHA (in `roles/zerofs/defaults/main.yml`).
- slatedb-nbd pinned to a specific commit SHA (in `roles/slatedb-nbd/defaults/main.yml`).
- Postgres pinned to PG18 from the PGDG apt repository (specific minor
  version recorded in published result sets).
- All Terraform / Ansible variables defaulted; readers override via
  `-var` / `--extra-vars` without editing source.
- Result sets in `results/` include the full `terraform output -json`,
  rendered `postgresql.conf`, server log, the pgbench `--log` raw files, and
  `scenario.json` metadata — i.e. enough to replay analysis without
  re-running the benchmark.



## 14. Out of scope (and why)

- **Comparing to managed services** (Aurora, Lakebase, AlloyDB) — we cannot
  reproduce their internals; the post is about *user-deployable* configurations.
- **HammerDB** — keeping it pgbench-only avoids combining tools and diluting
  the comparability story.
- **Multi-region** — adds latency variables that drown the storage signal.
- **Encryption-at-rest variations** — both ZeroFS and ZFS support it; off
  by default for cleaner I/O numbers, mentioned as a knob in the post.
- **Cost analysis** — explicitly a future post; this one is about performance.

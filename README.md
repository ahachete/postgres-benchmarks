# Postgres benchmarks

An open-source collection of reproducible Postgres benchmarks produced by [**OnGres**](https://ongres.com).

Every benchmark in this repo is **end-to-end reproducible**: Terraform brings up
the infrastructure, Ansible provisions it, scripts run the workload, and
analysis tooling renders the published plots — all from a single `git clone` +
`make` invocation. Costs and AWS quota requirements are spelled out per
benchmark.

This commitment to transparency is detailed in
["Benchmarking: do it with transparency or don't do it at all"](https://ongres.com/blog/benchmarking-do-it-with-transparency/).


## Benchmarks in this repo

| Subfolder | Topic | Status |
|---|---|---|
| [`is-postgres-on-s3-faster-than-nvme/`](is-postgres-on-s3-faster-than-nvme/) | Postgres on local NVMe — ext4 vs ZFS; single-node vs 3-AZ HA; `full_page_writes` on/off. The NVMe baseline for a larger "Postgres on S3 vs Postgres on NVMe?" series. | Part I published, Part II WIP |


## Conventions

- **One benchmark per top-level subfolder**, self-contained: each owns its own
  Terraform, Ansible, scripts, and analysis venv.
- **Shared tooling** can be promoted to the repo root once a real pattern
  emerges across multiple benchmarks. Until then, accept the per-benchmark
  duplication.
- **Reproducibility over polish**: code is committed in the state in which it
  actually produced the published results, not a refactored ideal. Refactors
  happen between benchmark runs, not retroactively.


## License

Apache 2.0 — see [`LICENSE`](LICENSE).

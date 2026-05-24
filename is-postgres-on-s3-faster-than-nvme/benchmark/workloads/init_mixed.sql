-- One-time init for the mixed workload: create the bench_inserts table.
-- Same column shape as pgbench_history (per pgbench source) so WAL volume
-- per row is comparable to the TPC-B insert step.

CREATE TABLE IF NOT EXISTS bench_inserts (
    tid     int,
    bid     int,
    aid     int,
    delta   int,
    mtime   timestamp,
    filler  char(22)
);

-- A simple BRIN index on mtime to give autovacuum something to chew through —
-- representative of real-world insert tables that always have at least one
-- index. BRIN keeps the index size negligible.
CREATE INDEX IF NOT EXISTS bench_inserts_mtime_brin
    ON bench_inserts USING brin (mtime);

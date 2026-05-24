-- Mixed workload: 75% SELECT / 5% UPDATE / 20% INSERT
-- Used by pgbench via:  pgbench -f mixed_75_5_20.sql@100 ...
-- (the @N suffix is pgbench's per-script weight; here we instead use four
--  independent script files with weights, but a single file with branching
--  works too — keeping it as one file simplifies the run.sh wiring.)
--
-- The init step (run.sh) creates a sibling table `bench_inserts` with the
-- same row shape as pgbench_history so insert volume produces realistic
-- WAL traffic. pgbench_accounts is left as the SELECT/UPDATE target.

\set aid random(1, 100000 * :scale)
\set bid random(1, 1 * :scale)
\set tid random(1, 10 * :scale)
\set delta random(-5000, 5000)
\set choice random(1, 100)

BEGIN;

\if :choice <= 75
  -- 75% read: balance lookup
  SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
\elif :choice <= 80
  -- 5% update: balance update (the heaviest write per row)
  UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
\else
  -- 20% insert: append to bench_inserts. Includes a payload column to make
  -- WAL volume realistic; column matches pgbench_history's mtime/filler shape.
  INSERT INTO bench_inserts (tid, bid, aid, delta, mtime, filler)
  VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP, '');
\endif

END;

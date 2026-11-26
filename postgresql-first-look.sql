-- PostgreSQL first look
-- A read-only first pass over a PostgreSQL instance: what is running, what is at risk,
-- what nobody is watching. Published by Datrick, Inc. (https://datrick.com).
--
-- How to run it
--   psql -X -d your_database -f postgresql-first-look.sql
--   It works in any SQL client: every check is one plain SELECT, no psql commands.
--   Run it once per database. Checks 01 to 08 describe the whole instance, checks 09 to
--   18 the database you are connected to.
--
-- What it does and does not do
--   It reads system catalogs and statistics views. It creates nothing, changes no
--   setting and writes no data: the whole file runs in one READ ONLY transaction that
--   ends with ROLLBACK. Each statement stops after 30 seconds, and none waits more than
--   2 seconds for a lock.
--   It needs no extension. A role in pg_monitor (or a superuser) sees everything. An
--   ordinary role sees less: the details of other sessions are hidden, and check 03
--   shows a size only for databases the role may connect to.
--   Executed check by check on PostgreSQL 18. It reads only catalog columns that have
--   existed since PostgreSQL 13. Statistics counters are counted since the last
--   statistics reset, so read "never" as "not since the reset".
--
-- This is a first look, not an assessment. A clean result does not prove that backups
-- restore or that failover works. Those need a test, not a query.
--
-- License: MIT. Copyright (c) 2026 Datrick, Inc. Free to run, change and share, with
-- this notice kept. No warranty. Read it before you run it; that is the point of
-- keeping it to one file.
-- SPDX-License-Identifier: MIT

BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';

-- [01] Version and uptime
-- Compare the major version with https://www.postgresql.org/support/versioning/ :
-- a major version is supported for five years, and the minor release should be the
-- latest one for that major version.
SELECT current_setting('server_version')                       AS server_version,
       current_setting('server_version_num')::int / 10000      AS major_version,
       pg_postmaster_start_time()                              AS started_at,
       date_trunc('minute', now() - pg_postmaster_start_time()) AS uptime,
       pg_is_in_recovery()                                     AS is_standby;

-- [02] Settings that decide memory, durability and safety
-- source = 'default' means nobody has set it. shared_buffers, work_mem and
-- maintenance_work_mem at their defaults usually mean the instance was never tuned.
-- fsync or full_page_writes off risks corruption after a crash.
SELECT name, setting, unit, source,
       (source = 'default') AS still_default
FROM   pg_settings
WHERE  name IN ('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem',
                'max_connections', 'max_wal_size', 'checkpoint_timeout', 'random_page_cost',
                'autovacuum', 'fsync', 'full_page_writes', 'synchronous_commit',
                'wal_level', 'archive_mode', 'log_min_duration_statement',
                'idle_in_transaction_session_timeout', 'statement_timeout',
                'password_encryption', 'ssl')
ORDER  BY name;

-- [03] Databases: size and distance to transaction ID wraparound
-- xid_age climbs until autovacuum freezes old rows. Autovacuum forces that work at
-- autovacuum_freeze_max_age (200 million by default). A value far above it means
-- freezing is not keeping up; near 2 billion the database stops accepting writes.
SELECT d.datname                                   AS database,
       CASE WHEN has_database_privilege(d.datname, 'CONNECT')
            THEN pg_size_pretty(pg_database_size(d.datname)) END AS size,
       age(d.datfrozenxid)                         AS xid_age,
       round(100.0 * age(d.datfrozenxid) / 2000000000, 1) AS pct_to_wraparound
FROM   pg_database d
WHERE  d.datallowconn
ORDER  BY age(d.datfrozenxid) DESC;

-- [04] Connections against the limit
-- Many "idle in transaction" sessions hold locks and block vacuum. A total close to
-- max_connections means the next deploy or retry storm is refused.
SELECT coalesce(state, 'no state')                AS state,
       count(*)                                   AS sessions,
       current_setting('max_connections')::int    AS max_connections
FROM   pg_stat_activity
WHERE  backend_type = 'client backend'
GROUP  BY state
ORDER  BY count(*) DESC;

-- [05] Oldest open transactions and idle-in-transaction sessions
-- A transaction open for hours keeps dead rows from being removed in every table.
SELECT pid, usename, application_name, state,
       date_trunc('second', now() - xact_start)   AS transaction_age,
       date_trunc('second', now() - state_change) AS in_this_state_for,
       left(query, 80)                            AS last_query
FROM   pg_stat_activity
WHERE  xact_start IS NOT NULL
AND    pid <> pg_backend_pid()
AND    backend_type = 'client backend'
ORDER  BY xact_start
LIMIT  10;

-- [06] Replication: standbys attached to this server
-- No rows on a primary means no streaming standby is attached. replay_lag_bytes that
-- keeps growing means the standby is not a failover target right now.
SELECT application_name, client_addr, state, sync_state,
       pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn()
                            ELSE pg_current_wal_lsn() END, replay_lsn) AS replay_lag_bytes,
       replay_lag
FROM   pg_stat_replication
ORDER  BY application_name;

-- [07] Replication slots
-- An inactive slot keeps WAL on disk until the disk is full. Every row with
-- active = false needs an owner or needs to be dropped.
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn()
                                           ELSE pg_current_wal_lsn() END, restart_lsn)) AS retained_wal
FROM   pg_replication_slots
ORDER  BY active, slot_name;

-- [08] WAL archiving
-- archive_mode off means there is no point-in-time recovery from this server's own
-- archive. failed_count above zero with an old last_archived_time means archiving is
-- stuck and WAL is piling up.
SELECT current_setting('archive_mode') AS archive_mode,
       archived_count, last_archived_time,
       failed_count, last_failed_time,
       date_trunc('second', now() - last_archived_time) AS since_last_archive
FROM   pg_stat_archiver;

-- [09] Largest tables, with their indexes and TOAST
SELECT n.nspname                                     AS schema,
       c.relname                                     AS table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       pg_size_pretty(pg_relation_size(c.oid))       AS table_only,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indexes,
       c.reltuples::bigint                           AS estimated_rows
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  c.relkind IN ('r', 'm')
AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
AND    n.nspname NOT LIKE 'pg_toast%'
ORDER  BY pg_total_relation_size(c.oid) DESC
LIMIT  15;

-- [10] Dead rows waiting for vacuum
-- This is a signal, not a bloat measurement: it counts dead rows that vacuum has not
-- removed yet. A high dead_pct on a large table with an old last vacuum is the place
-- to look first. Space already lost to bloat needs pgstattuple to measure.
SELECT schemaname                                    AS schema,
       relname                                       AS table_name,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       greatest(last_vacuum, last_autovacuum)        AS last_vacuumed
FROM   pg_stat_user_tables
WHERE  n_dead_tup > 1000
ORDER  BY n_dead_tup DESC
LIMIT  15;

-- [11] Tables vacuum or analyze has not reached
-- never analyzed means the planner is guessing row counts for that table.
-- rows_changed_since_analyze shows how stale the statistics are.
SELECT schemaname                                    AS schema,
       relname                                       AS table_name,
       n_live_tup,
       greatest(last_vacuum, last_autovacuum)        AS last_vacuumed,
       greatest(last_analyze, last_autoanalyze)      AS last_analyzed,
       n_mod_since_analyze                           AS rows_changed_since_analyze
FROM   pg_stat_user_tables
WHERE  greatest(last_analyze, last_autoanalyze) IS NULL
OR     greatest(last_vacuum, last_autovacuum) IS NULL
OR     greatest(last_vacuum, last_autovacuum) < now() - interval '30 days'
ORDER  BY n_live_tup DESC
LIMIT  15;

-- [12] Tables closest to transaction ID wraparound
-- The table-level view of check 03: which tables hold the database's xid_age up.
SELECT n.nspname                                     AS schema,
       c.relname                                     AS table_name,
       age(c.relfrozenxid)                           AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  c.relkind IN ('r', 'm', 't')
AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER  BY age(c.relfrozenxid) DESC
LIMIT  10;

-- [13] Indexes that are never read
-- Zero scans since the statistics reset. Each one slows every write to its table.
-- Unique and primary key indexes are left out because they enforce a rule. Check a
-- standby's own counters before dropping: an index can be read only there.
SELECT s.schemaname                                  AS schema,
       s.relname                                     AS table_name,
       s.indexrelname                                AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       s.idx_scan                                    AS scans
FROM   pg_stat_user_indexes s
JOIN   pg_index i ON i.indexrelid = s.indexrelid
WHERE  s.idx_scan = 0
AND    NOT i.indisunique
AND    NOT i.indisprimary
ORDER  BY pg_relation_size(s.indexrelid) DESC
LIMIT  20;

-- [14] Duplicate indexes
-- Same table, same columns in the same order, same operator classes, same expression
-- and same WHERE clause. All but one of each group can usually go.
SELECT n.nspname                                     AS schema,
       t.relname                                     AS table_name,
       count(*)                                      AS copies,
       string_agg(x.relname, ', ' ORDER BY x.relname) AS indexes,
       pg_size_pretty(sum(pg_relation_size(i.indexrelid))) AS combined_size
FROM   pg_index i
JOIN   pg_class t ON t.oid = i.indrelid
JOIN   pg_class x ON x.oid = i.indexrelid
JOIN   pg_namespace n ON n.oid = t.relnamespace
WHERE  n.nspname NOT IN ('pg_catalog', 'information_schema')
AND    n.nspname NOT LIKE 'pg_toast%'
GROUP  BY n.nspname, t.relname, i.indrelid,
          i.indkey::text, i.indclass::text, i.indoption::text,
          coalesce(pg_get_expr(i.indexprs, i.indrelid), ''),
          coalesce(pg_get_expr(i.indpred, i.indrelid), '')
HAVING count(*) > 1
ORDER  BY sum(pg_relation_size(i.indexrelid)) DESC;

-- [15] Invalid indexes
-- Left behind by a failed CREATE INDEX CONCURRENTLY or REINDEX CONCURRENTLY. They cost
-- writes and are never used for reads. Drop and rebuild.
SELECT n.nspname AS schema, t.relname AS table_name, x.relname AS index_name
FROM   pg_index i
JOIN   pg_class t ON t.oid = i.indrelid
JOIN   pg_class x ON x.oid = i.indexrelid
JOIN   pg_namespace n ON n.oid = t.relnamespace
WHERE  NOT i.indisvalid
ORDER  BY n.nspname, t.relname, x.relname;

-- [16] Tables without a primary key
-- Logical replication cannot follow updates and deletes on these without a replica
-- identity, and most migration and change-capture tools need a key.
SELECT n.nspname           AS schema,
       c.relname           AS table_name,
       c.reltuples::bigint AS estimated_rows
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  c.relkind = 'r'
AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
AND    NOT EXISTS (SELECT 1 FROM pg_constraint k
                   WHERE k.conrelid = c.oid AND k.contype = 'p')
ORDER  BY c.reltuples DESC
LIMIT  20;

-- [17] Sequences close to their maximum
-- An integer key at 2,147,483,647 stops every insert into its table.
SELECT schemaname AS schema, sequencename AS sequence_name, data_type,
       last_value, max_value,
       round(100.0 * last_value / max_value, 1) AS pct_used
FROM   pg_sequences
WHERE  last_value IS NOT NULL
AND    NOT cycle
AND    100.0 * last_value / max_value > 50
ORDER  BY 100.0 * last_value / max_value DESC;

-- [18] Roles with powers beyond their own data
-- Every superuser is a full administrator of the server and its files. Application
-- roles should not be in this list.
SELECT rolname,
       rolsuper       AS superuser,
       rolcreaterole  AS can_create_roles,
       rolcreatedb    AS can_create_databases,
       rolreplication AS replication,
       rolbypassrls   AS bypasses_row_security,
       rolcanlogin    AS can_login,
       rolvaliduntil  AS password_valid_until
FROM   pg_roles
WHERE  (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)
AND    rolname NOT LIKE 'pg\_%'
ORDER  BY rolsuper DESC, rolname;

ROLLBACK;

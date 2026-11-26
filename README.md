# PostgreSQL first look

One SQL file with 18 read-only checks for the first hour with a PostgreSQL database you did not build: what is running, what is at risk, what nobody is watching.

Published by Datrick, Inc. (https://datrick.com). The same file is served at https://datrick.com/tools/postgresql-first-look.sql.

## Run it

```
psql -X -d your_database -f postgresql-first-look.sql
```

It works in any SQL client: every check is one plain `SELECT`, and the file holds no psql commands. Run it once per database.

Read it before you run it. That is the point of keeping it to one file.

## What it does and does not do

- It reads system catalogs and statistics views. It creates nothing, changes no setting and writes no data.
- The whole file runs in one `READ ONLY` transaction that ends with `ROLLBACK`.
- Each statement stops after 30 seconds, and none waits more than 2 seconds for a lock.
- It needs no extension.
- A role in `pg_monitor` (or a superuser) sees everything. An ordinary role sees less: the details of other sessions are hidden, and check 03 shows a size only for databases the role may connect to.
- Statistics counters are counted since the last statistics reset, so read "never" as "not since the reset".

This is a first look, not an assessment. A clean result does not prove that backups restore or that failover works. Those need a test, not a query.

## The checks

The two tables below are cut from the comments of the SQL file, so they say what the file says.

<!-- checks:start (written by scripts/first-look-package.mjs from the SQL file) -->
### Checks 01 to 08: the whole instance

| check | reads | how to read the result |
|---|---|---|
| 01 | Version and uptime | Compare the major version with https://www.postgresql.org/support/versioning/ : a major version is supported for five years, and the minor release should be the latest one for that major version. |
| 02 | Settings that decide memory, durability and safety | source = 'default' means nobody has set it. shared_buffers, work_mem and maintenance_work_mem at their defaults usually mean the instance was never tuned. fsync or full_page_writes off risks corruption after a crash. |
| 03 | Databases: size and distance to transaction ID wraparound | xid_age climbs until autovacuum freezes old rows. Autovacuum forces that work at autovacuum_freeze_max_age (200 million by default). A value far above it means freezing is not keeping up; near 2 billion the database stops accepting writes. |
| 04 | Connections against the limit | Many "idle in transaction" sessions hold locks and block vacuum. A total close to max_connections means the next deploy or retry storm is refused. |
| 05 | Oldest open transactions and idle-in-transaction sessions | A transaction open for hours keeps dead rows from being removed in every table. |
| 06 | Replication: standbys attached to this server | No rows on a primary means no streaming standby is attached. replay_lag_bytes that keeps growing means the standby is not a failover target right now. |
| 07 | Replication slots | An inactive slot keeps WAL on disk until the disk is full. Every row with active = false needs an owner or needs to be dropped. |
| 08 | WAL archiving | archive_mode off means there is no point-in-time recovery from this server's own archive. failed_count above zero with an old last_archived_time means archiving is stuck and WAL is piling up. |

### Checks 09 to 18: the database you are connected to

| check | reads | how to read the result |
|---|---|---|
| 09 | Largest tables, with their indexes and TOAST |  |
| 10 | Dead rows waiting for vacuum | This is a signal, not a bloat measurement: it counts dead rows that vacuum has not removed yet. A high dead_pct on a large table with an old last vacuum is the place to look first. Space already lost to bloat needs pgstattuple to measure. |
| 11 | Tables vacuum or analyze has not reached | never analyzed means the planner is guessing row counts for that table. rows_changed_since_analyze shows how stale the statistics are. |
| 12 | Tables closest to transaction ID wraparound | The table-level view of check 03: which tables hold the database's xid_age up. |
| 13 | Indexes that are never read | Zero scans since the statistics reset. Each one slows every write to its table. Unique and primary key indexes are left out because they enforce a rule. Check a standby's own counters before dropping: an index can be read only there. |
| 14 | Duplicate indexes | Same table, same columns in the same order, same operator classes, same expression and same WHERE clause. All but one of each group can usually go. |
| 15 | Invalid indexes | Left behind by a failed CREATE INDEX CONCURRENTLY or REINDEX CONCURRENTLY. They cost writes and are never used for reads. Drop and rebuild. |
| 16 | Tables without a primary key | Logical replication cannot follow updates and deletes on these without a replica identity, and most migration and change-capture tools need a key. |
| 17 | Sequences close to their maximum | An integer key at 2,147,483,647 stops every insert into its table. |
| 18 | Roles with powers beyond their own data | Every superuser is a full administrator of the server and its files. Application roles should not be in this list. |
<!-- checks:end -->

## Sample output

Three of the checks on the test fixture described below (a table without a primary key, two identical indexes, a sequence past half of its range). `estimated_rows` is -1 because that table was never analyzed.

```
-- [14] Duplicate indexes
 schema | table_name | copies | indexes                              | combined_size
--------+------------+--------+--------------------------------------+---------------
 public | customers  | 2      | customers_email_a, customers_email_b | 416 kB
(1 row)

-- [16] Tables without a primary key
 schema | table_name     | estimated_rows
--------+----------------+----------------
 public | import_staging | -1
(1 row)

-- [17] Sequences close to their maximum
 schema | sequence_name       | data_type | last_value | max_value  | pct_used
--------+---------------------+-----------+------------+------------+----------
 public | events_event_id_seq | integer   | 1900000000 | 2147483647 | 88.5
(1 row)
```

## How it was tested

Every check was executed on PostgreSQL 18, check by check: version 18.7 as built into PGlite 0.5.17, an embedded build of PostgreSQL, against a small fixture made to trip the checks (a table without a primary key, two identical indexes, an index that is never read, a sequence past half of its range, a role that can create databases).

- Checks 13, 14, 16, 17 and 18 reported the finding planted for them. Check 15 reported nothing on a fixture with no invalid index.
- Checks 01, 02, 03, 09 and 12 were read for their content.
- Checks 06 and 07 ran without an error and had nothing to find: a single embedded instance has no standby and no replication slot.
- Checks 04, 05, 08, 10 and 11 depend on what the server has been doing. They were checked for running, not for content.
- A write attempted inside the file's transaction was refused, and the fixture was unchanged after the run.

The file reads only catalog columns that have existed since PostgreSQL 13. It has not been executed on versions 13 to 17, on a standby, or on a managed cloud service. If a check fails on your server, the error names the check; an issue with the version and the message is welcome.

## License

MIT License. Copyright (c) 2026 Datrick, Inc. Free to run, change and share, with the notice kept. No warranty. The full text is in `LICENSE`.

## From the same people

- A wider review of monitoring, backups, recovery, performance, access and ownership: [database health assessment](https://datrick.com/database-health-assessment)
- Ongoing operations: [PostgreSQL DBA services](https://datrick.com/postgresql-dba-services)
- Contact: info@datrick.com

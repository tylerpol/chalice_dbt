-- One-off cleanup.
--
-- Before each layer had a `+schema` config, `dbt build` materialized every model
-- into DuckDB's default `main` schema. Models now land in `staging`,
-- `intermediate`, and `marts`, so the objects left behind in `main` are dead and
-- can be dropped. Seeds were always configured to `raw` and are unaffected.
--
-- Run this once against duckdb/chalice_duckdb.duckdb, then rebuild with
-- `dbt build`. DataGrip must be disconnected from the database first, or DuckDB
-- will refuse the write lock.
--
-- Verify what is there before dropping:
--     select schema_name, table_name from duckdb_tables()  where schema_name = 'main';
--     select schema_name, view_name  from duckdb_views()   where schema_name = 'main' and not internal;

-- Marts (tables)
drop table if exists main.dim_advertisers;
drop table if exists main.dim_parent_advertisers;

-- Intermediate (view) -- depends on staging, so drop it first
drop view if exists main.int_parent_advertisers;

-- Staging (view)
drop view if exists main.stg_advertisers;

-- Confirm main is clear (raw and the new layer schemas should be untouched):
--     select schema_name, table_name from duckdb_tables()  where schema_name = 'main';
--     select schema_name, view_name  from duckdb_views()   where schema_name = 'main' and not internal;

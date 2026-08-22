# AGENTS.md

Guidance for coding agents working in this repository.

## Repository layout

The dbt project is nested one level below the repo root:

```
chalice_dbt/            # repo root
├── AGENTS.md           # this file
├── duckdb/             # the database, built by dbt (git-ignored)
└── chalice_dbt/        # <- the dbt project; run all dbt commands from here
    ├── dbt_project.yml
    ├── models/
    ├── seeds/
    └── macros/
```

**dbt commands must be run from `chalice_dbt/chalice_dbt/`**, not the repo root.
Running from the root fails with "No dbt_project.yml found". Alternatively pass
`--project-dir chalice_dbt`.

## Environment

- Adapter is **dbt-duckdb**; the warehouse is a single DuckDB file at
  `duckdb/chalice_duckdb.duckdb`, referenced from the `chalice_dbt` profile.
- **The database is git-ignored** — it is a build artifact regenerated from the
  tracked CSV seeds. It may be absent (a fresh clone) or stale; if a query needs
  data that is not there, run `dbt build` rather than assuming the models are
  broken. Never commit the `.duckdb` file.
- **DuckDB allows only one read-write connection at a time.** If a dbt command
  fails with `Could not set lock on file`, another client holds the file and must
  disconnect before dbt can run. Linting does not touch the database and is
  unaffected.

## This project runs on DuckDB — write DuckDB SQL

All SQL in this project targets **DuckDB**, and sqlfluff is configured with
`dialect = duckdb`. Write DuckDB syntax, not Snowflake/BigQuery/Redshift syntax.

DuckDB's dialect is largely **PostgreSQL-compatible**, so Postgres idioms are the
safe default. Practical notes:

- `md5()` is built in and is what surrogate-key hashing uses.
- `current_timestamp` supplies `meta_refreshed_at`.
- **There is no `CREATE DATABASE`.** Each `.duckdb` file *is* a database; use
  `ATTACH 'path.duckdb' AS name` to add another, `DETACH` to remove it.
- Convenience syntax is available and encouraged where it aids clarity:
  `GROUP BY ALL`, `ORDER BY ALL`, `SELECT * EXCLUDE (col)`,
  `SELECT * REPLACE (expr AS col)`, trailing commas.
- Rich native types — `LIST`, `STRUCT`, `MAP`, `ARRAY` — with dotted access for
  struct fields.
- Files can be queried directly: `select * from 'file.csv'`,
  `read_parquet('file.parquet')`.
- `DESCRIBE`, `SUMMARIZE`, `PIVOT`/`UNPIVOT` are built in.
- Object comments are supported (`COMMENT ON TABLE/COLUMN`), which is how
  `persist_docs` works here. Read them back via the `duckdb_tables()`,
  `duckdb_views()`, and `duckdb_columns()` table functions —
  `information_schema.columns` does **not** expose comments in DuckDB.

When unsure whether a function exists, check against the installed engine rather
than assuming; DuckDB's function coverage differs from Postgres in places.

## Layer conventions — read the layer doc before editing

Modeling rules are **layer-specific and defined per layer**. Do not infer them
from sibling models. Before creating or modifying a model, read the markdown file
for that layer:

| Layer | Read this first |
| --- | --- |
| Staging | `chalice_dbt/models/staging/__staging.md` |
| Intermediate | `chalice_dbt/models/intermediate/__intermediate.md` |
| Marts | `chalice_dbt/models/marts/__marts.md` |

Each layer doc is authoritative for that layer's folder structure, naming,
allowed transformations, documentation requirements, and testing norms. When a
convention changes, update the layer doc — it is the source of truth, and this
file deliberately does not duplicate it.

The layer docs are named `__<layer_name>.md` and live in the layer's directory.

## Project-wide conventions

These hold everywhere and are not layer-specific:

- **Import CTEs always.** Every model opens with one CTE per `ref()`/`source()`,
  named exactly after the object it references. Transformation CTEs come after
  and are named for what they do.
- **Every model ends with `select * from final`.**
- **Flow of complexity:** cosmetic reshaping in staging, real transformation in
  intermediate, assembly only in marts. If a model is doing work its layer
  forbids, move the work rather than bending the rule.
- **Surrogate keys** are md5 hashes named `<entity>_key`, singular even when the
  model is plural, and are created **only in the mart layer**.
- **Keys are tested** `unique` and `not_null` at every layer; foreign keys also
  get `relationships` tests in marts. See the layer docs for specifics.
- **Documentation is mandatory.** Every column carries a `description`, and yml
  column order mirrors the model's column order.

## Working practice

- **Lint before considering a change done:** `sqlfluff lint models/` from the dbt
  project directory. The project must lint clean.
- **Validate without executing** using `dbt parse` and `dbt list`. These verify
  the DAG, configs, and yml wiring without touching the database or holding a
  lock — prefer them for checking your work.
- **Do not run `dbt run`, `dbt build`, or `dbt seed` unless asked.** Building is
  the user's call; they run it themselves.
- **Every layer builds into its own schema**, set with `+schema` in
  `dbt_project.yml`: seeds → `raw`, staging → `staging`, intermediate →
  `intermediate`, marts → `marts`. Custom schemas resolve to their exact name (no
  `<target>_<custom>` prefixing) via the `generate_schema_name` override in
  `macros/`. **Nothing should build into DuckDB's default `main` schema** — if
  models appear there, a `+schema` config is missing.
- `scripts/` holds standalone maintenance SQL that is not part of the dbt DAG. It
  is excluded from linting because the dbt templater cannot resolve it.
- `.sqlfluff` and `.sqlfluffignore` require their leading dots to be discovered.
  `ST06` is excluded project-wide because it conflicts with the mart key-ordering
  convention; `macros/` is ignored because sqlfluff cannot lint macro definition
  files.

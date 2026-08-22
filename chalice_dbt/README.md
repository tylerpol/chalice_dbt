```
╭────────────────────────────────────────────╮
│                                            │
│      ████                        ████      │
│      ████████                ████████      │
│      ████████████████████████████████      │
│      ████████████████████████████████      │
│      ████████████████████████████████      │
│      ████████████████████████████████      │
│      ████████████████████████████████      │
│      ████████████████████████████████      │
│        ████████████████████████████        │
│        ████████████████████████████        │
│          ████████████████████████          │
│            ████████████████████            │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                  ████████                  │
│                ████████████                │
│            ████████████████████            │
│      ████████████████████████████████      │
│            ████████████████████            │
│                  ████████                  │
│                    ████                    │
│                                            │
│           C H A L I C E   d b t            │
│                                            │
╰────────────────────────────────────────────╯
```

<div align="center">

**A dbt project modeling advertiser data into a relational warehouse, running on DuckDB.**

</div>

---

## Getting started

The virtualenv lives at `~/Desktop/dbt-env` and is not on `PATH` by default.
Run dbt from **this directory** (`chalice_dbt/chalice_dbt/`), not the repo root:

```bash
cd chalice_dbt                     # from the repo root
~/Desktop/dbt-env/bin/dbt seed     # load CSV seeds into the raw schema
~/Desktop/dbt-env/bin/dbt run      # build staging, intermediate, and marts
~/Desktop/dbt-env/bin/dbt test     # run the test suite
```

To validate the project without touching the database, use `dbt parse` and
`dbt list`.

---

## Warehouse

The warehouse is a single DuckDB file, tracked in git at
`duckdb/chalice_duckdb.duckdb`, configured through the `chalice_dbt` profile in
`~/.dbt/profiles.yml`.

To connect from DataGrip: **Database** tool window → **+** → **Data Source** →
**DuckDB**, and point *Path* at that file.

> [!IMPORTANT]
> **DuckDB permits only one read-write connection at a time.** If dbt fails with
> `Could not set lock on file`, disconnect the data source in DataGrip (or close
> its console tabs) and re-run. Linting is unaffected.

Custom schemas resolve to their exact name — the `generate_schema_name` override
in `macros/` disables dbt's default `<target>_<custom>` prefixing. Seeds land in
the `raw` schema.

---

## Project structure

```
chalice_dbt/                      ── repo root
├── AGENTS.md                     ── conventions for coding agents
├── duckdb/                       ── the DuckDB database file
└── chalice_dbt/                  ── the dbt project
    ├── dbt_project.yml
    ├── .sqlfluff / .sqlfluffignore
    ├── macros/
    ├── seeds/                    ── CSV seeds → raw schema
    └── models/
        ├── staging/              ── views
        ├── intermediate/         ── views
        └── marts/                ── tables
```

---

## Modeling layers

Each layer's rules are documented in a `__<layer_name>.md` file inside the
layer's directory. **Those files are the source of truth** — this README only
summarizes them.

| Layer | Purpose | Docs |
| :--- | :--- | :--- |
| **Staging** | Cosmetic reshaping only — casts, renames, JSON/regex parsing. No joins, unions, or filtering. | [`__staging.md`](models/staging/__staging.md) |
| **Intermediate** | All real transformation — joins, unions, filtering, aggregation, grain changes. Optional when a mart can read staging directly. | [`__intermediate.md`](models/intermediate/__intermediate.md) |
| **Marts** | Relational fact and dimension models. Assembly, uniqueness, and key hashing only. | [`__marts.md`](models/marts/__marts.md) |

Cross-cutting conventions:

- **Import CTEs always**, named after the object referenced; every model ends
  with `select * from final`.
- **Surrogate keys** are md5 hashes named `<entity>_key` (singular even when the
  model is plural), created **only in the mart layer**.
- **Mart column order:** primary key, its native id, then each foreign key
  followed by its native id, then remaining attributes.
- Keys are tested `unique` and `not_null` at every layer; mart foreign keys also
  carry `relationships` tests.

---

## Documentation

`persist_docs` is enabled for relations and columns, so descriptions are written
into DuckDB as native comments on every build. Read them back with:

```sql
select table_name, comment from duckdb_tables();

select table_name, column_name, comment from duckdb_columns()
where table_name = 'dim_advertisers';
```

Staging and intermediate share one `__<layer>_models.yml` per layer. Marts
instead use one yml per model, whose description is a `{{ doc() }}` block defined
in `models/marts/docs/<model_name>.md`.

---

## Linting

```bash
~/Desktop/dbt-env/bin/sqlfluff lint models/
```

Dialect is `duckdb`, templater is `dbt`. Rule `ST06` is excluded because it
conflicts with the mart key-ordering convention, and `macros/` is ignored because
sqlfluff cannot lint macro definition files.

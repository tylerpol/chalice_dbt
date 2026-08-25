# AGENTS.md

Guidance for coding agents working in this repository.

## Repository layout

The dbt project is nested one level below the repo root:

```
chalice_dbt/            # repo root
├── AGENTS.md           # this file
├── .github/            # PR and Jira ticket templates
├── chat/               # the natural-language query app
├── duckdb/             # the database, built by dbt (git-ignored)
└── chalice_dbt/        # <- the dbt project; run all dbt commands from here
    ├── dbt_project.yml
    ├── models/
    │   └── __business_rules.md   # the six business rules, and every decision
    ├── analyses/       # answer queries; plain SQL, not templated
    ├── seeds/
    ├── tests/
    └── macros/
```

**dbt commands must be run from `chalice_dbt/chalice_dbt/`**, not the repo root.
Running from the root fails with "No dbt_project.yml found". Alternatively pass
`--project-dir chalice_dbt`.

## Environment

- Adapter is **dbt-duckdb**; the warehouse is a single DuckDB file at
  `duckdb/chalice.duckdb`, referenced from the `chalice_dbt` profile.
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
| Staging | `chalice_dbt/models/staging/__staging_layer.md` |
| Intermediate | `chalice_dbt/models/intermediate/__intermediate_layer.md` |
| Marts | `chalice_dbt/models/marts/__mart_layer.md` |

Each layer doc is authoritative for that layer's folder structure, naming,
allowed transformations, documentation requirements, and testing norms. When a
convention changes, update the layer doc — it is the source of truth, and this
file deliberately does not duplicate it.

The layer docs are named `__<layer_name>_layer.md` and live in the layer's
directory.

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
- **Documentation belongs in yml, never in a comment block above the SQL.** Do
  not open a model with an explanatory header. The model's `description` in its
  yml says what it does and why; column `description`s carry the per-column
  traps; a mart's doc block in `docs/<model>.md` carries the granularity and dev
  notes; and a decision the business rules were silent on goes in
  `models/__business_rules.md`. Those are the four places, and they are the ones
  `persist_docs` pushes into the warehouse for the chat app to read — a header
  comment reaches none of them and goes stale unread.

  Keep descriptions short. State the rule and the consequence, not the reasoning
  that led there.

  Inline `--` comments are still fine, but only against a specific line whose
  intent the SQL does not carry on its own, and only a line or two:

  ```sql
  -- greatest(0, null) returns 0 in DuckDB, so guard on the contract to
  -- keep "no commitment" reading as null rather than a confident zero.
  ```

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
  `intermediate`, marts → `mart` (singular). Custom schemas resolve to their exact name (no
  `<target>_<custom>` prefixing) via the `generate_schema_name` override in
  `macros/`. **Nothing should build into DuckDB's default `main` schema** — if
  models appear there, a `+schema` config is missing.
- `.sqlfluff` and `.sqlfluffignore` require their leading dots to be discovered.
  `ST06` is excluded project-wide because it conflicts with the mart key-ordering
  convention; `macros/` is ignored because sqlfluff cannot lint macro definition
  files.

## Writing PRs and tickets

Two templates live in `.github/`. Use them whenever asked to draft either — do
not invent a structure.

| Ask | Template |
|---|---|
| "write the PR", "PR description", "raise a PR" | [`.github/pull_request_template.md`](.github/pull_request_template.md) |
| "write a ticket", "Jira ticket", "write up the work" | [`.github/jira_ticket_template.md`](.github/jira_ticket_template.md) |

Read the template first and follow its section order and headings exactly. Fill
every section; delete the guidance comments in angle brackets, and delete
checklist rows that genuinely do not apply rather than leaving them unticked with
no explanation.

What both templates need from you, and what makes them worth filling in:

- **State figures, not adjectives.** Every number you claim must be one you
  actually ran, and both templates have a slot for it. "Revenue is now correct"
  is worthless; "net revenue moves $565,766.81 → $565,766.83 because rounding
  moved from the monthly grain to the reporting grain" is reviewable. If you have
  not run the query, do not write the number.
- **The PR's "Does this change a published number?" table is the section
  reviewers read first.** Most changes here move figures someone has already
  reported. Fill the before/after table whenever a figure moves, including
  rounding and grain changes that look cosmetic.
- **Acceptance criteria must be checkable by someone who did not write the
  code**, each against a specific expected value. Reference the requirement
  number each one covers. Requirements say what to build; acceptance criteria say
  how we will know it is right — do not merge the two.
- **Record decisions, do not bury them.** If the business rules were silent on a
  case and you decided, add it to `models/__business_rules.md` in the same
  change and say so in the PR.
- **Report the build honestly.** `dbt build` counts go in as they came out, and
  a non-zero warning count is stated with the reason it is acceptable — never
  quietly omitted.

If asked for a ticket for work already done, write it as it should have been
raised beforehand: requirements in the imperative, acceptance criteria as the
verified figures.

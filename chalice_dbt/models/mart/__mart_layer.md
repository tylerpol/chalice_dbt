# Marts Layer

The mart layer is the consumption layer. Models here are relationally modeled as
facts and dimensions, named after the entity they describe, and are the objects
downstream consumers query.

## Folder structure

Unlike [staging](../staging/__staging_layer.md) and
[intermediate](../intermediate/__intermediate_layer.md), mart models do **not** share one
monolithic yml. Documentation is broken out per model, and each model's
description is a doc block held in its own markdown file.

```
models/mart/
├── __mart_layer.md                    # this file
├── dim_<entity>.sql              # one file per model
├── dim_<entity>.yml              # per-model yml, named after the model
├── fct_<entity>.sql
├── fct_<entity>.yml
└── docs/
    ├── dim_<entity>.md           # doc block, named after the model
    └── fct_<entity>.md
```

- One `.sql`, one `.yml`, and one `docs/*.md` per mart model, all sharing the
  model's name.
- The yml sets `description: '{{ doc("<model_name>") }}'`, pointing at the doc
  block defined in `docs/<model_name>.md`.
- Materialized as **tables** into the **`mart`** schema. Both the materialization
  and `+schema: mart` are set in `dbt_project.yml` under a key that must match
  this directory's name; the `generate_schema_name` override makes the schema
  resolve to exactly `mart`, with no target prefix. Nothing in this layer builds
  into `main`.

## Doc block requirements

Each `docs/<model_name>.md` wraps its content in
`{% docs <model_name> %} ... {% enddocs %}` and covers exactly three sections:

1. **What this model contains** — the entity and its role in the warehouse.
2. **Granularity** — one row per *what*, and which key enforces it.
3. **Dev notes** — peculiarities and gotchas. This section must earn its place:
   record real traps found in the data or the modeling (unnormalized values that
   cannot be used as join keys, entities that appear in more than one dimension,
   tests that do *not* catch a given failure mode), not restatements of the
   schema.

## Modeling conventions

- **Relational modeling only** — `dim_` for dimensions, `fct_` for facts, named
  after the entity.
- Every model opens with **import CTEs**, does its assembly in a `final` CTE, and
  ends with `select * from final`.
- Surrogate keys are **md5 hashes** of the natural key, named `<entity>_key` and
  kept **singular** even though the model name is plural — `dim_advertisers`
  exposes `advertiser_key`.
- **Column order:** primary key first, immediately followed by the native id that
  was hashed, then each foreign key followed by its native id, then all remaining
  attributes.

  When the primary key is a surrogate hashed from more than one column, **only
  actual ids follow it** — non-id components (dates, months, amounts) are not part
  of that id block and sit with the other attributes instead. Foreign keys come
  next, each beside its native id.

  `fct_delivery_daily` hashes `line_item_id` and `event_date_local`, so the order
  runs `delivery_key`, `line_item_id`, `line_item_key`, then `event_date_local`
  with the measures — the date composes the key but is not an id.
- Every mart carries `meta_refreshed_at`, stamped in the same `final` CTE.
- Hashing happens **inline in `final`** — no separate `hashed` CTE.

## Rules for this layer

**All key hashing happens in mart.** No upstream layer hashes surrogate keys.

**Mart models only assemble.** A mart's job is limited to:

1. assembling pieces from upstream models,
2. defining uniqueness / grain,
3. hashing keys,
4. stamping `meta_refreshed_at`.

**If heavy-duty transformation is needed, push it back to an `int_` model.** A
mart that is doing real transformation work is a signal that an intermediate
model is missing.

**Referencing staging directly is allowed.** When no meaningful transformation
sits between staging and the mart, an `int_` model is unnecessary ceremony —
`ref()` the staging model directly.

## Testing norms

This is the layer where referential integrity is asserted. Every mart model
declares, in its own `<model_name>.yml`:

- `unique` **and** `not_null` on the primary `<entity>_key`.
- `not_null` on every foreign `<entity>_key`.
- `relationships` on every foreign key, pointing at the dimension it references:

  ```yaml
  - relationships:
      to: ref('dim_<entity>')
      field: <entity>_key
  ```

  `not_null` alone does **not** catch an orphaned key — a hash of a nonexistent
  id is still non-null. The `relationships` test is what closes that gap, so it
  is required on foreign keys, not optional.

- On facts additionally: `not_null` on measures that must always be populated,
  and range or sign assertions (via `dbt_utils.accepted_range` or a singular
  test) on measures with a known valid domain.

Self-referencing foreign keys are a normal case here — a `relationships` test
still applies, pointed at whichever dimension holds the parent entity.

Every column gets a `description`, and column order in the yml mirrors the
model's column order.

## A note on sqlfluff

The column-order convention above puts hashed `_key` fields first, which conflicts
with sqlfluff rule `ST06` (calculations must follow simple targets). `ST06` is
excluded in `.sqlfluff` for this reason.

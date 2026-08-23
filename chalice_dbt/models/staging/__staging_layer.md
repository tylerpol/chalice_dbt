# Staging Layer

The staging layer is the first modeling layer on top of raw seeds and sources. It
exists to make the data *look like how you wish it had arrived* — and nothing
more.

## Folder structure

```
models/staging/
├── __staging_layer.md              # this file
├── __staging_models.yml      # one yml for the whole layer
└── stg_<entity>.sql          # one model per source object
```

- One yml file for the entire layer, named `__staging_models.yml`.
- One staging model per source object, named `stg_<entity>`.
- Materialized as **views** into the **`staging`** schema. Both the
  materialization and `+schema: staging` are set in `dbt_project.yml`; the
  `generate_schema_name` override makes the schema resolve to exactly `staging`,
  with no target prefix. Nothing in this layer builds into `main`.

## Modeling conventions

- Every model opens with **import CTEs** — one per `ref()`/`source()`, named
  exactly after the object being referenced.
- Transformation logic lives in a `final` CTE.
- Every model ends with `select * from final`.
- Every column is **explicitly listed and explicitly cast**. No `select *` into
  the final output, no implicit types.
- Do **not** hash surrogate keys here. All hashing happens in the mart layer.

## Rules for this layer

**Staging must never contain meaningful transformations.** Specifically, no:

- joins
- unions
- `where` clauses / row filtering
- aggregation or window functions
- business logic of any kind

**Staging may only contain cosmetic changes**, the kind that reshape how the data
presents without changing what it means:

- data type casting
- column renaming
- JSON parsing / unnesting
- string parsing — `regexp_*`, `replace`, trimming, casing

If a transformation changes *which rows exist* or *what the data means*, it does
not belong here. Push it down to the [intermediate layer](../intermediate/__intermediate_layer.md).

## Testing norms

Every staging model declares, in `__staging_models.yml`:

- `unique` **and** `not_null` on the model's natural key.
- `not_null` on any column the business treats as mandatory — in particular any
  id that will become a foreign key downstream.
- `accepted_values` on low-cardinality categorical columns where the domain is
  known and stable.

Do **not** add `relationships` tests here. Referential integrity is asserted in
the mart layer, against hashed keys.

Every column in the layer gets a `description`, and column order in the yml
mirrors column order in the model.

## Downstream

Staging models feed [intermediate](../intermediate/__intermediate_layer.md) models, and
may be referenced directly by [mart](../marts/__mart_layer.md) models when no
intermediate step is warranted.

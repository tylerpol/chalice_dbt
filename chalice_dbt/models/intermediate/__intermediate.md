# Intermediate Layer

The intermediate layer is where the real work happens. It sits between
[staging](../staging/__staging.md) and [marts](../marts/__marts.md) and absorbs
all transformation complexity so that mart models stay thin.

## Folder structure

```
models/intermediate/
├── __intermediate.md             # this file
├── __intermediate_models.yml     # one yml for the whole layer
└── int_<description>.sql         # one model per transformation step
```

- One yml file for the entire layer, named `__intermediate_models.yml`.
- Models are named `int_<description>`, describing what the step *produces*
  rather than what source it came from.
- Materialized as **views** (set in `dbt_project.yml`).

## Modeling conventions

- Every model opens with **import CTEs** — one per `ref()`, named exactly after
  the model being referenced.
- Transformation logic lives in a `final` CTE (with additional named CTEs above
  it as needed to keep each step readable).
- Every model ends with `select * from final`.

## Rules for this layer

**Intermediate may contain all of the complex transformations** that staging is
forbidden from doing:

- joins and unions
- row filtering (`where`)
- aggregation and window functions
- deduplication and grain changes
- business logic, categorization, derived measures
- fanning out or collapsing records

**Intermediate must not hash surrogate keys.** All key hashing happens in the
mart layer — see [marts](../marts/__marts.md).

## When to use an intermediate model

An intermediate model is warranted when a transformation is complex enough that
inlining it into a mart would obscure the mart's job of assembly. It is **not**
mandatory: a mart may reference a staging model directly when no meaningful
transformation stands between them.

The test is whether the downstream mart stays thin. If a mart is doing heavy
lifting, that logic belongs here instead.

## Testing norms

Because this layer changes grain, the grain must be asserted. Every intermediate
model declares, in `__intermediate_models.yml`:

- `unique` **and** `not_null` on whatever column (or surrogate combination)
  defines the model's grain. This is the most important test in the layer —
  a silent fan-out from a join is the failure mode this layer is most prone to.
- `not_null` on any id carried through to become a downstream foreign key.
- Targeted singular tests in `tests/` for business logic that a generic test
  cannot express — reconciliation between two paths, expected row counts after a
  deduplication, sign or range constraints on a derived measure.

Do **not** add `relationships` tests here; those belong in the mart layer.

Every column gets a `description` explaining what the transformation produced,
not merely restating the column name.

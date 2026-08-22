{% docs dim_parent_advertisers %}

## What this model contains

Conformed dimension of parent advertisers — the top-level corporate entity that
one or more advertisers roll up to. Holds the hashed surrogate key, the
source-system natural key, and the parent's display name.

This is the dimension that `dim_advertisers.parent_advertiser_key` points at.

## Granularity

One row per parent advertiser, keyed on `parent_advertiser_key` (an md5 hash of
`parent_advertiser_id`).

## Dev notes

- Parent advertisers are identified upstream in `int_parent_advertisers` by the
  self-referencing convention in the source data: a row is a parent when
  `advertiser_id = parent_advertiser_id`. There is no separate parent-advertiser
  source table.
- Consequently every parent advertiser **also** appears as a row in
  `dim_advertisers`. This table is a strict subset of that one by entity, not a
  disjoint set — do not union the two expecting distinct entities.
- The convention above assumes the source always emits a self-referencing row
  for each parent. If a child ever references a `parent_advertiser_id` that has
  no self-referencing row of its own, that parent will be **missing** here and
  the foreign key from `dim_advertisers` will not resolve. The `not_null` test
  on `dim_advertisers.parent_advertiser_key` will not catch this — it is an
  orphaned-key condition, so add a `relationships` test if that risk matters.
- `parent_advertiser_name` inherits whatever casing and whitespace the source
  recorded for the parent's own row; no normalization is applied.
- `meta_refreshed_at` is stamped with `current_timestamp` at build time and is
  identical across all rows in a given build. It tracks the rebuild, not source
  data freshness.

{% enddocs %}

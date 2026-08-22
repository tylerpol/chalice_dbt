{% docs dim_advertisers %}

## What this model contains

Conformed dimension of advertisers. Every advertiser known to the source system
appears here exactly once, carrying its hashed surrogate key, its source-system
natural key, a foreign key to its parent advertiser, and its display name.

Child advertisers (regional or brand-level entities) and parent advertisers both
appear in this table. `dim_parent_advertisers` is the narrower dimension holding
only the parent-level entities.

## Granularity

One row per advertiser, keyed on `advertiser_key` (an md5 hash of
`advertiser_id`).

## Dev notes

- `parent_advertiser_key` is a **self-referencing** foreign key in spirit: it
  points at `dim_parent_advertisers`, but every parent advertiser is also an
  advertiser and so has its own row in this table. Joining
  `dim_advertisers` to itself on `advertiser_key = parent_advertiser_key` is
  valid and resolves parent attributes without touching the parent dimension.
- Advertisers that *are* parents have `advertiser_id = parent_advertiser_id`,
  which means `advertiser_key = parent_advertiser_key` on those rows. Filter on
  that equality if you need to separate parents from children.
- `advertiser_name` is passed through **raw from the source**. The source data
  contains casing and trailing-whitespace inconsistencies for what is
  functionally the same brand (e.g. `Northgate Insurance` vs
  `northgate insurance `). No normalization is applied here — do not use
  `advertiser_name` as a join key or a grouping key without cleaning it first.
- `meta_refreshed_at` is stamped with `current_timestamp` at build time. It
  reflects when the model was last rebuilt, not when the underlying source data
  changed. Because the model is materialized as a table, this value is identical
  for every row in a given build.

{% enddocs %}

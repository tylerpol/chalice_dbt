{% docs fct_delivery_daily %}

## What this model contains

Fact table of daily ad delivery — the impressions, clicks, and media cost
recorded for a line item on a given local calendar date. This is the additive
core of the warehouse; spend and volume reporting is built from here.

## Granularity

One row per line item per local event date, keyed on `delivery_key` (an md5 hash
of `line_item_id` and `event_date_local`).

The grain is only true because `int_delivery_daily_deduplicated` collapses 24
exact duplicate rows present in the source. A singular test
(`assert_delivery_daily_grain_is_unique`) guards it, and would fail if the source
ever emits *conflicting* rather than identical duplicates — at which point
`distinct` stops being a safe collapse and a real reconciliation rule is needed.

## Dev notes

- **20 rows reference `LI-5999`, a line item that does not exist** in
  `dim_line_items` — 637,596 impressions and $1,859.74 of media cost with no
  contract behind them. These rows are **deliberately retained**: dropping them
  would silently understate spend. The `relationships` test on `line_item_key`
  therefore runs at **warn** severity. Any inner join to `dim_line_items`
  excludes this volume, so totals taken from this fact directly will not match
  totals taken after joining to the dimension. That discrepancy is real, not a
  modeling error.
- **`billing_month` does not always agree with `event_date_local`** — 24 rows are
  assigned to a month other than the one their event date falls in. Both columns
  are carried deliberately. Use `billing_month` for revenue reconciliation
  (it is what the source bills on) and `event_date_local` for delivery pacing;
  do not derive one from the other.
- **The measures contain impossible values**: 6 rows have negative impressions
  and 6 rows have more clicks than impressions. These are retained as recorded
  rather than clamped, so a naive CTR (`clicks / impressions`) can exceed 1 or
  divide by a negative. Filter or guard explicitly in any rate calculation.
- `event_date_local` is local to the campaign's timezone, which varies across
  five zones. **Summing by date across campaigns mixes timezones** — see
  `dim_campaigns` dev notes.
- Media cost here is the delivered cost only. Billing adjustments live separately
  in `fct_billing_adjustments` and must be added to reach a billable figure.

{% enddocs %}

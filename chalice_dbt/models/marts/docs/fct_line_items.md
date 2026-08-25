{% docs fct_line_items %}

## What this model contains

Delivery pacing against contract, measured at a point in time. Each row answers
"how is this line item tracking, as of this date": how much of the flight had
elapsed, how many impressions the contract therefore expected, how many actually
landed, the ratio between them, and the revenue that goes unearned if the gap is
never closed.

This is business rule 6. It is a **fact**, not an attribute of the line item —
every column is a function of two things the contract does not know: what has
been delivered, and which date you are asking about.

## Granularity

One row per line item per as-of date, keyed on `line_item_pacing_key` (an md5
hash of `line_item_id` and `pacing_as_of_date`).

Only one as-of date exists today (**2026-06-30**), which is precisely why the
grain has to be stated. `line_item_id` alone looks unique in the current data;
add a second snapshot and anything that assumed one row per line item silently
starts fanning out.

## Dev notes

- **Contract terms are on the dimension.** `rate`, `discount_rate`,
  `flight_start`, `flight_end` and `flight_days` are properties of the agreement
  and live on `dim_line_items`. Join on `line_item_key`.
- **`contracted_impressions` is the one exception**, carried here as well because
  it is the basis every measure on the row is calculated against — a pacing row
  is unreadable without it. `assert_line_item_contract_matches_dimension` fails
  the build if the two copies ever disagree.
- **Pacing is measured, not summed.** One row already represents a line item's
  whole position. Joining this to `fct_delivery_daily` repeats each row once per
  delivery day; `sum(revenue_at_risk_usd)` across that join is nonsense. Join to
  `dim_line_items` for contract terms, and to nothing at all for a ranking.
- **"Worst pacing" is the LOWEST `pacing_ratio`.** Ordering descending puts the
  healthiest line items at the top of a risk report — `LI-5015` at 1.052 is
  over-delivering, not failing.
- **Rank by dollars, not by ratio, when the question is about exposure.**
  `LI-5011` paces at 0.632 and risks $2,649.81; `LI-5010` paces at a far
  healthier 0.854 and risks $6,649.60, because its contract is 3.5x larger.
- **Every pacing column is null for `FLAT_FEE` line items.** They carry no
  impression commitment, so pacing does not apply. Null means not applicable —
  do not coalesce it to zero, which would make each of them look infinitely
  behind.
- **`revenue_at_risk_usd` is an upper bound for a flight still running.**
  `LI-5016` runs to 2026-07-31 with only 49% elapsed, so its $11,356.04 counts a
  month that has not happened yet. Against what the contract expects *by the
  as-of date* it is short 178,980 impressions — a 0.818 ratio, mid-pack. Use
  `shortfall_to_date_impressions` for "is it behind", and
  `shortfall_full_contract_impressions` for "what is at stake".
- **Brand attribution is carried on the row**, the same way `fct_delivery_daily`
  does it, so revenue at risk by brand is a group-by rather than a three-table
  join. It is null for the two line items with no campaign (`LI-5105`,
  `LI-5106`) and for the inferred member `LI-5999`.
- **`delivered_impressions_to_date` is a copy of an aggregate**, so it can drift
  from the delivery fact if the two are ever built from different snapshots.
  `assert_line_item_pacing_reconciles` fails the build if it does.

{% enddocs %}

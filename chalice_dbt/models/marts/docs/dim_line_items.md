{% docs dim_line_items %}

## What this model contains

Conformed dimension of line items — the contracted units of delivery within a
campaign. Carries the hashed surrogate key, the source-system natural key, a
foreign key to the parent campaign, and the commercial terms: pricing model,
rate, contracted volume, normalized discount, and flight dates.

## Granularity

One row per line item, keyed on `line_item_key` (an md5 hash of `line_item_id`).

## Dev notes

- **`rate` means two different things** depending on `pricing_model`. For `CPM`
  it is dollars per thousand impressions; for `FLAT_FEE` it is a fixed dollar
  amount for the whole line item. Averaging or summing `rate` across pricing
  models is meaningless — always partition by `pricing_model` first.
- **Use `discount_rate`, never the source's raw discount.** The source column
  mixed fractions (`0.1`) and whole percentage points (`12.0`) in one field;
  `int_line_items_normalized` resolves both to a fraction of 1. The raw column is
  deliberately not carried into this dimension so it cannot be picked up by
  mistake.
- `campaign_key` is **null for two line items** (`LI-5105`, `LI-5106`) whose
  source `campaign_id` is null. Because of this the `not_null` test on
  `campaign_key` runs at **warn** severity rather than error — it is a known
  source gap, surfaced rather than hidden. Any join to `dim_campaigns` silently
  drops these rows, so use a left join if line items must be complete.
- `contracted_impressions` is null for five line items, concentrated in
  `FLAT_FEE` pricing where no volume is contracted. Treat null as "no commitment",
  not as zero — a delivery-vs-contract calculation must exclude these rather than
  score them as under-delivered.

- **The pacing columns are contract arithmetic, not delivery.** `flight_days`,
  `elapsed_days`, `elapsed_share`, and `expected_impressions_to_date` describe
  what the contract expects by `pacing_as_of_date` (fixed at **2026-06-30**, so
  the figures are reproducible rather than drifting with `current_date`).
  Delivered impressions stay in `fct_delivery_daily` where they belong, so the
  pacing index is a division at report time:

  ```sql
  select d.line_item_id,
         d.contracted_impressions,
         d.expected_impressions_to_date,
         sum(f.impressions) as delivered_impressions,
         round(sum(f.impressions) / d.expected_impressions_to_date, 4) as pacing_index
  from mart.dim_line_items d
  join mart.fct_delivery_daily f using (line_item_key)
  where d.expected_impressions_to_date is not null
  group by 1, 2, 3
  order by pacing_index;
  ```

  Above 1 is ahead of contract, below 1 is behind.
- **`expected_impressions_to_date` is null, not zero, for FLAT_FEE line items.**
  They carry no impression commitment, so pacing does not apply to them. Null
  means "not applicable"; zero would mean "expected nothing", which would make
  every flat fee line item look infinitely ahead of pace. Do not coalesce it.
- **Flights are inclusive of both endpoints** — 2026-04-01 to 2026-06-30 is 91
  days, not 90 — and `elapsed_share` is capped at 1, so a flight that closed
  before the as-of date reads as fully elapsed rather than over 100%.
- **Most line items are fully elapsed in the current data**, so their pacing is
  simply delivered against the whole contract. `LI-5016` is the one genuinely
  pro-rated case: a 2026-06-01 to 2026-07-31 flight, 30 of 61 days elapsed, so it
  is measured against 983,607 impressions rather than its full 2,000,000.

{% enddocs %}

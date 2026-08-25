{% docs dim_line_items %}

## What this model contains

Conformed dimension of line items — the contracted units of delivery within a
campaign. Carries the hashed surrogate key, the source-system natural key, the
full key chain up to the brand (campaign, advertiser, parent advertiser), and the
commercial terms: pricing model, rate, contracted volume, normalized discount,
and flight dates.

**Contract terms only.** How a line item is *performing* — delivered impressions,
the contract expectation, the pacing ratio, revenue at risk — lives in
`fct_line_items`, because those depend on delivery and on an as-of date rather
than on the agreement.

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

- **Pacing lives in `fct_line_items`.** `pacing_ratio`,
  `expected_impressions_to_date`, `delivered_impressions_to_date`, the shortfalls
  and `revenue_at_risk_usd` are all functions of delivery and of an as-of date,
  which makes them measures rather than attributes of the contract. Join on
  `line_item_key`:

  ```sql
  select l.line_item_id,
         l.contracted_impressions,
         p.expected_impressions_to_date,
         p.delivered_impressions_to_date,
         round(p.pacing_ratio, 4) as pacing_ratio
  from mart.dim_line_items as l
  join mart.fct_line_items as p using (line_item_key)
  where l.pricing_model = 'CPM'
    and l.contracted_impressions is not null
  order by p.pacing_ratio;
  ```

  Above 1 is ahead of contract, below 1 is behind — so ascending is worst-first.
- **`flight_days` is an attribute** because it is a function of the flight dates
  alone: 2026-04-01 to 2026-06-30 is 91 days, inclusive of both endpoints. Every
  other piece of flight arithmetic depends on the as-of date and belongs to
  `fct_line_items`.
- **`advertiser_key` and `parent_advertiser_key` are resolved through the
  campaign**, so both are null for the two line items with no `campaign_id` and
  for the inferred member. They mirror the keys on `fct_line_items` exactly —
  `int_line_items_normalized` derives them once for both models.

{% enddocs %}

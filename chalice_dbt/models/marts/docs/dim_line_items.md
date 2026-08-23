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

{% enddocs %}

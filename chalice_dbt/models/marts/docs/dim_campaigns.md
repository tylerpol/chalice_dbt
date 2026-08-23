{% docs dim_campaigns %}

## What this model contains

Conformed dimension of campaigns — the advertiser-funded programs that line items
deliver against. Carries the hashed surrogate key, the source-system natural key,
a foreign key to the owning advertiser, and the campaign's descriptive and
scheduling attributes.

## Granularity

One row per campaign, keyed on `campaign_key` (an md5 hash of `campaign_id`).

## Dev notes

- `advertiser_key` points at `dim_advertisers`, **not** `dim_parent_advertisers`.
  Campaigns are owned by the specific advertiser entity, which may be a child
  brand. To roll spend up to the corporate parent, join through
  `dim_advertisers.parent_advertiser_key` — going straight to the parent
  dimension from here will not resolve.
- `timezone` is the campaign's IANA zone and is what `event_date_local` in
  `fct_delivery_daily` is expressed in. Campaigns span `America/New_York`,
  `America/Chicago`, `America/Denver`, `Europe/London`, and `Asia/Tokyo`, so
  **daily delivery across campaigns is not aligned to a single UTC day**.
  Summing by `event_date_local` across markets mixes timezones.
- `start_date`/`end_date` bound the campaign, but line-item flights are not
  guaranteed to sit inside that window — one line item currently flights outside
  its campaign's dates. Do not assume the campaign window contains all delivery.
- Every campaign resolves to a valid advertiser, so the `relationships` test on
  `advertiser_key` is enforced at error severity.

{% enddocs %}

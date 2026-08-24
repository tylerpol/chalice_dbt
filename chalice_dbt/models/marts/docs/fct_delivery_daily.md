{% docs fct_delivery_daily %}

## What this model contains

Fact table of daily ad delivery — the impressions, clicks, media cost, and
**recognised revenue** for a line item on a given local calendar date. This is
the additive core of the warehouse and the lowest grain the data supports;
monthly, campaign, and advertiser reporting are all group-bys over this table
rather than separate models.

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
  assigned to a month other than the one their event date falls in. The business
  rule is that the reporting month is the month delivery *actually occurred*, so
  **`reporting_month` is derived from `event_date_local` and is the one to group
  by**. `billing_month` is retained for traceability and to match billing
  adjustments, which are recorded at that grain. A report built on
  `billing_month` will not tie to one built on `reporting_month`; that is
  expected, not a defect.
- **The measures contain impossible values**: 6 rows have negative impressions
  and 6 rows have more clicks than impressions. These are retained as recorded
  rather than clamped, so a naive CTR (`clicks / impressions`) can exceed 1 or
  divide by a negative. Filter or guard explicitly in any rate calculation.
- `event_date_local` is local to the campaign's timezone, which varies across
  five zones. **Summing by date across campaigns mixes timezones** — see
  `dim_campaigns` dev notes.
- **Media cost is not revenue.** `media_cost_usd` is what delivery cost;
  `net_revenue_usd` is what was earned under the contract. They are unrelated
  figures and summing both into one total is meaningless.
- **`revenue_basis` tells you whether a day's revenue was earned or allocated.**
  `CPM_DELIVERED` rows earned it from that day's impressions. `FLAT_FEE_ALLOCATED`
  rows carry a share of a monthly fee spread evenly across the month's flight
  days — the fee is not a function of impressions, so a flat fee day's revenue
  says nothing about that day's delivery. Summing to the month reproduces the
  contracted rate exactly, which is what the rule actually specifies.
- **Revenue is null where the line item has no pricing terms.** `LI-5999` has 20
  delivery rows and no rate, so it has media cost but no revenue. Delivery and
  revenue totals will not tie for it, by design.
- **Money is stored to six decimal places, not cents.** A daily flat fee share can
  be `833.333333`; rounding at this grain would lose cents from the month. Round
  after aggregating to your reporting grain.
- **Adjustments are not here.** They apply at campaign and month level only and
  live in `fct_billing_adjustments`. Add them after discounted revenue to reach a
  billable figure — see the example below.

## Summarising

Everything above the delivery grain is a group-by. Revenue by month:

```sql
select reporting_month,
       round(sum(gross_revenue_usd), 2) as gross,
       round(sum(discount_usd), 2)      as discount,
       round(sum(net_revenue_usd), 2)   as net
from mart.fct_delivery_daily
group by 1 order by 1;
```

Billable revenue by campaign and month — net revenue with adjustments applied
after the discount, per the business rule:

```sql
with revenue as (
    select campaign_id, reporting_month, sum(net_revenue_usd) as net_revenue_usd
    from mart.fct_delivery_daily
    where campaign_id is not null
    group by 1, 2
),

adjustments as (
    select campaign_id, billing_month as reporting_month,
           sum(adjustment_usd) as adjustments_usd
    from mart.fct_billing_adjustments
    group by 1, 2
)

select coalesce(r.campaign_id, a.campaign_id)         as campaign_id,
       coalesce(r.reporting_month, a.reporting_month) as reporting_month,
       round(coalesce(r.net_revenue_usd, 0), 2)       as net_revenue_usd,
       round(coalesce(a.adjustments_usd, 0), 2)       as adjustments_usd,
       round(coalesce(r.net_revenue_usd, 0)
             + coalesce(a.adjustments_usd, 0), 2)     as billed_revenue_usd
from revenue r
full outer join adjustments a
  on r.campaign_id = a.campaign_id
 and r.reporting_month = a.reporting_month
order by 1, 2;
```

A full outer join, not an inner one: a campaign month can carry an adjustment
with no delivery behind it, and an inner join would drop real billed value.

Pacing lives on `dim_line_items` — see its doc for the query.

{% enddocs %}

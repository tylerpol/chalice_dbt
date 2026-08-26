-- 1a. Recognised revenue by advertiser and month, Q2 2026 -- RAW VERSION
--
-- Plain SQL. Run it directly against the DuckDB file; nothing here is templated.
--
-- Same answer as analyses/mart/1a_recognized_revenue_by_advertiser_month_mart.sql,
-- built straight from the raw seeds. Every correction the warehouse applies has
-- to be re-applied by hand here, which is the point of keeping both: the CTEs
-- below are exactly the cleaning the mart layer stops you from having to
-- remember, and each one corrects a defect in the source data.
--
--   deduped        -- 24 byte-identical rows in delivery_daily would otherwise
--                     double-count 372,942 impressions and $3,142.57 of revenue
--   line_items     -- discount_pct mixes fractions and percentage points; taken
--                     literally it understates revenue by $296,677.46
--   reporting_month - derived from event_date_local, not billing_month, which
--                     disagrees on 24 rows and moves $3,193.42 between months
--   left join      -- LI-5999 delivers but has no line item record, so it earns
--                     no revenue and must not silently vanish
--   brand          -- 7 advertisers are really 5 brands

with delivery_daily as (

    select * from raw.delivery_daily

),

line_items_raw as (

    select * from raw.line_items

),

campaigns as (

    select * from raw.campaigns

),

advertisers as (

    select * from raw.advertisers

),

billing_adjustments as (

    select * from raw.billing_adjustments

),

-- Exact duplicate delivery rows.
deduped as (

    select distinct * from delivery_daily

),

-- discount_pct holds fractions (0.1) and percentage points (12.0) in the same
-- column. Values above 1 are percentage points.
line_items as (

    select
        line_item_id,
        campaign_id,
        pricing_model,
        rate,
        contracted_impressions,
        flight_start,
        flight_end,
        coalesce(
            case when discount_pct > 1 then discount_pct / 100 else discount_pct end, 0
        ) as discount_rate
    from line_items_raw

),

q2_months as (

    select cast('2026-04-01' as date) as month_start

    union all

    select cast('2026-05-01' as date)

    union all

    select cast('2026-06-01' as date)

),

-- Rule 1: CPM revenue is earned by delivered impressions. Computed per delivery
-- day and then summed, matching how the warehouse stores it, so the two versions
-- round identically.
cpm_revenue as (

    select
        line_items.line_item_id,
        strftime(date_trunc('month', deduped.event_date_local), '%Y-%m') as reporting_month,
        sum(
            cast(cast(deduped.impressions as decimal(18, 6)) / 1000 * line_items.rate as decimal(18, 6))
        ) as gross_revenue_usd
    from deduped
    inner join line_items
        on deduped.line_item_id = line_items.line_item_id
    where line_items.pricing_model = 'CPM'
        and date_trunc('month', deduped.event_date_local) in (select month_start from q2_months)
    group by 1, 2

),

-- Rule 2: the flat fee is recognised in full for every calendar month in flight
-- and is not a function of impressions, so these months come from the flight
-- window rather than from delivery.
flat_fee_revenue as (

    select
        line_items.line_item_id,
        strftime(q2_months.month_start, '%Y-%m') as reporting_month,
        cast(line_items.rate as decimal(18, 6)) as gross_revenue_usd
    from line_items
    cross join q2_months
    where line_items.pricing_model = 'FLAT_FEE'
        and q2_months.month_start >= date_trunc('month', line_items.flight_start)
        and q2_months.month_start <= date_trunc('month', line_items.flight_end)

),

-- Rule 3: the discount comes off gross revenue for the line item.
discounted as (

    select
        recognised.line_item_id,
        recognised.reporting_month,
        recognised.gross_revenue_usd,
        cast(
            round(recognised.gross_revenue_usd * line_items.discount_rate, 6) as decimal(18, 6)
        ) as discount_usd,
        recognised.gross_revenue_usd - cast(
            round(recognised.gross_revenue_usd * line_items.discount_rate, 6) as decimal(18, 6)
        ) as net_revenue_usd,
        line_items.campaign_id
    from (
        select * from cpm_revenue

        union all

        select * from flat_fee_revenue
    ) as recognised
    inner join line_items
        on recognised.line_item_id = line_items.line_item_id

),

-- 7 advertiser rows are 5 brands. Roll up to the parent.
brand as (

    select
        child.advertiser_id,
        parent.advertiser_name as parent_advertiser_name
    from advertisers as child
    inner join advertisers as parent
        on child.parent_advertiser_id = parent.advertiser_id

),

revenue as (

    select
        discounted.reporting_month,
        brand.parent_advertiser_name,
        discounted.gross_revenue_usd,
        discounted.discount_usd,
        discounted.net_revenue_usd,
        cast(0 as decimal(18, 6)) as adjustments_usd
    from discounted
    left join campaigns
        on discounted.campaign_id = campaigns.campaign_id
    left join brand
        on campaigns.advertiser_id = brand.advertiser_id

),

-- Rule 4: adjustments apply at campaign x month and are added after the discount.
adjustments as (

    select
        billing_adjustments.billing_month as reporting_month,
        brand.parent_advertiser_name,
        cast(0 as decimal(18, 6)) as gross_revenue_usd,
        cast(0 as decimal(18, 6)) as discount_usd,
        cast(0 as decimal(18, 6)) as net_revenue_usd,
        cast(billing_adjustments.adjustment_usd as decimal(18, 6)) as adjustments_usd
    from billing_adjustments
    left join campaigns
        on billing_adjustments.campaign_id = campaigns.campaign_id
    left join brand
        on campaigns.advertiser_id = brand.advertiser_id
    where billing_adjustments.billing_month in ('2026-04', '2026-05', '2026-06')

),

labelled as (

    select
        coalesce(parent_advertiser_name, 'UNATTRIBUTED (line item has no campaign)') as brand,
        reporting_month,
        gross_revenue_usd,
        discount_usd,
        net_revenue_usd,
        adjustments_usd
    from (
        select * from revenue

        union all

        select * from adjustments
    ) as combined

),

final as (

    select
        coalesce(brand, 'ALL BRANDS') as brand,
        coalesce(reporting_month, 'Q2 2026 TOTAL') as reporting_month,
        round(sum(gross_revenue_usd), 2) as gross_revenue_usd,
        round(sum(discount_usd), 2) as discount_usd,
        round(sum(net_revenue_usd), 2) as net_revenue_usd,
        round(sum(adjustments_usd), 2) as adjustments_usd,
        round(sum(net_revenue_usd) + sum(adjustments_usd), 2) as billed_revenue_usd,
        grouping(brand) as is_grand_total,
        grouping(reporting_month) as is_quarter_total
    from labelled
    group by grouping sets ((brand, reporting_month), (brand), ())

)

select
    brand,
    reporting_month,
    gross_revenue_usd,
    discount_usd,
    net_revenue_usd,
    adjustments_usd,
    billed_revenue_usd
from final
order by
    is_grand_total,
    brand,
    is_quarter_total,
    reporting_month

-- 1a. Recognised revenue by advertiser and month, Q2 2026 -- MART VERSION
--
-- Plain SQL. Run it directly against the DuckDB file; nothing here is templated.
--
-- One row per brand per month, plus a quarter total per brand and a grand total.
-- "One brand is one line" means the PARENT advertiser: the source carries 7
-- advertiser rows that are really 5 brands (ADV-1002 'northgate insurance ' is
-- ADV-1001 with different casing and a trailing space; ADV-1004 'Perreault Foods
-- NA' is a division of ADV-1003). Reporting on advertiser_id splits two brands
-- and understates Perreault Foods by 53%.
--
-- The warehouse carries parent_advertiser_id down onto both facts, so the
-- rollup is a group-by rather than a three-table join. The single join below is
-- only to fetch the brand's display name -- facts hold keys, dimensions hold
-- labels.
--
-- Revenue recognition, discounting, the reporting month and the adjustment grain
-- are all resolved in the models. See models/__business_rules.md.
--
-- Ties to analyses/raw/1a_recognized_revenue_by_advertiser_month_raw.sql.

with revenue as (

    select
        reporting_month,
        parent_advertiser_id,
        gross_revenue_usd,
        discount_usd,
        net_revenue_usd,
        cast(0 as decimal(18, 6)) as adjustments_usd
    from mart.fct_delivery_daily
    where reporting_month in ('2026-04', '2026-05', '2026-06')

),

-- Adjustments apply at campaign x month and are added AFTER discounted revenue.
adjustments as (

    select
        billing_month as reporting_month,
        parent_advertiser_id,
        cast(0 as decimal(18, 6)) as gross_revenue_usd,
        cast(0 as decimal(18, 6)) as discount_usd,
        cast(0 as decimal(18, 6)) as net_revenue_usd,
        cast(adjustment_usd as decimal(18, 6)) as adjustments_usd
    from mart.fct_billing_adjustments
    where billing_month in ('2026-04', '2026-05', '2026-06')

),

combined as (

    select * from revenue

    union all

    select * from adjustments

),

-- Revenue with no campaign reaches no advertiser. It is labelled rather than
-- dropped so the grand total still reconciles to total recognised revenue.
labelled as (

    select
        coalesce(
            brands.parent_advertiser_name, 'UNATTRIBUTED (line item has no campaign)'
        ) as brand,
        combined.reporting_month,
        combined.gross_revenue_usd,
        combined.discount_usd,
        combined.net_revenue_usd,
        combined.adjustments_usd
    from combined
    left join mart.dim_parent_advertisers as brands
        on combined.parent_advertiser_id = brands.parent_advertiser_id

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

-- Rule 2: a flat fee line item recognises its rate in full for every calendar
-- month it is in flight. Because the mart is at delivery grain, that monthly
-- figure is an allocation across the month's flight days, which is only lossless
-- while every flight day actually has a delivery row.
--
-- This asserts the rule survives the allocation: summing the daily rows for a
-- flat fee line item month must reproduce the contracted rate, to the cent. A
-- missing delivery day, a flight boundary handled wrongly, or a change to the
-- allocation denominator would all show up here as under- or over-recognised
-- revenue rather than passing silently.
--
-- Compared to the cent because a daily share of 833.333333 cannot sum back to
-- 25000 in any decimal scale; cents are the precision money is reported in.

with fct_delivery_daily as (

    select * from {{ ref('fct_delivery_daily') }}

),

dim_line_items as (

    select * from {{ ref('dim_line_items') }}

),

final as (

    select
        delivery.line_item_id,
        delivery.reporting_month,
        round(sum(delivery.gross_revenue_usd), 2) as recognised_usd,
        round(max(line_items.rate), 2) as contracted_rate_usd
    from fct_delivery_daily as delivery
    inner join dim_line_items as line_items
        on delivery.line_item_key = line_items.line_item_key
    where line_items.pricing_model = 'FLAT_FEE'
    group by 1, 2
    having round(sum(delivery.gross_revenue_usd), 2) <> round(max(line_items.rate), 2)

)

select * from final

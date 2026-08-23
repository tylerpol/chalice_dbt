-- The source contains 24 rows that are exact duplicates across every column,
-- which would otherwise double-count impressions, clicks, and media cost at the
-- line-item/day grain. Because the duplicates are byte-identical rather than
-- conflicting restatements, `distinct` is a safe collapse: no column has to be
-- chosen between competing values.

with stg_delivery_daily as (

    select * from {{ ref('stg_delivery_daily') }}

),

final as (

    select distinct
        line_item_id,
        event_date_local,
        impressions,
        clicks,
        media_cost_usd,
        billing_month
    from stg_delivery_daily

)

select * from final

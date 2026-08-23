with delivery_daily as (

    select * from {{ ref('delivery_daily') }}

),

final as (

    select
        cast(line_item_id as varchar) as line_item_id,
        cast(event_date_local as date) as event_date_local,
        cast(impressions as bigint) as impressions,
        cast(clicks as bigint) as clicks,
        cast(media_cost_usd as decimal(18, 2)) as media_cost_usd,
        cast(billing_month as varchar) as billing_month
    from delivery_daily

)

select * from final

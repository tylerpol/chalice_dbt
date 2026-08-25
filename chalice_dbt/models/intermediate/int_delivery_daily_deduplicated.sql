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

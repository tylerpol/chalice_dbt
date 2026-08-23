with int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

final as (

    select
        md5(line_item_id || '|' || cast(event_date_local as varchar)) as delivery_key,
        line_item_id,
        md5(line_item_id) as line_item_key,
        event_date_local,
        impressions,
        clicks,
        media_cost_usd,
        billing_month,
        current_timestamp as meta_refreshed_at
    from int_delivery_daily_deduplicated

)

select * from final

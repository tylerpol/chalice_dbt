with int_delivery_daily_revenue as (

    select * from {{ ref('int_delivery_daily_revenue') }}

),

final as (

    select
        md5(line_item_id || '|' || cast(event_date_local as varchar)) as delivery_key,
        line_item_id,
        md5(line_item_id) as line_item_key,
        event_date_local,
        campaign_id,
        md5(campaign_id) as campaign_key,
        advertiser_id,
        md5(advertiser_id) as advertiser_key,
        parent_advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        reporting_month,
        impressions,
        clicks,
        media_cost_usd,
        billing_month,
        revenue_basis,
        gross_revenue_usd,
        discount_rate,
        discount_usd,
        net_revenue_usd,
        current_timestamp as meta_refreshed_at
    from int_delivery_daily_revenue

)

select * from final

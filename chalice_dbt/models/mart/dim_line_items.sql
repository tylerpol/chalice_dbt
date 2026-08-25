with int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

),

final as (

    select
        md5(line_item_id) as line_item_key,
        line_item_id,
        md5(campaign_id) as campaign_key,
        campaign_id,
        md5(advertiser_id) as advertiser_key,
        advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        parent_advertiser_id,
        pricing_model,
        rate,
        contracted_impressions,
        discount_rate,
        flight_start,
        flight_end,
        flight_days,
        is_unmapped,
        current_timestamp as meta_refreshed_at
    from int_line_items_normalized

)

select * from final

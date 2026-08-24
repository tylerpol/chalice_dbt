with int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

),

final as (

    select
        md5(line_item_id) as line_item_key,
        line_item_id,
        md5(campaign_id) as campaign_key,
        campaign_id,
        pricing_model,
        rate,
        contracted_impressions,
        discount_rate,
        flight_start,
        flight_end,
        is_unmapped,
        flight_days,
        pacing_as_of_date,
        elapsed_days,
        elapsed_share,
        expected_impressions_to_date,
        current_timestamp as meta_refreshed_at
    from int_line_items_normalized

)

select * from final

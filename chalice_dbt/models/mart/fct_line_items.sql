with int_line_items_pacing as (

    select * from {{ ref('int_line_items_pacing') }}

),

final as (

    select
        md5(line_item_id || '|' || cast(pacing_as_of_date as varchar)) as line_item_pacing_key,
        line_item_id,
        md5(line_item_id) as line_item_key,
        pacing_as_of_date,
        campaign_id,
        md5(campaign_id) as campaign_key,
        advertiser_id,
        md5(advertiser_id) as advertiser_key,
        parent_advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        elapsed_days,
        elapsed_share,
        contracted_impressions,
        expected_impressions_to_date,
        delivered_impressions_to_date,
        pacing_ratio,
        shortfall_to_date_impressions,
        shortfall_full_contract_impressions,
        revenue_at_risk_usd,
        current_timestamp as meta_refreshed_at
    from int_line_items_pacing

)

select * from final

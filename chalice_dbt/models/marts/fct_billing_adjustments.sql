with int_billing_adjustments_attributed as (

    select * from {{ ref('int_billing_adjustments_attributed') }}

),

final as (

    select
        md5(
            campaign_id || '|' || billing_month || '|'
            || cast(adjustment_usd as varchar) || '|' || reason
        ) as billing_adjustment_key,
        campaign_id,
        md5(campaign_id) as campaign_key,
        advertiser_id,
        md5(advertiser_id) as advertiser_key,
        parent_advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        billing_month,
        adjustment_usd,
        reason,
        current_timestamp as meta_refreshed_at
    from int_billing_adjustments_attributed

)

select * from final

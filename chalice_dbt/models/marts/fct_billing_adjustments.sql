with stg_billing_adjustments as (

    select * from {{ ref('stg_billing_adjustments') }}

),

final as (

    select
        md5(
            campaign_id || '|' || billing_month || '|'
            || cast(adjustment_usd as varchar) || '|' || reason
        ) as billing_adjustment_key,
        campaign_id,
        md5(campaign_id) as campaign_key,
        billing_month,
        adjustment_usd,
        reason,
        current_timestamp as meta_refreshed_at
    from stg_billing_adjustments

)

select * from final

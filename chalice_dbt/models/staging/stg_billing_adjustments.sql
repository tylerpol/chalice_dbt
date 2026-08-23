with billing_adjustments as (

    select * from {{ ref('billing_adjustments') }}

),

final as (

    select
        cast(campaign_id as varchar) as campaign_id,
        cast(billing_month as varchar) as billing_month,
        cast(adjustment_usd as decimal(18, 2)) as adjustment_usd,
        cast(reason as varchar) as reason
    from billing_adjustments

)

select * from final

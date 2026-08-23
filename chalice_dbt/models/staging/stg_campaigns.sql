with campaigns as (

    select * from {{ ref('campaigns') }}

),

final as (

    select
        cast(campaign_id as varchar) as campaign_id,
        cast(advertiser_id as varchar) as advertiser_id,
        cast(campaign_name as varchar) as campaign_name,
        cast(market as varchar) as market,
        cast(timezone as varchar) as timezone,
        cast(start_date as date) as start_date,
        cast(end_date as date) as end_date
    from campaigns

)

select * from final

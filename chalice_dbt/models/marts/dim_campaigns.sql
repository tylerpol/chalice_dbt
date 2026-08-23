with stg_campaigns as (

    select * from {{ ref('stg_campaigns') }}

),

final as (

    select
        md5(campaign_id) as campaign_key,
        campaign_id,
        md5(advertiser_id) as advertiser_key,
        advertiser_id,
        campaign_name,
        market,
        timezone,
        start_date,
        end_date,
        current_timestamp as meta_refreshed_at
    from stg_campaigns

)

select * from final

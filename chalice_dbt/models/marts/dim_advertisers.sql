with stg_advertisers as (

    select * from {{ ref('stg_advertisers') }}

),

final as (

    select
        md5(advertiser_id) as advertiser_key,
        advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        parent_advertiser_id,
        advertiser_name,
        current_timestamp as meta_refreshed_at
    from stg_advertisers

)

select * from final

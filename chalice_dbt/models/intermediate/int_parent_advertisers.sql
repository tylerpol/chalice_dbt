with stg_advertisers as (

    select * from {{ ref('stg_advertisers') }}

),

final as (

    select
        parent_advertiser_id,
        advertiser_name as parent_advertiser_name
    from stg_advertisers
    where advertiser_id = parent_advertiser_id

)

select * from final

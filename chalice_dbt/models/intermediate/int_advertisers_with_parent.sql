with stg_advertisers as (

    select * from {{ ref('stg_advertisers') }}

),

int_parent_advertisers as (

    select * from {{ ref('int_parent_advertisers') }}

),

final as (

    select
        advertisers.advertiser_id,
        advertisers.advertiser_name,
        advertisers.parent_advertiser_id,
        parents.parent_advertiser_name
    from stg_advertisers as advertisers
    left join int_parent_advertisers as parents
        on advertisers.parent_advertiser_id = parents.parent_advertiser_id

)

select * from final

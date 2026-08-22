with advertisers as (

    select * from {{ ref('advertisers') }}

),

final as (

    select
        cast(advertiser_id as varchar) as advertiser_id,
        cast(advertiser_name as varchar) as advertiser_name,
        cast(parent_advertiser_id as varchar) as parent_advertiser_id
    from advertisers

)

select * from final

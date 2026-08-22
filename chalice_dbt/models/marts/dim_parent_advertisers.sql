with int_parent_advertisers as (

    select * from {{ ref('int_parent_advertisers') }}

),

final as (

    select
        md5(parent_advertiser_id) as parent_advertiser_key,
        parent_advertiser_id,
        parent_advertiser_name,
        current_timestamp as meta_refreshed_at
    from int_parent_advertisers

)

select * from final

with int_advertisers_with_parent as (

    select * from {{ ref('int_advertisers_with_parent') }}

),

final as (

    select
        md5(advertiser_id) as advertiser_key,
        advertiser_id,
        md5(parent_advertiser_id) as parent_advertiser_key,
        parent_advertiser_id,
        advertiser_name,
        parent_advertiser_name,
        current_timestamp as meta_refreshed_at
    from int_advertisers_with_parent

)

select * from final

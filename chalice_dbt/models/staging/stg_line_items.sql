with line_items as (

    select * from {{ ref('line_items') }}

),

final as (

    select
        cast(line_item_id as varchar) as line_item_id,
        cast(campaign_id as varchar) as campaign_id,
        cast(pricing_model as varchar) as pricing_model,
        cast(rate as decimal(18, 4)) as rate,
        cast(contracted_impressions as bigint) as contracted_impressions,
        cast(discount_pct as decimal(18, 4)) as discount_pct,
        cast(flight_start as date) as flight_start,
        cast(flight_end as date) as flight_end
    from line_items

)

select * from final

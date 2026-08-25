with stg_line_items as (

    select * from {{ ref('stg_line_items') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

stg_campaigns as (

    select * from {{ ref('stg_campaigns') }}

),

int_advertisers_with_parent as (

    select * from {{ ref('int_advertisers_with_parent') }}

),

normalized as (

    select
        line_item_id,
        campaign_id,
        pricing_model,
        rate,
        contracted_impressions,
        discount_pct,
        cast(
            case
                when discount_pct is null then null
                when discount_pct > 1 then discount_pct / 100
                else discount_pct
            end as decimal(18, 6)
        ) as discount_rate,
        flight_start,
        flight_end,
        false as is_unmapped
    from stg_line_items

),

unmapped as (

    select distinct
        delivery.line_item_id,
        cast(null as varchar) as campaign_id,
        cast(null as varchar) as pricing_model,
        cast(null as decimal(18, 4)) as rate,
        cast(null as bigint) as contracted_impressions,
        cast(null as decimal(18, 4)) as discount_pct,
        cast(null as decimal(18, 6)) as discount_rate,
        cast(null as date) as flight_start,
        cast(null as date) as flight_end,
        true as is_unmapped
    from int_delivery_daily_deduplicated as delivery
    left join normalized
        on delivery.line_item_id = normalized.line_item_id
    where normalized.line_item_id is null

),

combined as (

    select * from normalized

    union all

    select * from unmapped

),

attributed as (

    select
        combined.*,
        campaigns.advertiser_id,
        advertisers.parent_advertiser_id
    from combined
    left join stg_campaigns as campaigns
        on combined.campaign_id = campaigns.campaign_id
    left join int_advertisers_with_parent as advertisers
        on campaigns.advertiser_id = advertisers.advertiser_id

),

final as (

    select
        *,
        -- Inclusive of both endpoints: 2026-04-01 to 2026-06-30 is 91 days.
        date_diff('day', flight_start, flight_end) + 1 as flight_days
    from attributed

)

select * from final

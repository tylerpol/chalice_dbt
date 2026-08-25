with int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

),

stg_campaigns as (

    select * from {{ ref('stg_campaigns') }}

),

int_advertisers_with_parent as (

    select * from {{ ref('int_advertisers_with_parent') }}

),

priced as (

    select
        delivery.line_item_id,
        delivery.event_date_local,
        delivery.impressions,
        delivery.clicks,
        delivery.media_cost_usd,
        delivery.billing_month,
        line_items.campaign_id,
        campaigns.advertiser_id,
        advertisers.parent_advertiser_id,
        line_items.pricing_model,
        cast(coalesce(line_items.discount_rate, 0) as decimal(18, 6)) as discount_rate,
        date_diff(
            'day',
            greatest(line_items.flight_start, date_trunc('month', delivery.event_date_local)),
            least(line_items.flight_end, last_day(delivery.event_date_local))
        ) + 1 as flight_days_in_month,
        case
            when line_items.pricing_model = 'CPM'
                then cast(
                    cast(delivery.impressions as decimal(18, 6)) / 1000 * line_items.rate as decimal(18, 6)
                )
            when line_items.pricing_model = 'FLAT_FEE'
                then cast(cast(line_items.rate as decimal(18, 6)) / nullif(
                    date_diff(
                        'day',
                        greatest(line_items.flight_start, date_trunc('month', delivery.event_date_local)),
                        least(line_items.flight_end, last_day(delivery.event_date_local))
                    ) + 1, 0
                ) as decimal(18, 6))
        end as gross_revenue_usd
    from int_delivery_daily_deduplicated as delivery
    left join int_line_items_normalized as line_items
        on delivery.line_item_id = line_items.line_item_id
    left join stg_campaigns as campaigns
        on line_items.campaign_id = campaigns.campaign_id
    left join int_advertisers_with_parent as advertisers
        on campaigns.advertiser_id = advertisers.advertiser_id

),

final as (

    select
        line_item_id,
        campaign_id,
        advertiser_id,
        parent_advertiser_id,
        event_date_local,
        strftime(date_trunc('month', event_date_local), '%Y-%m') as reporting_month,
        impressions,
        clicks,
        media_cost_usd,
        billing_month,
        pricing_model,
        flight_days_in_month,
        case
            when pricing_model = 'CPM' then 'CPM_DELIVERED'
            when pricing_model = 'FLAT_FEE' then 'FLAT_FEE_ALLOCATED'
        end as revenue_basis,
        gross_revenue_usd,
        discount_rate,
        cast(round(gross_revenue_usd * discount_rate, 6) as decimal(18, 6)) as discount_usd,
        gross_revenue_usd
        - cast(round(gross_revenue_usd * discount_rate, 6) as decimal(18, 6)) as net_revenue_usd
    from priced

)

select * from final

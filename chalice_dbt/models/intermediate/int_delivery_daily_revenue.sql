-- Revenue at the delivery grain, so the mart stays at the lowest level the data
-- supports and any monthly, campaign, or advertiser figure is a group-by rather
-- than a separate model.
--
-- Rule 1 (CPM): revenue = delivered impressions / 1000 * rate. Naturally daily.
--
-- Rule 2 (FLAT_FEE): the fee is recognised in full for each calendar month in
-- flight and is not a function of impressions. Its natural grain is the month,
-- so putting it on a daily row requires an allocation: the monthly rate is
-- spread evenly across the line item's *flight days in that month*, not across
-- its delivery rows. The denominator is contractual, so the daily figures always
-- sum back to exactly the monthly rate -- summing to the month reproduces rule 2
-- untouched. `revenue_basis` marks these rows as allocated so a reader is never
-- misled into treating a flat fee day as earned by that day's delivery.
--
-- The allocation is lossless only while every flight day has a delivery row. It
-- is today (30/30, 31/31, 30/30 for all five flat fee line items), and
-- `assert_flat_fee_revenue_matches_contract` fails the build if a gap ever makes
-- a month recognise less than its contracted rate.
--
-- Rule 3: the discount applies to gross revenue. Null means no discount, so it
-- is coalesced to 0. Mixed discount units are resolved upstream.
--
-- Money is stored as decimal to 6 places, not rounded to cents and not a float.
-- Cents are too coarse: a daily flat fee share can be 833.333333, and rounding
-- that to 833.33 would lose two cents a month. Float would be precise enough but
-- money in a warehouse should not be approximate -- decimal keeps every figure
-- exact and reproducible. Six places means a flat fee month sums back to its
-- contracted rate exactly to the cent, which is the precision money is reported
-- in; the sub-cent residue of dividing by 30 is unrepresentable in any decimal
-- scale. Round to cents at the grain you report on.
--
-- The join is a left join so delivery for a line item with no pricing terms
-- (LI-5999) keeps its row with null revenue rather than vanishing.

with int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

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

),

final as (

    select
        line_item_id,
        campaign_id,
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

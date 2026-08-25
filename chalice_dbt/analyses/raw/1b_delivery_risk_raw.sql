-- 1b. Delivery risk -- RAW VERSION
--
-- Plain SQL. Run it directly against the DuckDB file; nothing here is templated.
--
-- Same answer as analyses/mart/1b_delivery_risk_mart.sql, built from the raw seeds.
-- The pacing arithmetic the warehouse holds on fct_line_items has to be
-- rebuilt here:
--   * flights are inclusive of both endpoints (2026-04-01 to 2026-06-30 is 91
--     days, not 90) -- an off-by-one moves every ratio
--   * elapsed share is capped at 1 for flights that closed before the as-of date
--   * only delivery on or before the as-of date counts, so both sides of the
--     comparison are as-of the same moment
--   * delivery is deduplicated first; the 24 duplicate rows would otherwise
--     flatter pacing by counting 372,942 impressions twice
--   * discount_pct is normalised before it touches revenue at risk

with delivery_daily as (

    select * from raw.delivery_daily

),

line_items_raw as (

    select * from raw.line_items

),

campaigns as (

    select * from raw.campaigns

),

deduped as (

    select distinct * from delivery_daily

),

line_items as (

    select
        line_item_id,
        campaign_id,
        pricing_model,
        rate,
        contracted_impressions,
        flight_start,
        flight_end,
        coalesce(
            case when discount_pct > 1 then discount_pct / 100 else discount_pct end, 0
        ) as discount_rate
    from line_items_raw

),

delivered as (

    select
        line_item_id,
        sum(impressions) as delivered_impressions
    from deduped
    where event_date_local <= date '2026-06-30'
    group by 1

),

pacing as (

    select
        line_items.line_item_id,
        line_items.campaign_id,
        line_items.rate,
        line_items.discount_rate,
        line_items.contracted_impressions,
        coalesce(delivered.delivered_impressions, 0) as delivered_impressions,
        date_diff('day', line_items.flight_start, line_items.flight_end) + 1 as flight_days,
        greatest(
            0,
            date_diff(
                'day', line_items.flight_start, least(date '2026-06-30', line_items.flight_end)
            ) + 1
        ) as elapsed_days
    from line_items
    left join delivered
        on line_items.line_item_id = delivered.line_item_id
    where
        line_items.pricing_model = 'CPM'
        and line_items.contracted_impressions is not null

),

expected as (

    select
        *,
        cast(round(
            contracted_impressions * least(
                cast(1 as decimal(18, 10)),
                cast(cast(elapsed_days as decimal(18, 10)) / nullif(flight_days, 0) as decimal(18, 10))
            ), 0
        ) as bigint) as expected_impressions_to_date,
        least(
            cast(1 as decimal(18, 10)),
            cast(cast(elapsed_days as decimal(18, 10)) / nullif(flight_days, 0) as decimal(18, 10))
        ) as elapsed_share
    from pacing

),

final as (

    select
        expected.line_item_id,
        coalesce(campaigns.campaign_name, '(no campaign on line item)') as campaign_name,
        cast('2026-06-30' as date) as pacing_as_of_date,
        expected.contracted_impressions,
        expected.expected_impressions_to_date,
        expected.delivered_impressions,
        round(expected.elapsed_share, 4) as flight_elapsed_share,
        -- Cast back to decimal: DuckDB promotes this division to DOUBLE, and
        -- the warehouse stores it as decimal, so without this the two versions
        -- agree in value but differ in type.
        round(cast(
            cast(expected.delivered_impressions as decimal(18, 6))
            / nullif(expected.expected_impressions_to_date, 0) as decimal(18, 6)
        ), 4) as pacing_ratio,
        greatest(
            0, expected.expected_impressions_to_date - expected.delivered_impressions
        ) as shortfall_to_date,
        greatest(
            0, expected.contracted_impressions - expected.delivered_impressions
        ) as shortfall_full_contract,
        round(cast(
            cast(greatest(
                0, expected.contracted_impressions - expected.delivered_impressions
            ) as decimal(18, 6)) / 1000 * expected.rate
            * (1 - expected.discount_rate) as decimal(18, 6)
        ), 2) as revenue_at_risk_usd
    from expected
    left join campaigns
        on expected.campaign_id = campaigns.campaign_id

)

select * from final
order by revenue_at_risk_usd desc, pacing_ratio asc

-- Escalation reasoning is identical to the mart version; see
-- analyses/mart/1b_delivery_risk_mart.sql.

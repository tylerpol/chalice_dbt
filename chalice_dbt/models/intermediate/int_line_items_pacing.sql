with int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

as_of as (

    -- Fixed rather than current_date so the figures are reproducible.
    -- A second row here is all it takes to hold history.
    select cast('2026-06-30' as date) as pacing_as_of_date

),

contract as (

    select
        line_items.*,
        as_of.pacing_as_of_date
    from int_line_items_normalized as line_items
    cross join as_of

),

delivered as (

    select
        delivery.line_item_id,
        as_of.pacing_as_of_date,
        sum(delivery.impressions) as delivered_impressions_to_date
    from int_delivery_daily_deduplicated as delivery
    cross join as_of
    where delivery.event_date_local <= as_of.pacing_as_of_date
    group by 1, 2

),

elapsed as (

    select
        *,
        greatest(
            0,
            date_diff(
                'day', flight_start,
                least(pacing_as_of_date, flight_end)
            ) + 1
        ) as elapsed_days
    from contract

),

share as (

    select
        *,
        least(
            cast(1 as decimal(18, 10)),
            cast(
                cast(elapsed_days as decimal(18, 10))
                / nullif(flight_days, 0) as decimal(18, 10)
            )
        ) as elapsed_share
    from elapsed

),

expectation as (

    select
        share.*,
        coalesce(delivered.delivered_impressions_to_date, 0) as delivered_impressions_to_date,
        cast(
            round(share.contracted_impressions * share.elapsed_share, 0) as bigint
        ) as expected_impressions_to_date
    from share
    left join delivered
        on
            share.line_item_id = delivered.line_item_id
            and share.pacing_as_of_date = delivered.pacing_as_of_date

),

final as (

    select
        *,
        cast(
            cast(delivered_impressions_to_date as decimal(18, 6))
            / nullif(expected_impressions_to_date, 0) as decimal(18, 6)
        ) as pacing_ratio,
        -- greatest(0, null) returns 0 in DuckDB, so guard on the contract to
        -- keep "no commitment" reading as null rather than a confident zero.
        case
            when contracted_impressions is null then null
            else greatest(0, expected_impressions_to_date - delivered_impressions_to_date)
        end as shortfall_to_date_impressions,
        case
            when contracted_impressions is null then null
            else greatest(0, contracted_impressions - delivered_impressions_to_date)
        end as shortfall_full_contract_impressions,
        case
            when contracted_impressions is null then null
            else cast(
                cast(greatest(
                    0, contracted_impressions - delivered_impressions_to_date
                ) as decimal(18, 6)) / 1000 * rate
                * (1 - coalesce(discount_rate, 0)) as decimal(18, 6)
            )
        end as revenue_at_risk_usd
    from expectation

)

select * from final

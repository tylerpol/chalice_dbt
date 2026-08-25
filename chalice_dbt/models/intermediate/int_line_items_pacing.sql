-- Rule 6: pacing against contract, pro-rated to the elapsed flight.
--
-- This is a *measurement*, not an attribute. Every column here is a function of
-- two things the contract does not know: what has been delivered, and the date
-- you are asking about. That is what separates it from
-- `int_line_items_normalized`, which holds the contract terms alone, and what
-- makes `fct_line_items` a fact.
--
-- Grain: one row per line item per as-of date. Only one as-of date exists today,
-- which is exactly why the grain has to be stated -- add a second snapshot and a
-- model that assumed one row per line item silently starts fanning out.
--
-- Campaign, advertiser and parent advertiser arrive already resolved on
-- `int_line_items_normalized`, so this model inherits the identical key chain
-- that `dim_line_items` exposes rather than re-deriving one that could disagree.
--
-- Pacing decisions the rule does not cover:
--   * Elapsed share is capped at 1: a flight that closed before the as-of date is
--     fully elapsed, one that had not started is 0.
--   * Line items with no impression commitment (every FLAT_FEE one) get a null
--     expectation, not zero. Null means "not applicable"; zero would mean
--     "expected nothing", which is a different claim.
--   * Two shortfalls are carried because they answer different questions.
--     `shortfall_to_date_impressions` is delivered against what the contract
--     expects by the as-of date -- that is what "behind" means, and it is what
--     pacing_ratio measures. `shortfall_full_contract_impressions` is delivered
--     against the whole commitment, and it drives `revenue_at_risk_usd` because
--     that is what goes unearned if nothing more delivers. For a flight that has
--     already closed the two are equal; they differ only for a line item still
--     in flight, where conflating them counts unelapsed flight as already missed.
--   * Revenue at risk is net of the line item's discount: an unearned impression
--     would have billed at the discounted rate, not the rack rate.

with int_line_items_normalized as (

    select * from {{ ref('int_line_items_normalized') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

as_of as (

    -- Pacing is evaluated as of the date in the brief rather than current_date,
    -- so the numbers are reproducible. Declared once, here, as the grain of the
    -- model rather than as a project variable a reader would have to go looking
    -- for. Adding a second row to this CTE is all it takes to hold history.
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
        contract.*,
        greatest(
            0,
            date_diff(
                'day', contract.flight_start,
                least(contract.pacing_as_of_date, contract.flight_end)
            ) + 1
        ) as elapsed_days
    from contract

),

share as (

    select
        elapsed.*,
        least(
            cast(1 as decimal(18, 10)),
            cast(
                cast(elapsed.elapsed_days as decimal(18, 10))
                / nullif(elapsed.flight_days, 0) as decimal(18, 10)
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
        on share.line_item_id = delivered.line_item_id
        and share.pacing_as_of_date = delivered.pacing_as_of_date

),

final as (

    select
        *,
        cast(
            cast(delivered_impressions_to_date as decimal(18, 6))
            / nullif(expected_impressions_to_date, 0) as decimal(18, 6)
        ) as pacing_ratio,
        -- greatest() ignores nulls in DuckDB, so greatest(0, null) returns 0.
        -- Guarding on the contract explicitly keeps "no impression commitment"
        -- reading as null rather than as a confident zero shortfall.
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

-- `discount_pct` arrives in two different units in the same column: most rows
-- express a fraction (0.05, 0.1, 0.15, 0.2) while others express whole
-- percentage points (5.0, 12.0). Left as-is, a 5% discount would be applied as
-- 500%. This model resolves both to a single fractional `discount_rate`.
--
-- The rule -- values above 1 are percentage points -- is a heuristic, not a
-- guarantee from the source. It is unambiguous for the values present today but
-- would misread a literal 100% discount (1.0 stays 1.0, correctly) or a genuine
-- 0.05 percentage-point discount. Revisit if the source ever documents a unit.
--
-- This model also adds an *inferred member* for every line item that delivers but
-- is absent from the line-item extract (today: LI-5999, 20 delivery rows,
-- $1,859.74). The spine is derived from delivery, never hardcoded, so a new
-- orphan is absorbed automatically. Inferred rows carry `is_unmapped = true` and
-- null attributes; they exist so the delivery fact's foreign key always resolves
-- and unmapped spend lands on a labelled member rather than a null. The anomaly
-- is not silenced -- dim_line_items tests the count against a known baseline.
--
-- This model also derives the contract-side half of pacing (rule 6): how long
-- the flight is, how much of it had elapsed at the as-of date, and how many
-- impressions the contract therefore expects by then. Delivered impressions stay
-- in the fact where they belong, so the pacing index is a division at report
-- time -- see the dim_line_items doc for the query.
--
-- Pacing decisions the rule does not cover:
--   * Flights are inclusive of both endpoints, so 2026-04-01 to 2026-06-30 is 91
--     days, not 90. An off-by-one here shifts every pacing index.
--   * Elapsed share is capped at 1: a flight that closed before the as-of date is
--     fully elapsed, one that had not started is 0.
--   * Line items with no impression commitment (every FLAT_FEE one) get a null
--     expectation, not zero. Null means "not applicable"; zero would mean
--     "expected nothing", which is a different claim.

with stg_line_items as (

    select * from {{ ref('stg_line_items') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

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
        -- Pacing is evaluated as of the date in the brief rather than
        -- current_date, so the numbers are reproducible. Declared here, in the
        -- only model that uses it, rather than as a project variable a reader
        -- would have to go looking for.
        cast('2026-06-30' as date) as pacing_as_of_date,
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
        cast('2026-06-30' as date) as pacing_as_of_date,
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

elapsed as (

    select
        *,
        date_diff('day', flight_start, flight_end) + 1 as flight_days,
        greatest(
            0, date_diff('day', flight_start, least(pacing_as_of_date, flight_end)) + 1
        ) as elapsed_days
    from combined

),

final as (

    select
        *,
        least(
            cast(1 as decimal(18, 10)),
            cast(cast(elapsed_days as decimal(18, 10)) / nullif(flight_days, 0) as decimal(18, 10))
        ) as elapsed_share,
        cast(round(
            contracted_impressions
            * least(
                cast(1 as decimal(18, 10)),
                cast(cast(elapsed_days as decimal(18, 10)) / nullif(flight_days, 0) as decimal(18, 10))
            ), 0
        ) as bigint) as expected_impressions_to_date
    from elapsed

)

select * from final

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
-- This model also adds an *inferred member* for every line item that delivers
-- but is absent from the line-item extract (today: LI-5999, 20 delivery rows,
-- $1,859.74). The spine is derived from delivery, never hardcoded, so a new
-- orphan is absorbed automatically. Inferred rows carry `is_unmapped = true`
-- and null attributes; they exist so the fact table's foreign key always
-- resolves and unmapped spend lands on a labelled member rather than a null.
-- The anomaly is not silenced -- `is_unmapped` is tested at warn severity.

with stg_line_items as (

    select * from {{ ref('stg_line_items') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

sourced as (

    select
        line_item_id,
        campaign_id,
        pricing_model,
        rate,
        contracted_impressions,
        discount_pct,
        case
            when discount_pct is null then null
            when discount_pct > 1 then discount_pct / 100
            else discount_pct
        end as discount_rate,
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
        cast(null as decimal(18, 4)) as discount_rate,
        cast(null as date) as flight_start,
        cast(null as date) as flight_end,
        true as is_unmapped
    from int_delivery_daily_deduplicated as delivery
    left join sourced
        on delivery.line_item_id = sourced.line_item_id
    where sourced.line_item_id is null

),

final as (

    select * from sourced

    union all

    select * from unmapped

)

select * from final

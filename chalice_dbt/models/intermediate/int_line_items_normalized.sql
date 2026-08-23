-- `discount_pct` arrives in two different units in the same column: most rows
-- express a fraction (0.05, 0.1, 0.15, 0.2) while others express whole
-- percentage points (5.0, 12.0). Left as-is, a 5% discount would be applied as
-- 500%. This model resolves both to a single fractional `discount_rate`.
--
-- The rule -- values above 1 are percentage points -- is a heuristic, not a
-- guarantee from the source. It is unambiguous for the values present today but
-- would misread a literal 100% discount (1.0 stays 1.0, correctly) or a genuine
-- 0.05 percentage-point discount. Revisit if the source ever documents a unit.

with stg_line_items as (

    select * from {{ ref('stg_line_items') }}

),

final as (

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
        flight_end
    from stg_line_items

)

select * from final

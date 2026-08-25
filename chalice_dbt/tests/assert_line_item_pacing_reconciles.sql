-- fct_line_items carries `delivered_impressions_to_date`, which is an aggregate
-- of fct_delivery_daily rather than an independent measurement. A copy of an
-- aggregate can drift -- if the two models are ever built from different
-- snapshots, or if the as-of filter changes on one side only, the pacing ratio
-- keeps returning a confident number that no longer reconciles to delivery.
--
-- This test recomputes the aggregate from the delivery fact and fails on any
-- disagreement. It also re-derives pacing_ratio, so a change to the arithmetic
-- in one place and not the other cannot pass silently.

with delivered_from_fact as (

    select
        pacing.line_item_id,
        pacing.pacing_as_of_date,
        sum(delivery.impressions) as recomputed_impressions
    from {{ ref('fct_line_items') }} as pacing
    left join {{ ref('fct_delivery_daily') }} as delivery
        on
            pacing.line_item_id = delivery.line_item_id
            and pacing.pacing_as_of_date >= delivery.event_date_local
    group by 1, 2

),

compared as (

    select
        pacing.line_item_id,
        pacing.delivered_impressions_to_date,
        coalesce(delivered_from_fact.recomputed_impressions, 0) as recomputed_impressions,
        pacing.pacing_ratio,
        cast(
            cast(pacing.delivered_impressions_to_date as decimal(18, 6))
            / nullif(pacing.expected_impressions_to_date, 0) as decimal(18, 6)
        ) as recomputed_ratio
    from {{ ref('fct_line_items') }} as pacing
    left join delivered_from_fact
        on
            pacing.line_item_id = delivered_from_fact.line_item_id
            and pacing.pacing_as_of_date = delivered_from_fact.pacing_as_of_date

)

select *
from compared
where
    delivered_impressions_to_date is distinct from recomputed_impressions
    or pacing_ratio is distinct from recomputed_ratio

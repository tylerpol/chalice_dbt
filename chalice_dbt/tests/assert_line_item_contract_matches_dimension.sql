-- fct_line_items carries `contracted_impressions` as well as dim_line_items,
-- because it is the basis every pacing measure is calculated against and a
-- pacing row is unreadable without it. Two copies of one figure can diverge, so
-- this asserts they never do.

select
    pacing.line_item_id,
    pacing.contracted_impressions as fact_contracted_impressions,
    line_items.contracted_impressions as dimension_contracted_impressions
from {{ ref('fct_line_items') }} as pacing
inner join {{ ref('dim_line_items') }} as line_items
    on pacing.line_item_key = line_items.line_item_key
where pacing.contracted_impressions is distinct from line_items.contracted_impressions

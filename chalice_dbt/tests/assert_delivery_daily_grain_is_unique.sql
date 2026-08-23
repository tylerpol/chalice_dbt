-- The intermediate layer's job is to establish a true one-row-per-line-item-per-day
-- grain by collapsing the exact duplicate rows present in the source. This asserts
-- that collapse actually held: any (line_item_id, event_date_local) appearing more
-- than once means duplicates survived, or that conflicting (non-identical)
-- restatements have appeared in the source and `distinct` is no longer sufficient.

select
    line_item_id,
    event_date_local,
    count(*) as row_count
from {{ ref('int_delivery_daily_deduplicated') }}
group by 1, 2
having count(*) > 1

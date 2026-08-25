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
-- Everything here is a property of the *contract*: what was agreed, for how much,
-- over which dates. Nothing in this model depends on what was delivered or on
-- when you ask. Pacing -- which needs both -- lives in `int_line_items_pacing`,
-- and `flight_days` is the one piece of flight arithmetic that belongs here
-- because it is a function of the flight dates alone.
--
-- Campaign, advertiser and parent advertiser are resolved here once, so that
-- `dim_line_items` and `fct_line_items` carry the identical key chain and a
-- reader can group either by brand without a three-table join. Resolving it in
-- one place is what keeps the two models from disagreeing.

with stg_line_items as (

    select * from {{ ref('stg_line_items') }}

),

int_delivery_daily_deduplicated as (

    select * from {{ ref('int_delivery_daily_deduplicated') }}

),

stg_campaigns as (

    select * from {{ ref('stg_campaigns') }}

),

int_advertisers_with_parent as (

    select * from {{ ref('int_advertisers_with_parent') }}

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

attributed as (

    select
        combined.*,
        campaigns.advertiser_id,
        advertisers.parent_advertiser_id
    from combined
    left join stg_campaigns as campaigns
        on combined.campaign_id = campaigns.campaign_id
    left join int_advertisers_with_parent as advertisers
        on campaigns.advertiser_id = advertisers.advertiser_id

),

final as (

    select
        *,
        -- Flights are inclusive of both endpoints, so 2026-04-01 to 2026-06-30
        -- is 91 days, not 90. An off-by-one here shifts every pacing index.
        date_diff('day', flight_start, flight_end) + 1 as flight_days
    from attributed

)

select * from final

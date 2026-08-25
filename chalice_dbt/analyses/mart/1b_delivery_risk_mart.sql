-- 1b. Delivery risk -- MART VERSION
--
-- Plain SQL. Run it directly against the DuckDB file; nothing here is templated.
--
-- CPM line items pacing worst against contract, with the revenue that never gets
-- earned if the shortfall is never made up.
--
-- The pacing arithmetic lives in the warehouse, on fct_line_items: the as-of
-- date, the elapsed share of the flight, the contract pro-rated to it, delivered
-- impressions as of that date, both shortfalls and the revenue at risk. The
-- contract terms it is measured against -- pricing model and contracted volume --
-- are on dim_line_items, one join away. This query selects and formats; it
-- derives nothing. That also means the as-of date is not hardcoded here -- it
-- comes from the model, and pacing_as_of_date is returned so a reader can see
-- what the numbers are relative to.
--
-- Only CPM line items appear. Flat fee line items carry no impression
-- commitment, so every pacing column is null for them -- not zero, which would
-- make them look infinitely behind.
--
-- Two shortfalls, because they answer different questions:
--   * to-date       -- delivered vs what the contract expects by the as-of date.
--                      This is the pacing ratio, and it is what "behind" means.
--   * full contract -- delivered vs the whole commitment. This drives revenue at
--                      risk, because it is what goes unearned if nothing more
--                      delivers.
-- For a closed flight the two are equal. They differ only for LI-5016, which is
-- still in flight, and conflating them overstates its risk by treating unelapsed
-- flight as already missed.
--
-- Ranked by revenue at risk, not by pacing ratio -- see the notes at the bottom.
--
-- Ties to analyses/raw/1b_delivery_risk_raw.sql.

select
    line_items.line_item_id,
    coalesce(campaigns.campaign_name, '(no campaign on line item)') as campaign_name,
    pacing.pacing_as_of_date,
    line_items.contracted_impressions,
    pacing.expected_impressions_to_date,
    pacing.delivered_impressions_to_date as delivered_impressions,
    round(pacing.elapsed_share, 4) as flight_elapsed_share,
    round(pacing.pacing_ratio, 4) as pacing_ratio,
    pacing.shortfall_to_date_impressions as shortfall_to_date,
    pacing.shortfall_full_contract_impressions as shortfall_full_contract,
    round(pacing.revenue_at_risk_usd, 2) as revenue_at_risk_usd
from mart.fct_line_items as pacing
inner join mart.dim_line_items as line_items
    on pacing.line_item_key = line_items.line_item_key
left join mart.dim_campaigns as campaigns
    on pacing.campaign_key = campaigns.campaign_key
where line_items.pricing_model = 'CPM'
    and line_items.contracted_impressions is not null
order by revenue_at_risk_usd desc, pacing_ratio asc

-- ESCALATION
--
-- Rank by dollars at risk, not by pacing ratio. The ratio says how badly a line
-- item is missing; the dollars say whether anyone should care, and the two
-- diverge sharply here because contract sizes span 600k to 5M impressions and
-- rates span $6.75 to $16.00 CPM.
--
-- LI-5011 paces at 0.632 and risks $2,649.81. LI-5010 paces at 0.854 -- far
-- healthier -- and risks $6,649.60, two and a half times as much, because its
-- contract is 3.5x larger. A list sorted by ratio puts LI-5011 near the top and
-- buries LI-5010 in the middle, which sends the account team after the smaller
-- problem.
--
-- Escalate now, in this order:
--   1. LI-5002  (Northgate Q2 Auto Prospecting)  0.572 / $7,702.75
--      The worst ratio in the book AND the largest realised miss. Flight closed
--      2026-06-30, so this is not a warning -- 43% of contract was never
--      delivered and the revenue is gone.
--   2. LI-5010  (Kestrel Q2 Acquisition)         0.854 / $6,649.60
--      Escalates purely on size. A 15% miss on a 3.5M contract at $13.00 CPM
--      outweighs much uglier ratios elsewhere.
--   3. LI-5003  (Northgate Q2 Retention)         0.633 / $5,171.52
--      Closed flight missing 37% of contract. Second Northgate line item in the
--      top three, which makes this an advertiser-level conversation rather than
--      a line-item one.
--   4. LI-5009  (Vero Open Enrollment Warmup)    0.822 / $4,022.87
--   5. LI-5006 / LI-5005                         $3,247.30 / $3,210.51
--      Nearly identical dollars from opposite causes: LI-5006 is a 9% miss on a
--      5M contract, LI-5005 a 38% miss on 900k. Same exposure, different fix.
--
-- Do NOT escalate on ratio alone:
--   * LI-5016 tops the list at $11,356.04 and should not be treated as a miss.
--     Its flight runs to 2026-07-31 and only 49% has elapsed, so its
--     full-contract shortfall of 1,195,373 impressions counts a month that has
--     not happened yet. Against what the contract actually expects by the as-of
--     date it is short 178,980 -- a 0.818 ratio, mid-pack. Watch it; escalating
--     it as the worst account in the book would be wrong.
--   * LI-5105 has the second-worst ratio (0.577) and $4,883.81 at risk, but
--     carries no campaign_id, so there is no advertiser and no account owner to
--     escalate TO. The action here is fixing the mapping, not a delivery call.
--     See defect 6 in the data quality register.
--   * LI-5001 (1.039), LI-5012 (1.037) and LI-5015 (1.052) are OVER-delivering
--     against contract. Zero revenue at risk, but LI-5001 alone has served
--     155,814 impressions beyond its commitment -- unbilled inventory, which is
--     a real margin leak and the mirror image of this report.

# Business Rules

The six revenue and pacing rules as implemented, and every decision taken where a
rule was silent on a case the data actually contains.

Model conventions live in [AGENTS.md](../../AGENTS.md); layer rules live in each
layer's `__[layer]_layer.md`. This file covers only business logic.

---

## Where each rule is implemented

No rule gets its own mart. The mart stays at the lowest grain the data supports —
delivery day for facts, line item for the dimension — and every summary above
that is a group-by. Helper columns exist to make those group-bys trivial.

| # | Rule | Implemented in | Summarise via |
|---|------|----------------|---------------|
| 1 | CPM revenue = impressions / 1000 × rate | `int_delivery_daily_revenue` | `fct_delivery_daily.gross_revenue_usd` |
| 2 | Flat fee = rate, in full per calendar month in flight, not impression-based | `int_delivery_daily_revenue` | sum by `reporting_month` |
| 3 | Discounts apply to gross revenue | `int_delivery_daily_revenue`; units resolved in `int_line_items_normalized` | `discount_usd`, `net_revenue_usd` |
| 4 | Adjustments at campaign and month level, added after discounted revenue | not modelled — applied at report time | join `fct_billing_adjustments` on `campaign_id` + month |
| 5 | Reporting month is the month delivery actually occurred | `int_delivery_daily_revenue` | `fct_delivery_daily.reporting_month` |
| 6 | Pacing vs contract, pro-rated to elapsed flight as of 2026-06-30 | `int_line_items_normalized` | `dim_line_items.expected_impressions_to_date` |

Worked queries for the monthly, campaign-billing, and pacing summaries are in the
`fct_delivery_daily` and `dim_line_items` doc blocks.

---

## Decisions where the rules are silent

### 1. Flat fee revenue is allocated across flight days to reach the delivery grain

Rule 2 fixes flat fee revenue at the **month**, which is above the mart's grain.
Putting it on a daily row requires an allocation, and there is no rule for one.
**Decision: the monthly rate is spread evenly across the line item's flight days
in that month.** The denominator is contractual — flight days, not delivery rows
— so summing a month reproduces the contracted rate exactly and rule 2 is
recovered untouched at the grain it is actually stated for.

`revenue_basis = 'FLAT_FEE_ALLOCATED'` marks these rows so no reader mistakes an
allocated day for one that earned its revenue.
`assert_flat_fee_revenue_matches_contract` fails the build if any flat fee month
stops summing to its rate.

The alternative was a monthly revenue model alongside the daily one. Rejected:
two facts at different grains covering the same money is the more expensive
mistake, and it pushes every consumer into choosing which one to trust.

### 2. Allocation assumes every flight day has a delivery row

It does today — 30/30, 31/31, 30/30 for all five flat fee line items — but that
is a property of this dataset, not a guarantee. **Decision: allocate anyway, and
pin the result with a test** rather than defending against a gap that does not
exist. If one appears, the month under-recognises and the test says so.

### 3. A partial calendar month of flight is recognised in full

Rule 2 says "each calendar month the line item is in flight" without addressing a
flight starting or ending mid-month. **Decision: any overlap recognises the full
rate.** Every flat fee flight here is whole months, so this changes nothing
today; it is recorded because the rule is silent and the next dataset may not be.

### 4. Money is decimal to six places, rounded only at the reporting grain

No rule addresses rounding. **Decision: store `decimal(18,6)`; round to cents
after aggregating.** Cents are too coarse at the delivery grain — a daily flat
fee share can be `833.333333`, and rounding it to `833.33` loses two cents a
month. Float is precise enough but money should not be approximate; decimal keeps
every figure exact and reproducible. Six places makes a flat fee month sum back
to its rate exactly to the cent, which is the precision money is reported in.

Consequence: a pipeline that rounds at a different grain will differ by cents.
Rounding gross at line item × month before discounting, for instance, gives
$565,766.81 rather than $565,766.83.

### 5. Net revenue is derived by subtraction

**Decision: `net = gross − discount`, not `gross × (1 − rate)`.** Computed
independently the two can disagree by a cent, and a revenue table whose own
columns do not add up cannot be defended. Holds on every row.

### 6. A null discount means no discount

Rule 3 does not say what a null `discount_pct` means. **Decision: coalesced to
0.** Treating null as unknown and nulling revenue would discard the revenue of
the 15 of 22 line items that simply have no discount.

### 7. Discount units are normalised before the rule is applied

Rule 3 notes the field "was entered by humans in an operational tool over several
years" — the brief flagging a dirty column. It is: most rows hold a fraction
(`0.1`), some hold whole percentage points (`12.0`), in the same column. Applied
as-is, a 12% discount becomes 1200%. **Decision: values above 1 are percentage
points and are divided by 100.** A heuristic, not a guarantee — it would misread
a genuine 100% discount — and documented as such at the model.

### 8. Adjustments are not modelled, only documented

Rule 4 fixes adjustments at campaign and month. There is no basis in the rules
for allocating a campaign-level adjustment down to a line item or a day, and any
split — by revenue share, by impressions, evenly — would be invented.
**Decision: `fct_delivery_daily` carries discounted revenue and never
adjustments.** `fct_billing_adjustments` already sits at exactly the campaign ×
month grain the rule specifies; billable revenue is the join of the two, shown in
the `fct_delivery_daily` doc.

Use a **full outer join**: a campaign month can carry an adjustment with no
delivery behind it, and an inner join would silently drop real billed value.
Adjustments are net negative (−$8,689.90 across 25 rows) and one can exceed the
revenue it applies to, so **billed revenue can go negative — do not clamp it.**

### 9. Revenue with no campaign stays in the fact and is not hidden

Two line items (`LI-5105`, `LI-5106`) carry no `campaign_id`, so **$33,666.19 of
net revenue cannot be attributed to a campaign.** **Decision: those rows stay in
`fct_delivery_daily` with a null `campaign_id`.** Any campaign-level rollup must
decide what to do with them; the total will be $532,100.64 rather than
$565,766.83. The discrepancy is visible and reconcilable rather than silently
dropped upstream.

### 10. Negative impressions are summed as recorded, not clamped

Six delivery rows carry negative impressions and six have more clicks than
impressions. Rule 1 addresses delivered impressions and not corrections.
**Decision: sum as recorded.** They appear to be corrections meant to net out
monthly; clamping would restate delivery and overstate revenue. A negative CPM
day is therefore possible and correct.

### 11. `billing_month` is not used for revenue recognition

Rule 5 says the reporting month is the month delivery actually occurred, and the
source `billing_month` disagrees with `event_date_local` on 24 rows.
**Decision: `reporting_month` is derived from `event_date_local`.**
`billing_month` is retained for traceability and to match adjustments, which are
recorded at that grain. A report built on one will not tie to the other.

### 12. Flights are inclusive of both endpoints

Rule 6 does not define flight length. **Decision: 2026-04-01 to 2026-06-30 is 91
days, not 90.** An off-by-one shifts every pacing index.

### 13. Elapsed share is capped at [0, 1]

**Decision: a flight closed before the as-of date is fully elapsed; one not yet
started is 0.** Uncapped, a closed flight would read as over 100% elapsed and
understate pacing.

### 14. Pacing is null, not zero, where there is no contract

Flat fee line items carry no `contracted_impressions` — they are not
impression-based. **Decision: `expected_impressions_to_date` is null for them.**
Zero would make every flat fee line item look infinitely ahead of pace.

### 15. Delivered impressions are not stored on the dimension

Pacing needs a contract expectation and a delivered total. **Decision: the
dimension carries only the contract side; delivered impressions stay in the fact
and the index is a division at report time.** Putting a measure on a dimension
would break the fact/dim separation and freeze a number that changes with every
delivery load.

### 16. The as-of date is a literal in the model that uses it

**Decision: `cast('2026-06-30' as date)`, declared inline in
`int_line_items_normalized`.** Fixed rather than `current_date` so pacing is
reproducible and matches the brief. It was briefly a project variable; that made
a reviewer jump to `dbt_project.yml` to find a value used in exactly one place,
which is worse for reading even though it is more configurable.

### 17. Line items with no pricing terms earn no revenue

`LI-5999` appears in delivery (637,596 impressions, $1,859.74 of media cost) but
not in the line-item source, so it has no rate and no pricing model.
**Decision: its revenue columns are null**, and its delivery rows are kept via a
left join rather than dropped. Delivery and revenue totals will not tie for it,
by design.

---

## Headline figures

Pacing as of **2026-06-30**. Money rounded to cents at the total grain.

| Measure | Amount |
|---|---|
| Gross revenue | $587,161.38 |
| Discounts | −$21,394.55 |
| **Net revenue** | **$565,766.83** |
| Of which attributable to a campaign | $532,100.64 |
| Of which unattributable | $33,666.19 |
| Adjustments | −$8,689.90 |
| **Billed revenue** (campaign-attributed + adjustments) | **$523,410.74** |

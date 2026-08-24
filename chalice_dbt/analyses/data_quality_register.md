# Data Quality Register

Every defect found in the Q2 2026 take-home data, with how it was detected, what
it does to the numbers in 1a and 1b, how it was handled, and where the real fix
belongs.

Magnitudes are against **Q2 2026 recognised revenue of $565,766.83 net**
($587,161.38 gross less $21,394.55 discounts), before adjustments of −$8,689.90.

Queries: `analyses/mart/` (warehouse) and `analyses/raw/` (raw seeds). Both
versions return identical results; 1b is byte-identical and 1a matches on all 25
rows.

---

## Summary

| # | Defect | Impact if unhandled | Handled | Real fix |
|---|--------|--------------------|---------|----------|
| 1 | 24 byte-identical delivery rows | **+$3,142.57** revenue | Model | Upstream |
| 2 | `discount_pct` mixes fractions and percentage points | **−$296,677.46** revenue | Model | Upstream |
| 3 | `LI-5999` delivers but has no line item | $1,859.74 cost dropped on inner join | Model | Upstream |
| 4 | `billing_month` disagrees with `event_date_local` | **$3,193.42** in wrong month | Model | Upstream |
| 5 | 6 rows with negative impressions | −$709.96 revenue | Kept as recorded | Upstream |
| 6 | 2 line items with no `campaign_id` | **$33,666.19** unattributable | Surfaced | Upstream |
| 7 | 7 advertiser rows are 5 brands | **$105,411.52** split across wrong lines | Query | Upstream |
| 8 | Flat fee lines have no impression contract | Excluded from pacing | Model | Not a defect |
| 9 | 5 timezones on one local date column | Unquantifiable | Documented | Upstream |

---

## 1. Twenty-four byte-identical duplicate rows in `delivery_daily`

**What it is.** `raw.delivery_daily` holds 1,985 rows; 1,961 are distinct. The 24
extras repeat another row in *every* column — not a restatement, a duplicate
load. They carry **372,942 impressions** and **$1,183.41 of media cost**.

**How I detected it.** `count(*)` against
`count(*) from (select distinct * from raw.delivery_daily)`. The grain claim
(one row per line item per local date) is also assertable directly, which is what
the singular test `assert_delivery_daily_grain_is_unique` does.

**Magnitude.** Left in, they inflate Q2 net revenue by **$3,142.57** and Q2
impressions by 372,942. Flat fee revenue is unaffected — it is not a function of
impressions — so the entire error lands on CPM line items. In 1b the same
duplicates flatter pacing, making delivery look better than it was.

**Handling.** Fixed in the model: `int_delivery_daily_deduplicated` collapses
them with `distinct`. The raw query re-applies the same `select distinct`.

**Where the real fix belongs.** **Upstream.** `distinct` is safe only while the
duplicates are byte-identical. If the source ever emits *conflicting* duplicates
— same key, different measures — `distinct` silently keeps both and the grain
breaks. The loader needs an idempotency key. The test is written to fail in
exactly that case rather than to pass quietly.

## 2. `discount_pct` mixes fractions and whole percentage points

**What it is.** The same column holds `0.05`, `0.1`, `0.15`, `0.2` (fractions)
and `5.0` and `12.0` (percentage points). The brief's note that the field "was
entered by humans in an operational tool over several years" is the tell.

Affected: **LI-5003** (`5.0`, meaning 5%) and **LI-5009** (`12.0`, meaning 12%).

**How I detected it.** Any value `> 1` in a column that is supposed to be a
fraction of 1. Seven line items have a discount; two are out of range.

**Magnitude.** This is the largest defect in the data by an order of magnitude.
Applied literally, a 12% discount becomes 1200%:

| Line item | Gross | Net (correct) | Net (naive) | Error |
|---|---|---|---|---|
| LI-5003 | $9,406.29 | $8,935.98 | −$37,625.18 | $46,561.15 |
| LI-5009 | $21,053.56 | $18,527.13 | −$231,589.18 | $250,116.31 |
| | | | **Total** | **$296,677.46** |

Both line items would report *negative* revenue, and Q2 net revenue would come in
at roughly $269,089 instead of $565,766.83 — a 52% understatement. Vero Health
Group would show a negative quarter.

**Handling.** Fixed in the model: `int_line_items_normalized` treats values above
1 as percentage points and divides by 100. The raw query re-applies the same
rule.

**Where the real fix belongs.** **Upstream, and this one is urgent.** The rule is
a heuristic, not a guarantee — it is unambiguous for the values present today but
would misread a genuine 100% discount (`1.0` stays `1.0`, correctly) or a real
0.05 percentage-point discount. The operational tool should validate units at
entry and the column should be backfilled to a single unit.

## 3. `LI-5999` delivers but has no line item record

**What it is.** 20 delivery rows reference `LI-5999`, which does not exist in
`line_items`. They carry **637,596 impressions** and **$1,859.74 of media cost**
across 2026-04-01 to 2026-04-20 — a full three weeks of consecutive daily
delivery, so this is a real line item missing from the extract, not a typo'd id.

**How I detected it.** Left join delivery to line items and look for nulls; also
caught by the `relationships` test on `fct_delivery_daily.line_item_key`.

**Magnitude.** **Zero effect on 1a revenue** — with no rate and no pricing model,
no revenue is calculable, so it is correctly absent. The damage is to cost and
volume reporting: an inner join to the line item dimension silently drops
$1,859.74 of media cost and 637,596 impressions. It does not appear in 1b either,
since it has no contract to pace against.

**Handling.** Fixed structurally in the model. `int_line_items_normalized` adds
an **inferred member** derived from delivery, flagged `is_unmapped`, so the
foreign key always resolves and inner and left joins now agree at $90,396.01 of
media cost. Revenue stays null. The anomaly is not silenced: a threshold test
passes at one inferred member and fails the build at two.

**Where the real fix belongs.** **Upstream.** The line-item extract is
incomplete. The inferred member stops the warehouse from losing the spend; it
does not tell you the rate, so the revenue is genuinely unrecoverable until the
source is fixed.

## 4. `billing_month` disagrees with the month delivery occurred

**What it is.** 24 rows carry a `billing_month` other than the month their
`event_date_local` falls in — 20 on CPM line items, 4 on flat fee.

**How I detected it.** `billing_month <> strftime(event_date_local, '%Y-%m')`.

**Magnitude.** The business rule is that the reporting month is the month
delivery actually occurred, so `billing_month` is wrong for recognition. Using it
would move:

| From (event month) | To (billing month) | Rows | Net revenue |
|---|---|---|---|
| 2026-04 | 2026-05 | 10 | $1,694.32 |
| 2026-05 | 2026-06 | 10 | $1,499.10 |
| | | | **$3,193.42** |

The quarter total is unchanged — everything stays inside Q2 — but April is
understated by $1,694.32 and June overstated by $1,499.10. For a monthly CFO
report that is the whole point of the question.

**Handling.** Fixed in the model: `reporting_month` is derived from
`event_date_local`. `billing_month` is retained for traceability and is used only
to match billing adjustments, which are genuinely recorded at that grain.

**Where the real fix belongs.** **Upstream, as a definition.** Someone needs to
say what `billing_month` means. It is plausibly a deliberate billing-cycle offset
rather than an error, in which case both columns are correct and the warehouse
should keep carrying both — which is what it does.

## 5. Six rows with negative impressions

**What it is.** Six delivery rows carry negative impressions totalling
**−78,167** (−71,327 on CPM line items, −6,840 on one flat fee line). All six
also show more clicks than impressions — that is the *same* six rows, not a
separate defect: the clicks stayed positive while impressions went negative.

| Line item | Date | Impressions | Clicks |
|---|---|---|---|
| LI-5002 | 2026-04-18 | −14,191 | 16 |
| LI-5006 | 2026-04-24 | −35,485 | 31 |
| LI-5008 | 2026-06-24 | −6,960 | 7 |
| LI-5011 | 2026-05-02 | −9,408 | 12 |
| LI-5013 | 2026-04-14 | −5,283 | 4 |
| LI-5101 | 2026-05-24 | −6,840 | 14 |

**How I detected it.** `impressions < 0` and `clicks > impressions`. The second
check on its own would look like a CTR defect and send you down the wrong path.

**Magnitude.** −$709.96 of CPM revenue in Q2. The flat fee row has no revenue
effect. Small in dollars, but they poison any rate calculation: a naive
`clicks / impressions` CTR returns a negative number on these six rows.

**Handling.** **Kept as recorded, not clamped.** They read as correction rows
intended to net out at the monthly grain, and clamping to zero would restate
delivery upward and overstate revenue by $709.96. In 1b they slightly worsen the
pacing of the affected line items, which is the correct treatment if the
corrections are real.

**Where the real fix belongs.** **Upstream.** A negative impression count is not
a fact about the world. If these are reversals they should carry a correction
flag or reference the row they reverse; if they are errors they should be fixed
at source. Either way the consumer should not have to infer intent.

## 6. Two line items have no `campaign_id`

**What it is.** `LI-5105` (CPM, 1,100,000 contracted, $10.50) and `LI-5106`
(FLAT_FEE, $9,000/month) carry a null `campaign_id` in the source. With no
campaign there is no advertiser, and therefore no brand.

**How I detected it.** Null check on the source column; also visible as null
`campaign_key` in the dimension.

**Magnitude.** **$33,666.19 of Q2 net revenue — 5.95% of the quarter — cannot be
attributed to any advertiser.** $6,666.19 from LI-5105 and $27,000.00 from
LI-5106 ($9,000 × 3 months). In 1b, LI-5105 carries **$4,883.81 of revenue at
risk** at a 0.577 pacing ratio — the second-worst in the book — with no account
owner to escalate to.

**Handling.** **Surfaced, not dropped.** Both 1a queries report the amount on an
explicit `UNATTRIBUTED (line item has no campaign)` line so the grand total still
reconciles to total recognised revenue. Hiding it would make the brand rows sum
to $532,100.64 against a real total of $565,766.83 with no explanation.

**Where the real fix belongs.** **Upstream.** This is a mapping gap, not a
modelling choice. No allocation rule can invent the right campaign, and guessing
would put revenue on the wrong advertiser's P&L.

## 7. Seven advertiser rows are five brands

**What it is.** The advertiser table carries near-duplicate and divisional rows:

| ID | Name | Parent | Issue |
|---|---|---|---|
| ADV-1001 | `Northgate Insurance` | ADV-1001 | — |
| ADV-1002 | `northgate insurance ` | ADV-1001 | Lowercased, **trailing space** |
| ADV-1003 | `Perreault Foods` | ADV-1003 | — |
| ADV-1004 | `Perreault Foods NA` | ADV-1003 | Regional division |

**How I detected it.** Comparing `advertiser_id` to `parent_advertiser_id`, then
inspecting names with delimiters (`'['||advertiser_name||']'`) to make the
trailing whitespace visible. Five of seven rows are their own parent; two are not.

**Magnitude.** Reporting on `advertiser_id` returns **7 rows per month instead of
5** and splits two brands. **$105,411.52 of Q2 net revenue** sits on the child
rows — $17,658.82 on ADV-1002 and $87,752.70 on ADV-1004 — appearing as separate
advertisers from their parents. Perreault Foods would be understated by 53% on
its own line. This is precisely the "one brand is one line" requirement.

**Handling.** Fixed in the model. `int_advertisers_with_parent` attaches the
parent name, `dim_advertisers` exposes it, and `parent_advertiser_id` is carried
down onto both facts, so rolling up to brand is a group-by rather than a join a
reader has to know to write. The raw query re-applies the same self-join.

**Where the real fix belongs.** **Upstream for the name hygiene, warehouse for
the rollup.** The trailing space and casing on ADV-1002 are straightforward
source defects and should be cleaned there. The parent-child hierarchy is
legitimate — a division is a real thing — so rolling it up is reporting logic and
belongs where it is.

## 8. Flat fee line items have no impression contract

**What it is.** All five FLAT_FEE line items have a null
`contracted_impressions`. All 17 CPM line items have one.

**How I detected it.** Null counts grouped by `pricing_model`.

**Magnitude.** None on 1a. On 1b it determines who appears at all: pacing is
undefined without a contract, so the five flat fee line items are excluded. If
their nulls were coalesced to zero they would each show an infinite pacing
shortfall and dominate the report.

**Handling.** Not a defect — it is correct. A flat fee is not impression-based,
so it has no volume commitment. Both 1b queries filter to CPM with a non-null
contract, and the warehouse stores the expectation as null rather than zero.

**Where the real fix belongs.** **Nowhere.** Recorded here because "null contract
on 23% of line items" looks like a defect until you know the pricing model, and
the wrong reflex (coalesce to zero) produces a badly wrong report.

## 9. Five timezones behind one local date column

**What it is.** `event_date_local` is local to the campaign's timezone, and
campaigns span five: `America/New_York` (4), `America/Chicago` (3),
`America/Denver` (1), `Europe/London` (1), `Asia/Tokyo` (1). Tokyo and Denver are
up to 16 hours apart.

**How I detected it.** Distinct timezones on `campaigns`, cross-referenced to
`market`. Note `US` alone spans three zones, so grouping by market does not
resolve it.

**Magnitude.** **Not quantifiable with the data given**, which is the finding.
There is no UTC timestamp anywhere in the source — only a local date — so there
is no way to determine how many rows sit on the wrong side of a month boundary.
For scale: **129 delivery rows carrying 2,111,433 impressions fall on the first
or last day of a month**, and those are the rows where a timezone shift could
move revenue between reporting months. That is an upper bound on exposure, not an
error estimate.

**Handling.** Documented, not corrected. Summing by `event_date_local` across
markets mixes timezones, and every figure in 1a inherits that. It is consistent
with how the source records delivery, which is the best available answer.

**Where the real fix belongs.** **Upstream.** The delivery feed should carry a
UTC timestamp alongside the local date. Without one, "revenue in June" is
undefined to within about a day at the boundaries and no amount of modelling
recovers it.

---

## Checked and clean

Stated because a register that only lists failures does not tell you what was
actually examined:

- **Referential integrity holds everywhere else.** Every `line_items.campaign_id`
  resolves to a campaign (excluding the two nulls in defect 6), every
  `campaigns.advertiser_id` resolves to an advertiser, and all 25
  `billing_adjustments.campaign_id` values resolve. `LI-5999` is the only orphan.
- **No dangling parent advertisers.** Every `parent_advertiser_id` resolves.
- **No delivery outside a flight window.** Zero rows fall before `flight_start`
  or after `flight_end`.
- **No negative media cost**, and no null impressions or dates.
- **Adjustments fall entirely within Q2** (2026-04 through 2026-06), net
  −$8,689.90 across 25 rows, so none are stranded outside the reporting period.
- **Flat fee flight coverage is complete** — every flight day of every flat fee
  line item has a delivery row (30/30, 31/31, 30/30), which is what makes the
  daily allocation in the warehouse lossless.

---

## What this costs if nobody fixes anything

Stacking the defects that move revenue, an analyst working straight from the raw
tables without any of the above corrections would report Q2 net revenue of
**$268,917.75** against a true **$565,766.83** — a **52.5% understatement**,
driven almost entirely by defect 2. They would also report 7 advertisers instead
of 5, put $3,193.42 in the wrong months, and, having used an inner join, quietly
lose $1,859.74 of media cost without ever seeing an error.

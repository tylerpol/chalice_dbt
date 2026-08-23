{% docs fct_billing_adjustments %}

## What this model contains

Fact table of billing adjustments — credits, rebates, makegoods, and fees applied
to a campaign for a given billing month, outside of delivered media cost. Combine
with `fct_delivery_daily` to reach a billable amount.

## Granularity

One row per adjustment, keyed on `billing_adjustment_key`.

## Dev notes

- **The source has no natural key.** `billing_adjustment_key` is an md5 hash of
  all four business columns (`campaign_id`, `billing_month`, `adjustment_usd`,
  `reason`) because no smaller combination is unique — one campaign/month/reason
  triple (`CMP-3007`, `2026-06`, `rebate`) legitimately appears twice with
  different amounts. A consequence: **two genuinely distinct adjustments that
  happened to be identical in all four fields would collapse into one row.** That
  does not occur in the data today, and the `unique` test on the key would fail
  loudly if the hash ever stopped separating rows.
- **Sign is not implied by `reason`.** Credit-flavored reasons are not reliably
  negative and fee-flavored reasons are not reliably positive — `late fee` ranges
  from -525.40 to +1,186.88, and `rebate` spans both signs. Never infer direction
  from the reason text; always use the sign of `adjustment_usd`.
- `reason` is **free text**, not a controlled vocabulary. Five values appear today
  (`rebate`, `makegood`, `late fee`, `discrepancy credit`, `viewability credit`)
  but nothing constrains the source to that set, so no `accepted_values` test is
  applied. Grouping by it is safe for reporting; branching business logic on it is
  fragile.
- Adjustments are at **campaign/month** grain while delivery is at
  **line item/day** grain. They cannot be joined row-to-row — aggregate delivery
  to campaign and billing month first, then combine.
- Every adjustment resolves to a valid campaign, so the `relationships` test on
  `campaign_key` is enforced at error severity.

{% enddocs %}

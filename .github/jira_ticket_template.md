# Jira ticket template

Copy into the Jira description. Delete the guidance in angle brackets.

Requirements say what to build. Acceptance criteria say how we will know it is
right — each one checkable by someone who did not write the code, against a
specific value. "Revenue is correct" is not an acceptance criterion.
"`billed_revenue` for Northgate in 2026-05 returns $44,240.41" is.

---

## Summary

<!-- One line, imperative. "Add billed revenue to the campaign rollup". -->

## Context

<!-- What happens now, who it affects, what it costs. Include the figure if there
     is one. -->

## Requirements

<!-- Numbered, so acceptance criteria can reference them. What, not how. -->

1.
2.

## Out of scope

<!-- Write this even when it feels obvious. Cheapest way to stop a PR three times
     the size of the ticket. -->

-

## Acceptance criteria

<!-- Each independently checkable. Prefer a concrete expected value. -->

- [ ] **AC1** (req 1) — Given <state>, when <action>, then <specific result>
- [ ] **AC2** (req 2) —

## Definition of done

- [ ] `dbt build` passes with ERROR=0, and any warning is justified in the PR
- [ ] `sqlfluff lint models/ tests/` clean
- [ ] Every acceptance criterion verified by running it, not by reading the code
- [ ] Reviewed by someone who did not write it

## Risks and dependencies

-

---

### Example acceptance criteria

For calibration — this is the level of specificity to aim for:

- [ ] **AC1** (req 1) — Given Q2 2026, when billed revenue is grouped by brand,
      Northgate 2026-05 returns **$44,240.41** ($45,455.82 net less $1,215.41
      adjustments).
- [ ] **AC2** (req 2) — `net_revenue` and `billed_revenue` are separately
      selectable and differ by exactly the adjustments total, −$8,689.90.
- [ ] **AC3** (req 3) — A campaign month with an adjustment and no delivery
      appears with zero revenue and the adjustment applied.

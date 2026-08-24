## What and why

<!-- One or two sentences. What changed, and what problem it solves. Link the ticket. -->

Ticket:

## Layers touched

<!-- Tick what this PR changes. Layer rules live in each models/<layer>/__<layer>_layer.md -->

- [ ] `seeds` — source data
- [ ] `staging` — cosmetic only (casts, renames, parsing). No joins, unions, or filters
- [ ] `intermediate` — joins, filters, grain changes, business logic
- [ ] `marts` — assembly and key hashing only
- [ ] `analyses` — answer queries
- [ ] `tests` — singular tests
- [ ] `chat/` — the natural-language app
- [ ] `chat/semantic/measures.yml` — the semantic model

## Does this change a published number?

**This is the section reviewers should read first.** Most PRs here are not
refactors — they move figures that someone has already reported.

- [ ] No number changes. Skip the table.
- [ ] Numbers change. Fill in the table and say why.

| Figure | Before | After | Why it moved |
|---|---|---|---|
|  |  |  |  |

<!-- Include the query you used, so a reviewer can reproduce both sides. A
     rounding-policy change is a number change: net revenue moved $565,766.81 ->
     $565,766.83 when rounding moved from the monthly grain to the reporting
     grain, and that is worth a row here. -->

## Business rules

<!-- Does this touch how revenue, discounts, adjustments, the reporting month, or
     pacing are calculated? If a rule was silent on a case you hit, you must
     record the decision in models/__business_rules.md, not just in code. -->

- [ ] No business rule affected
- [ ] Rule affected, and `models/__business_rules.md` is updated
- [ ] A new decision was taken where the rules are silent, and it is written down

## Checks

- [ ] `dbt build` passes — **PASS=___, WARN=___, ERROR=0**
- [ ] `sqlfluff lint models/ tests/` is clean
- [ ] Grain is asserted for anything that changes grain
- [ ] Null vs zero is deliberate — null means *not applicable*, zero means
      *measured and it was none*. They are not interchangeable
- [ ] Money is `decimal`, never `float`
- [ ] Additive columns still add up (`gross - discount = net`)

### If the warning count is not zero

Every warning must be either fixed or justified here. A permanently-warning test
trains people to ignore warnings, which is when a real one slips past. Prefer
encoding a known anomaly as a threshold (`warn_if` / `error_if`) so the build is
green *and* a regression still breaks it.

| Test | Rows | Why this is acceptable |
|---|---|---|
|  |  |  |

## Documentation

Docs are not optional here: `persist_docs` writes them into DuckDB as column
comments, and the chat app reads those comments as its schema context. Stale
docs actively degrade the app's answers.

- [ ] `.yml` column specs updated for added or changed columns
- [ ] Mart `.md` doc block updated — *what it contains*, *granularity*, *dev notes*
- [ ] Dev notes record any trap a column name does not imply
- [ ] `models/__business_rules.md` updated if a decision changed

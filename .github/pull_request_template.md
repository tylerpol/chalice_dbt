## What and why

<!-- One or two sentences. What changed, and what problem it solves. Link the ticket. -->

Ticket:

## Layers touched

<!-- Tick what this PR changes. Layer rules live in each models/<layer>/__<layer>_layer.md -->

- [ ] `seeds` — source data
- [ ] `staging` — cosmetic only (casts, renames, parsing). No joins, unions, or filters
- [ ] `intermediate` — joins, filters, grain changes, business logic
- [ ] `mart` — assembly and key hashing only
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

## Documentation

- [ ] `.yml` column specs updated for added or changed columns
- [ ] Mart `.md` doc block updated — *what it contains*, *granularity*, *dev notes*
- [ ] Dev notes record any trap a column name does not imply
- [ ] `models/__business_rules.md` updated if a decision changed

# Development notes — Chalice Chat

Context for picking this up later. `README.md` says how to run it; this file says
**why it is built the way it is**, and what was already tried and rejected. The
code shows the destination, not the route.

Last updated: 2026-08-23.

---

## State

Working. All six example questions in `app.py` return correct results with
`qwen2.5-coder:3b` — verified end to end against the live model, including the
four-table join, chart rendering, and the SQL guard.

Built on branch `add-v0-of-chat-app`, which already contained the full mart
layer. Nothing here has been committed yet.

## Architecture, and why

**The model never writes executable code.** It returns JSON —
`{sql, chart_type, x, y, title, explanation}` — and the app renders it. This was
a deliberate choice over the Vanna-style approach of having the model emit Plotly
code that gets `exec()`d. Two reasons: that pattern is the root of Vanna's
prompt-injection→RCE class of bug, and a small model writes a chart *spec* far
more reliably than it writes correct Python.

**Ollama grammar-constrains the reply** to the JSON schema in `llm.py`, so
malformed JSON is mechanically impossible. Only wrong *content* is possible —
hence the SQL is always displayed under every answer.

**Two passes.** Pass 1 (`scan`) shows a one-line catalogue and asks which tables
are needed. Pass 2 (`ask`) shows full columns for just those tables. This keeps
the prompt small and focused.

**Three safety layers:** read-only DuckDB connection, `sql_guard.py`, and no
`exec()` anywhere. The read-only connection also means the app can run *during* a
`dbt build` — it never takes DuckDB's single write lock.

**`AGENTS.md` holds all behaviour.** Re-read on every question (mtime-keyed
cache), so editing it changes the assistant without a code change or restart. It
is also rendered in the sidebar.

## Debugging history — do not redo these

The model kept inventing tables (`mart.dim_markets`) and writing joins that
returned zero rows. It looked like "the model is too small". It was mostly not.
Three separate causes, in the order they were found:

1. **Context overflow (app bug).** The prompt was ~3,710 tokens against Ollama's
   **4,096 default** `num_ctx`, leaving ~380 tokens for question, history, and
   answer. The schema was being silently truncated — the model wrote SQL against
   a schema it could no longer see. Fixed with `NUM_CTX = 16384` in `config.py`.
   **This is the single highest-impact fix and the least obvious.**

2. **Missing join hops (app bug).** The scan pass picked the two *endpoint*
   tables and omitted the ones in between, so a correct multi-hop join was
   physically impossible. Fixed with `expand_for_joins()` in `schema_context.py`,
   which BFSes the key graph and adds connecting tables. This is a deterministic
   problem the app should solve, not the model.

3. **Needed a worked example.** With both above fixed it still joined
   `line_item_key = advertiser_key`. Adding one worked multi-hop join example to
   `AGENTS.md` fixed it outright. Small models respond disproportionately to a
   concrete example versus a stated rule.

Also fixed along the way:
- Catalogue summaries were leaking `## What this model contains` markdown
  headings from the dbt doc blocks, crowding out the actual prose.
- The model names axes by expression (`SUM(f.cost)`) or qualified name
  (`c.market`) rather than the output column, so `charts.py` infers axes when the
  named ones are absent rather than dropping to a table.
- `use_container_width` is deprecated in Streamlit 1.62 — replaced. Note
  `dataframe`/`plotly_chart` default to `width="stretch"` but `button` defaults to
  `width="content"`, so buttons need it set explicitly.
- Replaying history collided Streamlit element ids. Widgets are keyed by turn
  **position**, not content — keying by content still collides when the same
  question is asked twice, which is normal in a chat.

### Rejected approaches

- **Relying on the `_key` naming rule alone**, without showing the derived
  relationships. Logically sufficient, but the 3B model applied it inconsistently
  and produced **zero-row results with no error** — worse than a failure, because
  it looks like a valid answer. `derive_joins()` computes the map from metadata at
  answer time, so nothing is hand-maintained, but it *is* shown to the model.
- **Showing all four schemas.** Describes the same entities four times, triples
  the prompt, and gives a small model near-identical tables to confuse. `mart`
  only, enforced in `sql_guard.py` rather than merely instructed.

## Known limits

- **Multi-hop joins are the fragile part.** Everything currently passes, but new
  question shapes needing 3+ hops are where it will break first.
- **Zero rows usually means a broken join**, not an empty answer. `AGENTS.md`
  says so, and the test harness flags it, but the UI does not warn yet — worth
  adding.
- `qwen2.5-coder:7b` is a one-line swap in `config.py` if accuracy disappoints.
  Never tested; the 3B model met the bar so the larger one was never pulled.
- `charts.py` and `app.py` have no unit tests. `sql_guard.py` was tested against
  12 bypass attempts; `schema_context.py` against a mock warehouse.

## Data caveats that shaped the prompt

These are real properties of the source data, documented in the mart doc blocks
and repeated in `AGENTS.md` because they change what correct SQL looks like:

- Some delivery reaches no campaign, and therefore no advertiser or brand.
  `LI-5105` and `LI-5106` carry no `campaign_id`, and `LI-5999` (20 rows,
  $1,859.74 of media cost) is absent from the source line-item extract entirely.
  An inner join to `dim_campaigns` silently drops all three — 202 rows,
  $5,828.60 of media cost and $33,666.19 of revenue. Hence "prefer left joins".
  **"Total media cost by market" correctly returns a `None` market row for
  $5,828.60 — that is this unattributed spend, not a bug.**
  `dim_line_items` itself is safe to inner join: it carries an inferred member
  for `LI-5999`, so the delivery fact's `line_item_key` always resolves.
- `billing_month` disagrees with `event_date_local` on 24 rows.
- Negative impressions and clicks > impressions exist; guard rate denominators.
- Five timezones, so summing by local date across markets mixes them.
- `rate` means different things per `pricing_model`.

## Environment gotchas

- The dbt venv is `~/Desktop/dbt-env`; the app has its **own** `.venv` in `chat/`.
  Don't cross them.
- Python 3.14 — Streamlit 1.62 and Plotly 6.9 do have wheels for it.
- `pip` emits `Cache entry deserialization failed` warnings on this machine.
  Pre-existing and harmless; `pip cache purge` silences them.
- DuckDB allows one writer. A SQL IDE holding the file blocks `dbt build`, and
  blocks any read-write connection. The app is read-only so it coexists fine.

## Next steps, unstarted

- Warn in the UI when a query returns zero rows.
- Package a distributable zip: copy the built database to `chat/data/` (the
  `.gitignore` excludes `data/` deliberately, so this is an explicit step).
- Optional bring-your-own-API-key path, which would make a shareable zip ~10MB
  instead of requiring a ~3GB local model download.

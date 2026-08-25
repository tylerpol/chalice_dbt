"""Talk to the local Ollama model and get back a structured answer.

Two passes, so the model works from metadata it asked for rather than a wall of
schema it has to hold in mind:

  1. scan   -- shown a one-line catalogue of tables, it names the ones it needs
  2. answer -- shown the full columns of just those tables, it writes the query

Operating instructions live in AGENTS.md and are re-read on every question, so
editing that file changes behaviour without touching code.

The model never writes executable code. It returns a JSON object describing a
query and how to plot it; the app renders that itself. Ollama constrains the
reply with a grammar derived from these schemas, so malformed JSON is impossible
-- only wrong *content* is, which is why the SQL is always shown to the user.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import ollama

import config

CHART_TYPES = ["table", "line", "bar", "horizontal_bar", "area", "scatter", "pie"]

_GUIDANCE_PATH = Path(__file__).resolve().parent / "AGENTS.md"

SCAN_SCHEMA = {
    "type": "object",
    "properties": {
        "tables": {"type": "array", "items": {"type": "string"}},
        "reasoning": {"type": "string"},
    },
    "required": ["tables"],
}

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "sql": {"type": "string"},
        "chart_type": {"type": "string", "enum": CHART_TYPES},
        "x": {"type": "string"},
        "y": {"type": "string"},
        "color": {"type": "string"},
        "title": {"type": "string"},
        "explanation": {"type": "string"},
    },
    # x and y are required so the grammar forces the model to consider them.
    # Left optional it simply omits them and every chart degrades to a table.
    # An empty string means "not applicable", correct for a table.
    "required": ["sql", "chart_type", "x", "y", "title", "explanation"],
}

SCAN_PROMPT = """\
You are selecting which tables are needed to answer a question.

Available tables:
{catalogue}

Return the qualified names of only the tables required. Include every table you
must join through to reach the columns you need — attributes live on dimensions,
not on facts. Prefer fewer tables, but never omit one you have to join through.
"""

ANSWER_PROMPT = """\
{guidance}

---

Columns of the tables you selected:

{schema}

---

Key relationships, derived from the schema. These are the ONLY valid joins.
Prefer a direct edge where one exists; chain only to reach something no direct
edge covers:

{joins}

---

Which table owns which column. A column appears ONLY on the table listed here.
If you want to filter or group by one, reference it on that table:

{columns}
"""


@dataclass
class Answer:
    sql: str
    chart_type: str
    title: str
    explanation: str
    x: str | None = None
    y: str | None = None
    color: str | None = None
    tables_used: list[str] | None = None


class ModelUnavailable(Exception):
    """Raised when Ollama or the model cannot be reached."""


@lru_cache(maxsize=1)
def _guidance_cached(mtime: float) -> str:
    return _GUIDANCE_PATH.read_text(encoding="utf-8")


def guidance() -> str:
    """Read AGENTS.md, re-reading whenever it changes on disk."""
    try:
        return _guidance_cached(_GUIDANCE_PATH.stat().st_mtime)
    except OSError:
        return "You are a data analyst. Query the mart schema only. Return read-only SQL."


def _client() -> ollama.Client:
    return ollama.Client(host=config.OLLAMA_HOST)


def _chat(messages: list[dict], schema: dict) -> str:
    try:
        response = _client().chat(
            model=config.MODEL,
            messages=messages,
            format=schema,
            options={"temperature": config.TEMPERATURE, "num_ctx": config.NUM_CTX},
        )
    except Exception as exc:  # noqa: BLE001
        raise ModelUnavailable(str(exc)) from exc
    return response["message"]["content"]


def check_ready() -> tuple[bool, str]:
    """Return (ready, human-readable status) for display in the sidebar."""
    try:
        installed = _client().list().get("models", [])
    except Exception as exc:  # noqa: BLE001 - surfaced verbatim to the user
        return False, f"Cannot reach Ollama at {config.OLLAMA_HOST} ({exc})."

    names = {m.get("model") or m.get("name", "") for m in installed}
    if config.MODEL in names or any(n.startswith(config.MODEL) for n in names):
        return True, f"{config.MODEL} ready"
    return False, f"Ollama is running but '{config.MODEL}' is not installed. Run the install script."


def scan(question: str, catalogue: str) -> list[str]:
    """Pass 1 -- ask which tables are needed. Falls back to all on any doubt."""
    raw = _chat(
        [
            {"role": "system", "content": SCAN_PROMPT.format(catalogue=catalogue)},
            {"role": "user", "content": question},
        ],
        SCAN_SCHEMA,
    )
    try:
        picked = json.loads(raw).get("tables", [])
    except json.JSONDecodeError:
        return []
    return [t for t in picked if isinstance(t, str)]


def ask(
    question: str,
    schema: str,
    joins: str = "",
    columns: str = "",
    history: list[dict] | None = None,
) -> Answer:
    """Pass 2 -- write the query against the selected tables' columns."""
    messages = [
        {
            "role": "system",
            "content": ANSWER_PROMPT.format(
                guidance=guidance(), schema=schema, joins=joins, columns=columns
            ),
        }
    ]

    # A short rolling window lets follow-ups like "now by market" work without
    # letting context grow unbounded.
    #
    # Only SQL the model itself wrote is replayed. Semantic-path SQL is composed
    # by the application from measures.yml: it carries CTEs named `unioned` and
    # `combined` and `grouping()` flags like `brand_is_total` that the model
    # never authored. Handed back as "here is what you wrote last time" it gets
    # imitated rather than understood, and the imitation is broken -- a
    # `from combined` with no such CTE, or a `brand_is_total` the inner query
    # never selected. Failed turns are skipped for the same reason: a broken
    # exemplar teaches the break.
    for turn in (history or [])[-3:]:
        if turn.get("semantic") or turn.get("error"):
            continue
        if turn.get("sql"):
            messages.append({"role": "user", "content": turn["question"]})
            messages.append({"role": "assistant", "content": turn["sql"]})

    messages.append({"role": "user", "content": question})

    payload = json.loads(_chat(messages, RESPONSE_SCHEMA))

    def clean(key: str) -> str | None:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        return None

    return Answer(
        sql=payload.get("sql", ""),
        chart_type=payload.get("chart_type", "table"),
        title=payload.get("title", "Result"),
        explanation=payload.get("explanation", ""),
        x=clean("x"),
        y=clean("y"),
        color=clean("color"),
    )


REPAIR_PROMPT = """\
{guidance}

---

Columns of the available tables:

{schema}

Valid joins, derived from the schema:

{joins}

Which table owns which column:

{columns}

---

Your previous query failed. Fix it.

Question: {question}

Query that failed:
{sql}

Database error:
{error}

The error is authoritative. If it says a column is missing from a table, that
column genuinely is not there — do not simply rewrite the same join.

When the error is "Table X does not have a column named Y", the fix is almost
never a different column name on the same alias. Look up Y in the column
ownership list above, find the table that actually owns it, and reference it
there — usually that table is already in your FROM clause under another alias.
"""


def repair(
    question: str,
    schema: str,
    bad_sql: str,
    error: str,
    joins: str = "",
    columns: str = "",
) -> Answer:
    """Give the model its own error back and let it correct itself once."""
    payload = json.loads(
        _chat(
            [
                {
                    "role": "system",
                    "content": REPAIR_PROMPT.format(
                        guidance=guidance(),
                        schema=schema,
                        joins=joins,
                        columns=columns,
                        question=question,
                        sql=bad_sql,
                        error=error,
                    ),
                },
                {"role": "user", "content": "Return the corrected query."},
            ],
            RESPONSE_SCHEMA,
        )
    )

    def clean(key: str) -> str | None:
        value = payload.get(key)
        return value.strip() if isinstance(value, str) and value.strip() else None

    return Answer(
        sql=payload.get("sql", ""),
        chart_type=payload.get("chart_type", "table"),
        title=payload.get("title", "Result"),
        explanation=payload.get("explanation", ""),
        x=clean("x"),
        y=clean("y"),
        color=clean("color"),
    )


PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "answerable": {"type": "boolean"},
        "measures": {"type": "array", "items": {"type": "string"}},
        "dimensions": {"type": "array", "items": {"type": "string"}},
        "filters": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "dimension": {"type": "string"},
                    "values": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["dimension", "values"],
            },
        },
        "months": {"type": "array", "items": {"type": "string"}},
        "totals": {"type": "boolean"},
        "order_by": {"type": "string"},
        "descending": {"type": "boolean"},
        "limit": {"type": "integer"},
        "chart_type": {"type": "string", "enum": CHART_TYPES},
        "x": {"type": "string"},
        "y": {"type": "string"},
        "title": {"type": "string"},
        "explanation": {"type": "string"},
    },
    "required": [
        "answerable", "measures", "dimensions", "filters", "months", "totals",
        "order_by", "descending", "chart_type", "x", "y", "title", "explanation",
    ],
}

PLAN_PROMPT = """\
You are planning an answer, not writing SQL. The application builds the SQL from
the measures and dimensions you name, so name them exactly as they appear below
and nothing else.

{catalogue}

---

Rules:

- `measures` -- the figures the question asks for, by name. Prefer `billed_revenue`
  when the question is about revenue a finance team would report, since it
  includes billing adjustments; use `net_revenue` only when the question is
  explicitly about revenue before adjustments.
- `dimensions` -- what to break the answer down by, one column each. An empty
  list gives one total row.

  **`brand` is the default for anything advertiser-shaped.** "Revenue by
  advertiser", "one row per advertiser", "per brand", "by client" all mean
  `brand`. The word "advertiser" in a question is NOT a reason to pick the
  `advertiser` dimension. Choose `advertiser` only when the question explicitly
  says not to roll up -- "without rolling up", "by individual advertiser
  account", "including subsidiaries separately". Getting this wrong splits two
  brands across two lines each and understates one of them by half.
- `filters` -- how to NARROW the rows, without adding a column. This is the
  distinction that matters most: "CPM line items pacing worst" wants
  `filters: [{{"dimension": "pricing_model", "values": ["CPM"]}}]` and
  `dimensions: ["line_item"]`. Putting `pricing_model` in `dimensions` instead
  would group by it rather than restrict to it, and answer a different question.
  A phrase of the form "<value> <things>" is almost always a filter.
- `months` -- reporting months as YYYY-MM, e.g. ["2026-04","2026-05","2026-06"]
  for Q2 2026. Empty means all months. A full date is NOT a month: "as of
  2026-06-30" describes when pacing was measured, which is already baked into
  the pacing measures, so it needs no filter at all.
- `totals` -- true when the question asks for a total, subtotal, or quarter
  total. The application adds the subtotal rows; do not add a measure for it.
- `order_by` -- a measure name whenever the question ranks or superlatives
  ("most", "largest", "worst", "top", "biggest"). Empty only when the question
  asks for a plain breakdown with no ordering implied.
- `descending` -- true for "most" or "largest"; false for "worst pacing" or
  "lowest", where the smallest value is the answer.
- `answerable` -- false ONLY if the question needs something with no measure or
  dimension above. Anything the list covers is answerable.

`x` and `y` must be names you used in `measures` or `dimensions`, or empty
strings for a table.
"""


def plan(question: str, catalogue: str) -> dict:
    """Pick measures and dimensions. Composition is the application's job."""
    messages = [
        {"role": "system", "content": PLAN_PROMPT.format(catalogue=catalogue)},
        {"role": "user", "content": question},
    ]
    return json.loads(_chat(messages, PLAN_SCHEMA))

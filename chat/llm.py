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

Key relationships, derived from the schema. These are the ONLY valid joins;
chain them to reach anything further out:

{joins}
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


def ask(question: str, schema: str, joins: str = "", history: list[dict] | None = None) -> Answer:
    """Pass 2 -- write the query against the selected tables' columns."""
    messages = [
        {
            "role": "system",
            "content": ANSWER_PROMPT.format(guidance=guidance(), schema=schema, joins=joins),
        }
    ]

    # A short rolling window lets follow-ups like "now by market" work without
    # letting context grow unbounded.
    for turn in (history or [])[-3:]:
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

---

Your previous query failed. Fix it.

Question: {question}

Query that failed:
{sql}

Database error:
{error}

The error is authoritative. If it says a column is missing from a table, that
column genuinely is not there — do not simply rewrite the same join. Re-read the
columns above and route through whichever table actually carries the key.
"""


def repair(question: str, schema: str, bad_sql: str, error: str, joins: str = "") -> Answer:
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

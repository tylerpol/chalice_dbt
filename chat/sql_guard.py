"""Validate model-generated SQL before it reaches the database.

The connection is already opened read-only, which is the real protection. This
module exists for two further reasons:

  1. A read-only connection rejects writes with an opaque engine error. Catching
     the intent here lets us say plainly what was refused and why.
  2. Read-only does not stop a statement from reaching outside the database --
     ATTACH, COPY ... TO, and the file-reading functions can touch the local
     filesystem. Those are blocked outright.

This is a denylist over a single-statement allowlist, not a SQL parser. It is
defence in depth, never the only line of defence.
"""

from __future__ import annotations

import re

# Statement kinds that may begin a query. Anything else is refused.
_ALLOWED_PREFIXES = ("select", "with", "describe", "summarize", "show", "explain", "pivot", "unpivot")

# Verbs that modify state or escape the database.
_FORBIDDEN = {
    "insert", "update", "delete", "merge", "truncate",
    "drop", "create", "alter", "replace",
    "attach", "detach", "copy", "export", "import",
    "install", "load", "set", "reset", "call", "pragma",
    "grant", "revoke", "vacuum", "checkpoint",
}

# Functions that read or write the local filesystem.
_FORBIDDEN_FUNCTIONS = {
    "read_csv", "read_csv_auto", "read_parquet", "read_json", "read_json_auto",
    "read_text", "read_blob", "glob", "parquet_scan", "csv_scan",
}


# Schemas that exist but are build internals. The guidance tells the model to
# stay in `mart`; this makes it structural rather than advisory.
_BLOCKED_SCHEMAS = ("staging", "intermediate", "raw", "main", "information_schema", "pg_catalog")


class UnsafeSQL(Exception):
    """Raised when generated SQL is refused."""


def _strip_noise(sql: str) -> str:
    """Remove comments and string literals so keywords cannot hide inside them."""
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    sql = re.sub(r"'(?:[^']|'')*'", " '' ", sql)
    sql = re.sub(r'"(?:[^"]|"")*"', ' "" ', sql)
    return sql


def check(sql: str) -> str:
    """Return cleaned SQL, or raise UnsafeSQL explaining the refusal."""
    if not sql or not sql.strip():
        raise UnsafeSQL("The model returned an empty query.")

    cleaned = sql.strip().rstrip(";").strip()
    probe = _strip_noise(cleaned).lower()

    if ";" in _strip_noise(cleaned):
        raise UnsafeSQL("Only one statement may run at a time; the query contained a semicolon.")

    first = re.match(r"\s*(\w+)", probe)
    if not first or first.group(1) not in _ALLOWED_PREFIXES:
        kind = first.group(1) if first else "unknown"
        raise UnsafeSQL(f"Only read queries are allowed, but this one starts with '{kind}'.")

    words = set(re.findall(r"\b\w+\b", probe))

    # `create`/`set` etc. appearing anywhere is enough to refuse -- a CTE named
    # "created_at" survives because we match whole words only.
    hits = sorted(words & _FORBIDDEN)
    if hits:
        raise UnsafeSQL(f"Refused: the query uses restricted keyword(s): {', '.join(hits)}.")

    fn_hits = sorted(words & _FORBIDDEN_FUNCTIONS)
    if fn_hits:
        raise UnsafeSQL(
            f"Refused: the query reads from the filesystem via {', '.join(fn_hits)}. "
            "Only tables already in the database may be queried."
        )

    # Only the curated mart layer is queryable. Matching `schema.` prefixes keeps
    # this from tripping on a table alias that happens to share the name.
    for schema in _BLOCKED_SCHEMAS:
        if re.search(rf"\b{schema}\s*\.\s*\w", probe):
            raise UnsafeSQL(
                f"Refused: the query reads from the '{schema}' schema. "
                "Only the curated `mart` schema is available."
            )

    return cleaned

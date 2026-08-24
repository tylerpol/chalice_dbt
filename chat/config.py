"""Central configuration for the Chalice chat app.

Every tunable lives here so the install scripts and the app agree on one source
of truth. Changing the model is a one-line edit -- see MODEL below.
"""

from __future__ import annotations

import os
from pathlib import Path

# --- model -------------------------------------------------------------------

# Smallest model we trust for SQL over this schema plus a JSON chart spec.
# If answers are consistently wrong, step up to "qwen2.5-coder:7b" -- it is a
# drop-in replacement, roughly 4.7GB instead of 2GB.
MODEL = os.environ.get("CHALICE_MODEL", "qwen2.5-coder:3b")

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")

# Low temperature: we want the most probable SQL, not a creative one.
TEMPERATURE = 0.0

# Ollama defaults to a 4096-token window. The schema description alone is close
# to that, so without raising it the system prompt gets silently truncated and
# the model writes SQL against a schema it can no longer see -- which shows up as
# invented table names. qwen2.5-coder handles far more than this comfortably.
NUM_CTX = int(os.environ.get("CHALICE_NUM_CTX", "16384"))

# --- database ----------------------------------------------------------------

_HERE = Path(__file__).resolve().parent

# Two supported layouts, checked in order:
#   1. data/chalice.duckdb      -- the distributable zip
#   2. ../duckdb/chalice.duckdb -- this repository
_DB_CANDIDATES = [
    _HERE / "data" / "chalice.duckdb",
    _HERE.parent / "duckdb" / "chalice.duckdb",
]

# Schemas the assistant is told about and allowed to query.
#
# Deliberately just `mart` by default. Showing all four schemas describes the
# same entities four times over -- it triples the prompt and gives a small model
# many near-identical tables to confuse. The mart layer is the consumption layer
# and answers essentially every business question on its own.
#
# Set CHALICE_SCHEMAS="mart,staging,raw" to widen it.
VISIBLE_SCHEMAS = tuple(
    s.strip() for s in os.environ.get("CHALICE_SCHEMAS", "mart").split(",") if s.strip()
)

# Schemas surfaced first in the prompt.
PREFERRED_SCHEMAS = ("mart",)

# --- app ---------------------------------------------------------------------

APP_TITLE = "Chalice Chat"
PORT = int(os.environ.get("CHALICE_PORT", "8501"))

# Rows fetched from any single query. Guards against a runaway `select *`.
MAX_ROWS = 5000


def database_path() -> Path:
    """Return the first database file that exists, else the preferred location."""
    for candidate in _DB_CANDIDATES:
        if candidate.exists():
            return candidate
    return _DB_CANDIDATES[0]


def database_exists() -> bool:
    return any(candidate.exists() for candidate in _DB_CANDIDATES)

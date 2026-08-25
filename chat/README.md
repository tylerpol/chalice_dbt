# Chalice Chat

Ask the advertising warehouse questions in plain English and get back tables and
charts. Everything runs on your machine — the model, the database, and the app.
No API key, no account, nothing sent anywhere.

> **Optional.** The dbt project stands entirely on its own. This is an extra.

---

## Install

Double-click **`Install.command`** (macOS) or **`Install.bat`** (Windows), then
**`Start.command`** / **`Start.bat`** to run it. Or from a terminal:

```bash
cd chat
./install.sh
```

The double-click wrappers exist because Finder opens a `.sh` in a text editor
rather than running it, and Windows refuses to run a `.ps1` on double-click at
all. They only hand off to the real scripts.

The installer walks six steps with a progress bar and downloads the model
(~2GB, with Ollama's own live download bar).

**Ollama is installed for you if it is missing** — on macOS, Linux and Windows
alike. You are asked first, and told what will happen; `--yes` skips the
question for an unattended run. It needs:

- **Python 3.9+** — already present on macOS (via `xcode-select --install`) and
  on most Linux distributions. On Windows, `install_windows.ps1` installs it too.
- **~3GB disk** and **~3GB free RAM** while running

| Platform | Ollama comes from |
| :--- | :--- |
| macOS | `Ollama.app` unpacked into `/Applications` — no admin password |
| Linux | the official `ollama.com/install.sh` (uses sudo) |
| Windows | winget, falling back to the official silent installer |

If you already have Ollama, yours is used and nothing is installed. Set
`CHALICE_OLLAMA` to point at a copy in an unusual location.

## Run

```bash
./start.sh
```

Opens <http://localhost:8501> in your browser.

## Uninstall

```bash
./uninstall.sh
```

Removes the model (~2GB) and the Python environment. **Leaves Ollama itself
installed** — other tools may depend on it — and never touches the database or
the dbt project.

---

## How it works

```
your question
      ↓
local model (qwen2.5-coder:3b via Ollama)
      ↓  returns JSON: { sql, chart_type, x, y, title, explanation }
SQL guard  ── refuses anything that is not a read query
      ↓
DuckDB (opened read-only)
      ↓
Plotly renders the chart your app chose — not code the model wrote
```

**The model never writes executable code.** It returns a specification; the app
renders it. Ollama constrains the reply to a JSON schema using a grammar, so
malformed output is not possible — only *wrong* output is, which is why the
generated SQL is always displayed.

Three layers keep it safe:

| Layer | What it stops |
| :--- | :--- |
| Read-only DuckDB connection | Any write reaching the warehouse |
| `sql_guard.py` | Non-`SELECT` statements, multiple statements, filesystem access |
| No `exec()` anywhere | Model-authored code running at all |

The read-only connection also means the app can run *while* `dbt build` runs —
it never takes DuckDB's single write lock.

## Schema context

The dbt project runs with `persist_docs` enabled, so every column description
written in yml lives in DuckDB as a native comment. The app reads those comments
back and feeds them to the model. Documentation you already maintain becomes the
model's understanding of the data — there is no second copy to keep in sync.

The prompt also carries the known data traps (mixed timezones, negative
impressions, `billing_month` drift, the orphaned line item) so the model is less
likely to write a query that is technically valid and quietly wrong.

---

## Verify before you trust

A 3B model is small. It will sometimes write SQL that looks right and answers a
subtly different question. **The generated SQL is shown under every answer** —
read it. This is a tool for exploring, not a system of record.

## Files

| File | Purpose |
| :--- | :--- |
| `app.py` | Streamlit UI |
| `llm.py` | Ollama call and the JSON response schema |
| `sql_guard.py` | Read-only enforcement |
| `schema_context.py` | Pulls table/column comments out of DuckDB |
| `charts.py` | Chart spec → Plotly, with fallback to a table |
| `config.py` | Model, port, paths — change the model here |
| `_common.sh` / `_common.ps1` | Shared script helpers — locating and starting Ollama |
| `*.command` / `*.bat` | Double-click wrappers around the install/start/uninstall scripts |

## Configuration

```bash
CHALICE_MODEL=qwen2.5-coder:7b ./start.sh   # larger, more accurate
CHALICE_PORT=8600 ./start.sh                # different port
```

If answers are consistently poor, `qwen2.5-coder:7b` (~4.7GB) is a drop-in
upgrade — set it before running `install.sh` and it will be downloaded instead.

## Database location

Checked in order:

1. `chat/data/chalice.duckdb` — for a standalone zip
2. `../duckdb/chalice.duckdb` — this repository, after `dbt build`

## Troubleshooting

**"Cannot reach Ollama"** — re-run `./install.sh`; it starts the server for you.
If Ollama lives somewhere the scripts do not look, set `CHALICE_OLLAMA` to the
full path of the binary (on macOS that is inside the app bundle, at
`/Applications/Ollama.app/Contents/Resources/ollama`).

**"Could not read the database"** — a SQL IDE has it open for writing. DuckDB
allows one writer at a time; disconnect that client and reload.

**"No database found"** — run `dbt build` in the dbt project, or copy a built
`chalice.duckdb` into `chat/data/`.

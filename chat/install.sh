#!/usr/bin/env bash
#
# Chalice Chat installer -- macOS and Linux.
#
# Sets up a local Python environment, makes sure Ollama is present, downloads the
# language model, and leaves you ready to run ./start.sh. Nothing leaves your
# machine and nothing is installed system-wide except Ollama itself (which you
# are asked about first).
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODEL="${CHALICE_MODEL:-qwen2.5-coder:3b}"
VENV=".venv"
TOTAL_STEPS=6
STEP=0

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RESET=$'\033[0m'

bar() {
  local step=$1 total=$2 msg=$3 width=32
  local filled=$(( step * width / total ))
  local empty=$(( width - filled ))
  local f="" e=""
  [ "$filled" -gt 0 ] && f=$(printf '█%.0s' $(seq 1 "$filled"))
  [ "$empty"  -gt 0 ] && e=$(printf '░%.0s' $(seq 1 "$empty"))
  printf "\r  ${BOLD}[%s%s]${RESET} %d/%d  %-42s" "$f" "$e" "$step" "$total" "$msg"
}

step() { STEP=$((STEP + 1)); bar "$STEP" "$TOTAL_STEPS" "$1"; }
done_step() { printf "\r  ${BOLD}[%s]${RESET} %d/%d  ${GREEN}✓${RESET} %-40s\n" \
  "$(printf '█%.0s' $(seq 1 32))" "$STEP" "$TOTAL_STEPS" "$1"; }
fail() { printf "\n\n  ${RED}✗ %s${RESET}\n\n" "$1" >&2; exit 1; }
note() { printf "  ${DIM}%s${RESET}\n" "$1"; }

printf "\n  ${BOLD}Chalice Chat — installer${RESET}\n"
printf "  ${DIM}Local, private. Model: %s${RESET}\n\n" "$MODEL"

# 1 -------------------------------------------------------------------- python
step "Checking Python"
PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' 2>/dev/null; then
      PYTHON="$candidate"; break
    fi
  fi
done
[ -n "$PYTHON" ] || fail "Python 3.9+ is required but was not found. Install it from https://python.org and re-run."
done_step "Python ($($PYTHON --version 2>&1))"

# 2 ---------------------------------------------------------------------- venv
step "Creating virtual environment"
if [ ! -d "$VENV" ]; then
  "$PYTHON" -m venv "$VENV" || fail "Could not create a virtual environment in $VENV"
fi
done_step "Virtual environment ready"

# 3 ------------------------------------------------------------------ packages
step "Installing Python packages"
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
if ! "$VENV/bin/python" -m pip install --quiet -r requirements.txt; then
  fail "Installing Python packages failed. Re-run without --quiet to see why:
    $VENV/bin/python -m pip install -r requirements.txt"
fi
done_step "Python packages installed"

# 4 -------------------------------------------------------------------- ollama
step "Checking Ollama"
if ! command -v ollama >/dev/null 2>&1; then
  printf "\n\n  ${YELLOW}Ollama is not installed.${RESET} It runs the language model locally (~1GB).\n"
  if [ "$(uname -s)" = "Darwin" ]; then
    note "Install it from https://ollama.com/download, then re-run this script."
    fail "Ollama required."
  fi
  read -r -p "  Install it now via the official script? [y/N] " reply
  case "$reply" in
    [yY]*) curl -fsSL https://ollama.com/install.sh | sh || fail "Ollama installation failed." ;;
    *) fail "Ollama is required. Install it from https://ollama.com/download and re-run." ;;
  esac
fi
done_step "Ollama present"

# 5 ------------------------------------------------------------------- service
step "Starting Ollama service"
if ! curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then
  nohup ollama serve >/dev/null 2>&1 &
  for _ in $(seq 1 30); do
    sleep 1
    curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break
  done
fi
curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 \
  || fail "Ollama is installed but not responding on port 11434. Start it with 'ollama serve' and re-run."
done_step "Ollama service running"

# 6 --------------------------------------------------------------------- model
step "Downloading model"
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  done_step "Model already downloaded ($MODEL)"
else
  printf "\n\n  Downloading ${BOLD}%s${RESET} — about 2GB. Ollama shows live progress:\n\n" "$MODEL"
  ollama pull "$MODEL" || fail "Downloading $MODEL failed. Check your connection and re-run."
  printf "\n"
  done_step "Model downloaded ($MODEL)"
fi

# ------------------------------------------------------------------------ data
if [ ! -f data/chalice.duckdb ] && [ ! -f ../duckdb/chalice.duckdb ]; then
  printf "\n  ${YELLOW}Note:${RESET} no database found at data/chalice.duckdb.\n"
  note "Build it with 'dbt build' in the dbt project, or copy chalice.duckdb into chat/data/."
fi

printf "\n  ${GREEN}${BOLD}Done.${RESET} Start the app with:\n\n"
printf "      ${BOLD}./start.sh${RESET}\n\n"
printf "  It opens http://localhost:%s in your browser.\n" "${CHALICE_PORT:-8501}"
printf "  To remove the model and environment later: ${BOLD}./uninstall.sh${RESET}\n\n"

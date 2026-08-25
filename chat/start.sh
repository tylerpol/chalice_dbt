#!/usr/bin/env bash
#
# Launch Chalice Chat. Run ./install.sh first.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=_common.sh
. ./_common.sh

PORT="${CHALICE_PORT:-8501}"
BOLD=$'\033[1m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

[ -d .venv ] || { printf "\n  ${RED}Not installed yet.${RESET} Run 'bash install.sh' first.\n\n" >&2; exit 1; }

# Windows venvs put executables in Scripts/, everywhere else bin/.
if [ -d .venv/bin ]; then VENV_BIN=".venv/bin"; else VENV_BIN=".venv/Scripts"; fi

# Ollama must be up; starting it here means the user never has to think about it.
# It is resolved rather than assumed to be on PATH: install.sh may have put it in
# an .app bundle on macOS or a per-user directory on Windows.
if ! chalice_ollama_up; then
  OLLAMA="$(chalice_find_ollama || true)"
  if [ -z "$OLLAMA" ]; then
    printf "\n  ${RED}Ollama is not installed.${RESET} Run 'bash install.sh' first.\n\n" >&2
    exit 1
  fi
  printf "  ${DIM}Starting Ollama…${RESET}\n"
  chalice_start_ollama "$OLLAMA" || {
    printf "\n  ${RED}Ollama did not come up on port 11434.${RESET}\n"
    printf "  Try starting it yourself: ${BOLD}%s serve${RESET}\n\n" "$OLLAMA" >&2
    exit 1
  }
fi

printf "\n  ${BOLD}Chalice Chat${RESET} → http://localhost:%s\n" "$PORT"
printf "  ${DIM}Press Ctrl+C to stop.${RESET}\n\n"

exec "$VENV_BIN/streamlit" run app.py \
  --server.port "$PORT" \
  --server.address localhost \
  --server.headless false \
  --browser.gatherUsageStats false

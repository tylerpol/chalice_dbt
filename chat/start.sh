#!/usr/bin/env bash
#
# Launch Chalice Chat. Run ./install.sh first.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PORT="${CHALICE_PORT:-8501}"
BOLD=$'\033[1m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

[ -d .venv ] || { printf "\n  ${RED}Not installed yet.${RESET} Run ./install.sh first.\n\n" >&2; exit 1; }

# Ollama must be up; starting it here means the user never has to think about it.
if ! curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then
  printf "  ${DIM}Starting Ollama…${RESET}\n"
  nohup ollama serve >/dev/null 2>&1 &
  for _ in $(seq 1 30); do
    sleep 1
    curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break
  done
fi

printf "\n  ${BOLD}Chalice Chat${RESET} → http://localhost:%s\n" "$PORT"
printf "  ${DIM}Press Ctrl+C to stop.${RESET}\n\n"

exec .venv/bin/streamlit run app.py \
  --server.port "$PORT" \
  --server.address localhost \
  --server.headless false \
  --browser.gatherUsageStats false

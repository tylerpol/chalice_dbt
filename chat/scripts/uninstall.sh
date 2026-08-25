#!/usr/bin/env bash
#
# Remove what install.sh created: the language model and the Python environment.
#
# Ollama itself is left alone unless you explicitly ask -- you may have other
# models or other tools relying on it. Nothing here touches the database or any
# part of the dbt project.
#
set -euo pipefail

# This script lives in scripts/ but every path it touches -- the virtual
# environment, requirements.txt, app.py, data/ -- belongs to the app root one
# level up. Resolve both explicitly rather than depending on where it was run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
cd "$SCRIPT_DIR/.."

MODEL="${CHALICE_MODEL:-qwen2.5-coder:3b}"
OLLAMA="$(chalice_find_ollama || true)"
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

printf "\n  ${BOLD}Chalice Chat — uninstaller${RESET}\n\n"
printf "  This will remove:\n"
printf "    • the model ${BOLD}%s${RESET} (frees ~2GB)\n" "$MODEL"
printf "    • the local Python environment ${BOLD}chat/.venv${RESET}\n\n"
printf "  ${DIM}Your database, the dbt project, and Ollama itself are left untouched.${RESET}\n\n"

read -r -p "  Continue? [y/N] " reply
case "$reply" in
  [yY]*) ;;
  *) printf "\n  Cancelled. Nothing was removed.\n\n"; exit 0 ;;
esac

printf "\n"

# --- model -------------------------------------------------------------------
if [ -n "$OLLAMA" ]; then
  if "$OLLAMA" list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
    if "$OLLAMA" rm "$MODEL" >/dev/null 2>&1; then
      printf "  ${GREEN}✓${RESET} Removed model %s\n" "$MODEL"
    else
      printf "  ${YELLOW}!${RESET} Could not remove %s — remove it manually with:\n    %s rm %s\n" "$MODEL" "$OLLAMA" "$MODEL"
    fi
  else
    printf "  ${DIM}·${RESET} Model %s was not installed\n" "$MODEL"
  fi
else
  printf "  ${DIM}·${RESET} Ollama not found; no model to remove\n"
fi

# --- venv --------------------------------------------------------------------
if [ -d .venv ]; then
  rm -rf .venv
  printf "  ${GREEN}✓${RESET} Removed chat/.venv\n"
else
  printf "  ${DIM}·${RESET} No virtual environment to remove\n"
fi

# --- ollama itself -----------------------------------------------------------
if [ -n "$OLLAMA" ]; then
  remaining=$("$OLLAMA" list 2>/dev/null | tail -n +2 | grep -c . || true)
  printf "\n  Ollama is still installed"
  [ "$remaining" -gt 0 ] && printf " with %s other model(s)" "$remaining"
  printf ".\n"
  printf "  ${DIM}To remove it entirely, see https://ollama.com — this script leaves it in place\n"
  printf "  because other tools on your machine may depend on it.${RESET}\n"
fi

printf "\n  ${GREEN}${BOLD}Done.${RESET}\n\n"

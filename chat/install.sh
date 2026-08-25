#!/usr/bin/env bash
#
# Chalice Chat installer -- macOS, Linux, and Windows via Git Bash or WSL.
#
# Sets up a local Python environment, installs Ollama if it is missing, downloads
# the language model, and leaves you ready to run ./start.sh. Nothing leaves your
# machine. The only thing installed outside this folder is Ollama, and you are
# asked before that happens.
#
#   bash install.sh          ask before installing Ollama
#   bash install.sh --yes    assume yes (for an unattended run)
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=_common.sh
. ./_common.sh

MODEL="${CHALICE_MODEL:-qwen2.5-coder:3b}"
VENV=".venv"
TOTAL_STEPS=6
STEP=0
PLATFORM="$(chalice_platform)"

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

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

# Yes/no, unless --yes was passed. A non-interactive shell has no answer to give,
# so `read` fails and we treat that as "no" rather than hanging.
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local reply
  read -r -p "  $1 [y/N] " reply || return 1
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

printf "\n  ${BOLD}Chalice Chat — installer${RESET}\n"
printf "  ${DIM}Local, private. Model: %s${RESET}\n\n" "$MODEL"

# --- installing ollama -------------------------------------------------------

install_ollama_macos() {
  # /Applications when it is writable, the per-user one when it is not, so this
  # never needs an admin password.
  local tmp dest
  dest="/Applications"
  [ -w "$dest" ] || dest="$HOME/Applications"
  mkdir -p "$dest"
  tmp="$(mktemp -d)"

  printf "\n  Downloading Ollama for macOS (about 180MB)…\n\n"
  if ! curl -fL --progress-bar -o "$tmp/Ollama-darwin.zip" \
       "https://ollama.com/download/Ollama-darwin.zip"; then
    rm -rf "$tmp"; fail "Downloading Ollama failed. Check your connection and re-run."
  fi

  rm -rf "$dest/Ollama.app"
  # ditto is the right unpacker for an .app: it keeps the code signature intact,
  # which unzip does not, and a broken signature means Gatekeeper refuses to run it.
  if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$tmp/Ollama-darwin.zip" "$dest" || { rm -rf "$tmp"; fail "Unpacking Ollama failed."; }
  else
    unzip -q "$tmp/Ollama-darwin.zip" -d "$dest" || { rm -rf "$tmp"; fail "Unpacking Ollama failed."; }
  fi
  rm -rf "$tmp"

  [ -x "$dest/Ollama.app/Contents/Resources/ollama" ] \
    || fail "Ollama unpacked to $dest but the command line binary is not where it should be."
  note "Installed to $dest/Ollama.app"
}

install_ollama_windows() {
  # Git Bash. The native PowerShell path is install_windows.ps1; this covers the
  # reviewer who is already in a bash shell.
  local tmp exe i
  tmp="$(mktemp -d)"
  exe="$tmp/OllamaSetup.exe"

  printf "\n  Downloading the Ollama installer (about 1.5GB)…\n\n"
  if ! curl -fL --progress-bar -o "$exe" "https://ollama.com/download/OllamaSetup.exe"; then
    rm -rf "$tmp"; fail "Downloading Ollama failed. Check your connection and re-run."
  fi

  printf "\n  Running it silently — this takes a minute…\n"
  # Inno Setup flags. MSYS2_ARG_CONV_EXCL stops Git Bash rewriting /VERYSILENT
  # into a path before the installer ever sees it.
  MSYS2_ARG_CONV_EXCL='*' "$exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART \
    || { rm -rf "$tmp"; fail "The Ollama installer failed."; }
  rm -rf "$tmp"

  # Inno Setup can hand control back before the files have finished landing.
  for i in $(seq 1 60); do
    chalice_find_ollama >/dev/null 2>&1 && break
    sleep 2
  done
}

install_ollama_linux() {
  printf "\n"
  curl -fsSL https://ollama.com/install.sh | sh || fail "Ollama installation failed."
}

# 1 -------------------------------------------------------------------- python
step "Checking Python"
PYTHON=""
# `python` last: on Windows it is usually the only name that exists, but on
# older macOS it can still be Python 2, so the version check below decides.
for candidate in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' 2>/dev/null; then
      PYTHON="$candidate"; break
    fi
  fi
done
if [ -z "$PYTHON" ]; then
  case "$PLATFORM" in
    macos)
      fail "Python 3.9+ is required but was not found.
    macOS ships it with the developer tools — install them with:
        xcode-select --install
    then re-run this script. Or get an installer from https://python.org." ;;
    windows)
      fail "Python 3.9+ is required but was not found.
    Git Bash cannot install it for you. Either use the native Windows installer,
    which does it automatically:
        powershell -ExecutionPolicy Bypass -File install_windows.ps1
    or install Python from https://python.org (tick 'Add Python to PATH')." ;;
    *)
      fail "Python 3.9+ is required but was not found.
    Install it with your package manager (for example: sudo apt install python3-venv)
    or from https://python.org, then re-run." ;;
  esac
fi
done_step "Python ($($PYTHON --version 2>&1))"

# 2 ---------------------------------------------------------------------- venv
step "Creating virtual environment"
if [ ! -d "$VENV" ]; then
  "$PYTHON" -m venv "$VENV" || fail "Could not create a virtual environment in $VENV"
fi

# Windows puts the venv executables in Scripts/, every other platform in bin/.
if [ -d "$VENV/bin" ]; then VENV_BIN="$VENV/bin"; else VENV_BIN="$VENV/Scripts"; fi
[ -x "$VENV_BIN/python" ] || [ -x "$VENV_BIN/python.exe" ] \
  || fail "The virtual environment in $VENV looks incomplete -- no python in $VENV_BIN."
done_step "Virtual environment ready"

# 3 ------------------------------------------------------------------ packages
step "Installing Python packages"
"$VENV_BIN/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
if ! "$VENV_BIN/python" -m pip install --quiet -r requirements.txt; then
  fail "Installing Python packages failed. Re-run without --quiet to see why:
    $VENV_BIN/python -m pip install -r requirements.txt"
fi
done_step "Python packages installed"

# 4 -------------------------------------------------------------------- ollama
step "Checking Ollama"
OLLAMA="$(chalice_find_ollama || true)"
if [ -z "$OLLAMA" ]; then
  printf "\n\n  ${YELLOW}Ollama is not installed.${RESET} It runs the language model on this machine.\n"
  case "$PLATFORM" in
    macos)   note "Ollama.app will be unpacked into /Applications — no admin password needed." ;;
    linux)   note "The official installer will be run; it uses sudo to write /usr/local/bin." ;;
    windows) note "The official Windows installer will be run silently (~1.5GB download)." ;;
    *)       fail "Unrecognised platform ($(uname -s)). Install Ollama from https://ollama.com/download and re-run." ;;
  esac

  if ! confirm "Install it now?"; then
    fail "Ollama is required. Install it from https://ollama.com/download and re-run."
  fi

  case "$PLATFORM" in
    macos)   install_ollama_macos ;;
    linux)   install_ollama_linux ;;
    windows) install_ollama_windows ;;
  esac

  OLLAMA="$(chalice_find_ollama || true)"
  [ -n "$OLLAMA" ] || fail "Ollama was installed but cannot be found. Open a new terminal and re-run,
    or set CHALICE_OLLAMA to the full path of the ollama binary."
  STEP=$((STEP - 1)); step "Checking Ollama"
fi
done_step "Ollama present"

# 5 ------------------------------------------------------------------- service
step "Starting Ollama service"
chalice_start_ollama "$OLLAMA" \
  || fail "Ollama is installed at $OLLAMA but is not responding on port 11434.
    Start it manually with '$OLLAMA serve' and re-run."
done_step "Ollama service running"

# 6 --------------------------------------------------------------------- model
step "Downloading model"
if "$OLLAMA" list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  done_step "Model already downloaded ($MODEL)"
else
  printf "\n\n  Downloading ${BOLD}%s${RESET} — about 2GB. Ollama shows live progress:\n\n" "$MODEL"
  "$OLLAMA" pull "$MODEL" || fail "Downloading $MODEL failed. Check your connection and re-run."
  printf "\n"
  done_step "Model downloaded ($MODEL)"
fi

# ------------------------------------------------------------------------ data
if [ ! -f data/chalice.duckdb ] && [ ! -f ../duckdb/chalice.duckdb ]; then
  printf "\n  ${YELLOW}Note:${RESET} no database found at data/chalice.duckdb.\n"
  note "Build it with 'dbt build' in the dbt project, or copy chalice.duckdb into chat/data/."
fi

printf "\n  ${GREEN}${BOLD}Done.${RESET} Start the app with:\n\n"
printf "      ${BOLD}bash start.sh${RESET}\n\n"
printf "  It opens http://localhost:%s in your browser.\n" "${CHALICE_PORT:-8501}"
printf "  To remove the model and environment later: ${BOLD}bash uninstall.sh${RESET}\n\n"

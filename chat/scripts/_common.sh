# Shared helpers for install.sh, start.sh and uninstall.sh.
#
# Sourced, never executed. Everything here exists because Ollama is not always on
# PATH: when this installer puts it there itself, on macOS it lands inside an .app
# bundle and on Windows in a per-user directory, and in neither case does the
# current shell learn about it. Resolving the binary is therefore a shared
# concern, and keeping one copy of that logic is the point of this file.

# --- platform ----------------------------------------------------------------
chalice_platform() {
  case "$(uname -s)" in
    Darwin)               printf 'macos' ;;
    Linux)                printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *)                    printf 'unknown' ;;
  esac
}

# --- finding ollama ----------------------------------------------------------
# PATH wins: someone who installed Ollama themselves should get their copy, not
# whatever we unpacked. After that, the places each platform's installer uses.
chalice_find_ollama() {
  if [ -n "${CHALICE_OLLAMA:-}" ] && [ -x "${CHALICE_OLLAMA}" ]; then
    printf '%s' "$CHALICE_OLLAMA"; return 0
  fi

  if command -v ollama >/dev/null 2>&1; then
    command -v ollama; return 0
  fi

  # Under Git Bash %LOCALAPPDATA% is a backslashed Windows path, which no bash
  # test will match until cygpath translates it.
  local localappdata=""
  if [ -n "${LOCALAPPDATA:-}" ]; then
    if command -v cygpath >/dev/null 2>&1; then
      localappdata="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || true)"
    else
      localappdata="$LOCALAPPDATA"
    fi
  fi

  local candidate
  for candidate in \
    "/Applications/Ollama.app/Contents/Resources/ollama" \
    "${HOME:-}/Applications/Ollama.app/Contents/Resources/ollama" \
    "/usr/local/bin/ollama" \
    "/opt/homebrew/bin/ollama" \
    "${HOME:-}/.local/bin/ollama" \
    "${localappdata}/Programs/Ollama/ollama.exe" \
    "/c/Program Files/Ollama/ollama.exe"
  do
    case "$candidate" in ""|"/Programs/Ollama/ollama.exe") continue ;; esac
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done

  return 1
}

# --- the server --------------------------------------------------------------
chalice_ollama_up() {
  curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1
}

# Bring the server up if it is not already. $1 is the ollama binary.
chalice_start_ollama() {
  local bin="$1" i
  chalice_ollama_up && return 0
  nohup "$bin" serve >/dev/null 2>&1 &
  for i in $(seq 1 30); do
    sleep 1
    chalice_ollama_up && return 0
  done
  return 1
}

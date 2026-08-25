#!/usr/bin/env bash
#
# Double-clickable launcher for Chalice Chat.
#
# Finder runs a .command file in Terminal when you double-click it. A plain .sh
# opens in a text editor instead, which is the only reason this wrapper exists --
# everything real happens in start.sh.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Called through `bash` on purpose: that way only this file needs the executable
# bit, and unzip tools that drop it on start.sh cannot break the double-click.
bash ./start.sh "$@"
status=$?

echo
if [ "$status" -ne 0 ]; then
  printf '  Did not finish (exit code %s). The messages above say why.\n' "$status"
else
  printf '  The app has stopped.\n'
fi
read -r -p "  Press Return to close this window. "

#!/usr/bin/env bash
#
# Double-clickable installer for Chalice Chat.
#
# Finder runs a .command file in Terminal when you double-click it. A plain .sh
# opens in a text editor instead, which is the only reason this wrapper exists --
# everything real happens in scripts/install.sh.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Called through `bash` on purpose: that way only this file needs the executable
# bit, and unzip tools that drop it on scripts/install.sh cannot break the double-click.
bash ./scripts/install.sh "$@"
status=$?

echo
if [ "$status" -ne 0 ]; then
  printf '  Did not finish (exit code %s). The messages above say why.\n' "$status"
else
  printf '  Finished. Double-click Start_macOS.command to run the app.\n'
fi
read -r -p "  Press Return to close this window. "

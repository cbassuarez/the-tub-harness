#!/bin/zsh
set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.stage-devices.tub-harness-watchdog.plist"
LABEL="com.stage-devices.tub-harness-watchdog"
UID="$(/usr/bin/id -u)"

/usr/bin/launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
/usr/bin/launchctl disable "gui/$UID/$LABEL" >/dev/null 2>&1 || true

if [[ -f "$PLIST_PATH" ]]; then
  /bin/rm -f "$PLIST_PATH"
fi

echo "Uninstalled watchdog launch agent."

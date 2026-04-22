#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_SCRIPT="$SCRIPT_DIR/harness_watchdog.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.stage-devices.tub-harness-watchdog.plist"
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="$LOG_DIR/the-tub-harness-watchdog.stdout.log"
STDERR_LOG="$LOG_DIR/the-tub-harness-watchdog.stderr.log"
LABEL="com.stage-devices.tub-harness-watchdog"

if [[ ! -x "$WATCHDOG_SCRIPT" ]]; then
  echo "watchdog script missing or not executable: $WATCHDOG_SCRIPT" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$WATCHDOG_SCRIPT</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StartInterval</key>
  <integer>900</integer>

  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>

  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
</dict>
</plist>
PLIST

UID="$(/usr/bin/id -u)"
TARGET="gui/$UID/$LABEL"

/usr/bin/launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
/usr/bin/launchctl bootstrap "gui/$UID" "$PLIST_PATH"
/usr/bin/launchctl enable "$TARGET"
/usr/bin/launchctl kickstart -k "$TARGET"

echo "Installed launch agent: $PLIST_PATH"
echo "Watchdog script: $WATCHDOG_SCRIPT"
echo "Runs every 15 minutes with RunAtLoad enabled."
echo "Override defaults by setting environment vars in the script or your LaunchAgent config:"
echo "  TUB_HARNESS_APP_BUNDLE, TUB_HARNESS_INPUT_HINT, TUB_HARNESS_OUTPUT_HINT, TUB_HARNESS_MODE"

#!/bin/zsh
set -euo pipefail

APP_BUNDLE="${TUB_HARNESS_APP_BUNDLE:-/Applications/TheTubHarness.app}"
STATUS_URL="${TUB_HARNESS_STATUS_URL:-http://127.0.0.1:9911/status}"
MODE="${TUB_HARNESS_MODE:-performance}"
AUTOSTART="${TUB_HARNESS_AUTOSTART:-true}"
INPUT_HINT="${TUB_HARNESS_INPUT_HINT:-Scarlett}"
OUTPUT_HINT="${TUB_HARNESS_OUTPUT_HINT:-Lynx}"
USB_LOCATION_HINT="${TUB_HARDWARE_USB_LOCATION_HINT:-}"
SERIAL_HINT="${TUB_HARDWARE_SERIAL_HINT:-}"
LOG_FILE="${TUB_HARNESS_WATCHDOG_LOG:-$HOME/Library/Logs/the-tub-harness-watchdog.log}"

APP_BIN="$APP_BUNDLE/Contents/MacOS/TheTubHarness"

mkdir -p "$(dirname "$LOG_FILE")"

ts() {
  /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '%s %s\n' "$(ts)" "$1" >> "$LOG_FILE"
}

if [[ ! -x "$APP_BIN" ]]; then
  log "watchdog error: app binary not executable at $APP_BIN"
  exit 1
fi

status_json=""
if ! status_json=$(/usr/bin/curl -fsS --max-time 2 "$STATUS_URL" 2>/dev/null); then
  status_json=""
fi

is_running="false"
if [[ -n "$status_json" ]]; then
  is_running=$(/usr/bin/python3 - "$status_json" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    payload = json.loads(raw)
    print("true" if payload.get("isRunning") else "false")
except Exception:
    print("false")
PY
)
fi

if [[ "$is_running" == "true" ]]; then
  log "healthy: harness running"
  exit 0
fi

log "unhealthy: relaunching harness in performance mode"
/usr/bin/pkill -f "$APP_BIN" >/dev/null 2>&1 || true
/bin/sleep 2

args=(--mode "$MODE" --autostart "$AUTOSTART")
if [[ -n "$INPUT_HINT" ]]; then
  args+=(--input-hint "$INPUT_HINT")
fi
if [[ -n "$OUTPUT_HINT" ]]; then
  args+=(--output-hint "$OUTPUT_HINT")
fi

launch_env=()
if [[ -n "$USB_LOCATION_HINT" ]]; then
  launch_env+=("TUB_HARDWARE_USB_LOCATION_HINT=$USB_LOCATION_HINT")
fi
if [[ -n "$SERIAL_HINT" ]]; then
  launch_env+=("TUB_HARDWARE_SERIAL_HINT=$SERIAL_HINT")
fi

if (( ${#launch_env[@]} > 0 )); then
  /usr/bin/nohup /usr/bin/env "${launch_env[@]}" "$APP_BIN" "${args[@]}" >> "$LOG_FILE" 2>&1 &
else
  /usr/bin/nohup "$APP_BIN" "${args[@]}" >> "$LOG_FILE" 2>&1 &
fi

log "relaunch command issued: $APP_BIN ${args[*]}"

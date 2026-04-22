# The Tub Harness Watchdog

This watchdog checks the harness every 15 minutes and relaunches it when not actively running.

## What it does

- Calls `http://127.0.0.1:9911/status`.
- If `isRunning != true`, it relaunches TheTubHarness with:
  - `--mode performance`
  - `--autostart true`
  - `--input-hint Scarlett`
  - `--output-hint Lynx`

The app now supports those launch flags directly, so this works on other Macs without hardcoded device UIDs.

## Install on a show machine

From repo root:

```bash
./scripts/watchdog/install_watchdog_launch_agent.sh
```

This installs a LaunchAgent at:

- `~/Library/LaunchAgents/com.stage-devices.tub-harness-watchdog.plist`

and runs every 900 seconds (15 minutes), plus once at load.

## Default assumptions

- App bundle path: `/Applications/TheTubHarness.app`
- Input hint: `Scarlett`
- Output hint: `Lynx`
- Mode: `performance`

## Override settings

Edit `scripts/watchdog/harness_watchdog.sh` variables or provide env vars via launchd:

- `TUB_HARNESS_APP_BUNDLE`
- `TUB_HARNESS_STATUS_URL`
- `TUB_HARNESS_MODE`
- `TUB_HARNESS_AUTOSTART`
- `TUB_HARNESS_INPUT_HINT`
- `TUB_HARNESS_OUTPUT_HINT`
- `TUB_HARNESS_WATCHDOG_LOG`
- `TUB_HARDWARE_USB_LOCATION_HINT` (example: `1110000`)
- `TUB_HARDWARE_SERIAL_HINT` (substring match on `/dev/cu.*` path)

## Logs

- `~/Library/Logs/the-tub-harness-watchdog.log`
- `~/Library/Logs/the-tub-harness-watchdog.stdout.log`
- `~/Library/Logs/the-tub-harness-watchdog.stderr.log`

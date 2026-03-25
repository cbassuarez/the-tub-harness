# the-tub-harness

Swift harness for THE TUB.

## Manifests

Manifest-backed routing is in:

- `TheTubHarness/TheTubHarness/Manifests/banks.json`
- `TheTubHarness/TheTubHarness/Manifests/instruments.json`
- `TheTubHarness/TheTubHarness/Manifests/chords.json`
- `TheTubHarness/TheTubHarness/Manifests/motifs.json`
- `TheTubHarness/TheTubHarness/Manifests/spatial_patterns.json`

At startup, the app validates that mode-default picks resolve against these manifests. Missing IDs are logged and deterministic per-mode defaults are used.

`instruments.json` is sampler-oriented:
- `type` must be `sampler`
- one of `sample_pack_path` or `soundfont_path` or `sampler_preset_ref`
- optional shaping metadata: `gain_db`, `polyphony_hint`, `velocity_layers`, `round_robin_count`

## Run app

```bash
open /Users/seb/the-tub-harness/TheTubHarness/TheTubHarness.xcodeproj
```

Start the model server first:

```bash
cd /Users/seb/the-tub-ml
source .venv/bin/activate
tub-ml serve --config configs/stub_policy_v1.yaml
```

In the app UI, `Audio + Real Features` is the default run profile and the top-row `Input` picker shows/selects the active microphone or line input device.
The output path is input-driven (no synthetic test-tone fallback in the mode engine).

Input recording toggle:
- UI: `Record Input Audio (CAF)` switch (default `OFF` unless overridden by launch arg)
- launch arg: `--record-input-audio true|false`

When the run loop starts, the harness creates:
- `sessions/<session_id>/frames_<session_id>.jsonl`
- `sessions/<session_id>/events_<session_id>.jsonl`
- `sessions/<session_id>/session_meta_<session_id>.json`
- `sessions/<session_id>/input_<session_id>.caf` (only when recording is enabled)
- `bundles/bundle_<YYYY-MM-DD>_<rev>.json`

and prints:
- `running bundle <bundle_id> (policy=..., banks=..., contract=...)`

Live human labels (sticky) in the UI:
- `1` or `Good` button -> `good`
- `2` or `Too Much` button -> `too_much`
- `3` or `Too Flat` button -> `too_flat`
- `0` or `Clear Label` -> `null`

## Replay mode (headless)

The app binary supports:

```bash
--replay <trace.jsonl> [--speed <float>] [--out <output.jsonl>] [--bundle-id <id>] [--host <ip>] [--port <udp_port>]
```

`speed` behavior:
- `1.0` = recorded cadence
- `>1.0` = accelerated
- `0` = as fast as possible

If `--bundle-id` is set, replay output lines use that bundle id. Otherwise replay preserves any bundle id present in the input trace.

Example:

```bash
xcodebuild -scheme TheTubHarness -project /Users/seb/the-tub-harness/TheTubHarness/TheTubHarness.xcodeproj -destination 'platform=macOS' build
APP_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*TheTubHarness.app/Contents/MacOS/TheTubHarness' | head -n 1)
"$APP_BIN" --replay /Users/seb/the-tub-harness/fixtures/golden_trace.jsonl --speed 0 --out /tmp/the-tub-replay-out.jsonl
```

If `--out` points to a path blocked by app sandbox permissions, replay falls back to the app log directory and prints a warning.

## Replay by Session ID (with audio injection)

From the app UI:

- Enter a `Replay session_id`
- Click `Start Replay`
- Optional: `Seek Replay` (seconds)
- Click `Stop Replay` to cancel

Replay behavior:
- Replayer loads `session_meta_<session_id>.json` + frame/event logs.
- If `input_<session_id>.caf/.wav` exists, replay injects that file into the same input bus path used by live mic/line input.
- Frame playback is paced against replay-audio time using recorded frame timestamps.
- If input audio is missing, replay still runs frame-stream replay and logs `{"replay_audio_missing":true,...}`.

## Tests

Unit tests:

```bash
cd /Users/seb/the-tub-harness
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj -destination 'platform=macOS' -only-testing:TheTubHarnessTests test
```

Golden trace integration replay test (requires model server running):

```bash
cd /Users/seb/the-tub-harness
RUN_GOLDEN_TRACE=1 MODEL_HOST=127.0.0.1 MODEL_PORT=9910 xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj -destination 'platform=macOS' -only-testing:TheTubHarnessTests test
```

Mode contract reference: `docs/mode-contract.md`.

## Mode verification by ear (including 5/6 MIDI-resonification)

With the model server running, pick `Audio + Real Features`, select your mic/line input, and verify:

- Mode `1` (Beat Repeat): onset+threshold gated stutters, quantized to grid (`1/8` or `1/16`), spatial changes step on grid.
- Mode `4` (Clean + samples + resynthesis): clean bed always present; gesture layer adds sparse sample/resynth responses with bounded concurrency.
- Mode `5` (MIDI-resonification wet-only): only resonifier/sampler layer audible; CLEAR releases voices; JOLT audibly pushes harmony/energy.
- Mode `6` (Parallel dry + resonifier): dry input stays centered while resonifier voices are spatialized; CLEAR releases voices cleanly.
- Mode `7` (Swap Buckets): wet-dominant stepped spectral redistribution with deterministic bucket-scene swaps and crossfaded handoffs (`crossfade_ms`), so band roles audibly move instead of sounding like broad filtering.
- Mode `0` (Clean): mostly dry input, subtle room reverb, minimal motion.
- Mode `2` (Granulator): discontinuous “shattered time” texture from your input; density responds quickly.
- Mode `3` (Roar/Resonator): resonant wet layer over punchy dry; distortion/bit reduction remains bounded.
- Mode `8` (Spatial dry + diffuse verb): dry image moves as one point source; reverb stays diffuse.
- Mode `9` (3-band spatial split): low/mid/high parts of dry input spread differently in space, no particle/MIDI behavior.

Safety rails that should always hold:

- No mode flip as a safety response (mode follows UI switch only).
- Reverb wet capped (`<= 0.50`) and decay bounded.
- Master limiter catches peaks (ceiling `-1 dBFS`).
- Mode `5` hard-caps at `8` resonifier voices and `12` notes/sec; mode `6` hard-caps at `3` voices and `6` notes/sec.

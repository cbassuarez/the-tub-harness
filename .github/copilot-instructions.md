# GitHub Copilot Instructions for the-tub-harness

This is **THE TUB HARNESS**, a macOS SwiftUI application that serves as the real-time audio processing engine for THE TUB. It communicates with an external ML model server over UDP at 10 Hz, processes live audio input through 11 DSP modes (0–10), logs training substrate data as JSONL, and renders an interactive visual stage.

See `CLAUDE.md` for additional context and conventions.

## Build & Test Commands

### Build the App

```bash
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' build
```

### Run Unit Tests

```bash
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' -only-testing:TheTubHarnessTests test
```

### Run Golden Trace Integration Test

Requires a model server running on `127.0.0.1:9910` (see README.md for setup).

```bash
RUN_GOLDEN_TRACE=1 MODEL_HOST=127.0.0.1 MODEL_PORT=9910 \
  xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' -only-testing:TheTubHarnessTests test
```

### Run the App

```bash
open TheTubHarness/TheTubHarness.xcodeproj
```

**Important**: The model server must be running before starting the harness. Start it first:

```bash
cd /path/to/the-tub-ml
source .venv/bin/activate
tub-ml serve --config configs/stub_policy_v1.yaml
```

## Architecture Overview

### Core 10 Hz Frame Loop

`TubMLClient` drives the main event loop:
1. Packages `ModelIn` (audio features, button state, mode, session metadata)
2. Sends via UDP to the model server
3. Decodes `ModelOut` response
4. Publishes via `@Published` properties for UI and audio engine

`AudioEngineController` observes model output and applies mode-specific DSP to the live audio graph.

`ContentView` aggregates state from both into a 4-panel control room UI.

### Data Structures

**Packet types** (`ModelPackets.swift`):
- `ModelIn`: Features (envelope, onset, spectrum), button presses, current mode, session state
- `ModelOut`: Params, picks (preset/bank/instrument selections), flags, visual output
- `Features`, `Picks`, `Flags`, `VisualOut`: Substruct types

JSON wire format uses **snake_case**; decoded via `JSONDecoder.convertFromSnakeCase`. Unknown keys are rejected in strict decode.

### Protocol Contract

`ModeContract.swift` locks the control surface contract — canonical parameters, bounds, required picks, visual scene vocabulary, and safe defaults for all 11 modes. The contract has a pinned SHA-256 fingerprint (`ModeContract.lockedContractFingerprint`).

**Critical rule**: Fingerprint mismatches between harness and model are release blockers. If you change contract tables or the visual head schema, bump `supportedProtocolVersion` and `contractVersion`, update `lockedContractFingerprint`, and add test coverage.

### Parameter Resolution

`ModeEngine.swift` resolves params from `ModelOut` with legacy alias fallback and safe defaults. `AudioControl` is the full state struct consumed by `AudioEngineController`.

### Manifest Routing

`ManifestCatalog.swift` loads JSON manifests from `Manifests/`:
- `banks.json`: Bank definitions
- `instruments.json`: Sampler specs (must have `type: "sampler"`, one of `sample_pack_path`/`soundfont_path`/`sampler_preset_ref`, optional gain/polyphony metadata)
- `chords.json`, `motifs.json`, `spatial_patterns.json`: Mode-specific assets

All picks (preset_id, bank_id, etc.) resolve against these tables. Missing IDs fall back to deterministic per-mode defaults.

### Logging & Session Artifacts

`JSONLLogger.swift` writes per-session:
- `frames_*.jsonl`: 10 Hz frame log with model I/O, interventions, human labels
- `events_*.jsonl`: Discrete events
- `session_meta_*.json`: Session metadata (timestamp, bundle ID, contract fingerprint, policy, banks loaded)
- `input_*.caf`: Optional input audio recording (CAF format, toggle via UI or `--record-input-audio` launch arg)
- `bundles/bundle_<YYYY-MM-DD>_<rev>.json`: Bundle manifest

On startup, the app prints: `running bundle <bundle_id> (policy=..., banks=..., contract=...)` with `fp=<fingerprint_prefix>` and `lock=<ok|mismatch>`.

See `docs/log_schema.md` for the full JSONL schema.

### Visual Stage

`VideoOutputController.swift` maps `VisualOut` to scene parameters.

`VideoStageView.swift` renders the stage at 24 Hz using SwiftUI Canvas. The visual system recognizes 6 scene IDs and a vocabulary of "thoughts" (idle, listening, tracking_bass, tracking_mids, tracking_highs, following_brightness, responding_to_transient, building_density).

### Replay

The app supports two replay modes:

1. **Headless CLI replay** via launch args:
   ```
   --replay <trace.jsonl> [--speed <float>] [--out <output.jsonl>] [--bundle-id <id>] [--host <ip>] [--port <udp_port>]
   ```
   Speed: `1.0` = recorded cadence, `>1.0` = accelerated, `0` = as fast as possible.
   
   See `ReplayCLI.swift`.

2. **Interactive session replay** from the UI:
   - Enter a `Replay session_id` and click `Start Replay`
   - Optional: `Seek Replay` (seconds)
   - If `input_<session_id>.caf/.wav` exists, replay injects it into the live audio bus
   - Frame playback paces against replay-audio time using recorded timestamps

## Key Conventions

### Threading & Concurrency

- **Main thread**: All UI bindings and `@Published` properties
- **Utility/UserInitiated queues**: Audio engine, logging, networking, feature extraction
- Tests use the `@MainActor` annotation where UI state is accessed

### Tests Use Swift Testing

All tests import `Testing` and use the `@Test` macro and `#expect` assertions, **not** XCTest.

Example:
```swift
@Test("ModelOut decodes expected snake_case payload")
func modelOutDecodeHappyPath() throws {
    let out = try decoder.decode(ModelOut.self, from: payload)
    #expect(out.protocolVersion == ModeContract.supportedProtocolVersion)
}
```

### Observable Architecture

`TubMLClient` and `AudioEngineController` are `@ObservableObject`; UI binds via `@Published` properties through Combine.

### Audio Safety Rails (Non-Negotiable)

- **No mode flip as a safety response** — mode follows UI switch only
- **Reverb wet ≤ 0.50** and decay bounded
- **Master limiter ceiling at −1 dBFS**
- **Mode 5 voice caps**: 8 resonifier voices, 12 notes/sec max
- **Mode 6 voice caps**: 3 resonifier voices, 6 notes/sec max

### Naming & Serialization

- **JSON manifests & wire format**: snake_case (e.g., `spatial_pattern_id`, `sample_pack_path`)
- **Swift code**: camelCase (e.g., `spatialPatternId`, `samplePackPath`)

### Human Labels

Sticky labels in the UI:
- `1` or `Good` → `good`
- `2` or `Too Much` → `too_much`
- `3` or `Too Flat` → `too_flat`
- `0` or `Clear Label` → `null`

These are recorded in the frame log.

## Documentation References

- `docs/mode-contract.md`: Protocol v2 spec, canonical params, aliases, required picks, bounds per mode, visual head schema
- `docs/log_schema.md`: JSONL training substrate schema for frames, events, session metadata

## Mode Overview (for Ear Verification)

With the model server running:

- **Mode 0** (Clean): Dry input, subtle room reverb, minimal motion
- **Mode 1** (Beat Repeat): Onset+threshold gated stutters quantized to grid (1/8 or 1/16)
- **Mode 2** (Granulator): Discontinuous "shattered time" texture; density responds quickly
- **Mode 3** (Roar/Resonator): Resonant wet layer over punchy dry; distortion/bit reduction bounded
- **Mode 4** (Clean + samples + resynthesis): Clean bed with sparse sample/resynth gesture layer
- **Mode 5** (MIDI-resonification wet-only): Only resonifier/sampler audible; CLEAR releases voices; JOLT pushes harmony
- **Mode 6** (Parallel dry + resonifier): Dry centered, resonifier voices spatialized; CLEAR releases cleanly
- **Mode 7** (Swap Buckets): Wet-dominant stepped spectral redistribution with deterministic bucket-scene swaps
- **Mode 8** (Spatial dry + diffuse verb): Dry image as point source; reverb stays diffuse
- **Mode 9** (3-band spatial split): Low/mid/high parts spread differently; no particle/MIDI behavior
- **Mode 10** (Reserved/experimental): Check `ModeContract.swift` for current spec

## Launch Arguments

The app supports several launch args:

```bash
--record-input-audio true|false     # Enable/disable input audio recording (default: OFF unless overridden)
--replay <path.jsonl>               # Load and replay a golden trace
--speed <float>                     # Replay speed (1.0 = normal, 0 = as fast as possible)
--out <path.jsonl>                  # Replay output destination
--bundle-id <id>                    # Override bundle ID in replay output
--host <ip>                         # Model server IP (default: localhost)
--port <port>                       # Model server UDP port (default: 9910)
```

## Input Recording & Output

The app creates a session directory with:
- `sessions/<session_id>/frames_<session_id>.jsonl`
- `sessions/<session_id>/events_<session_id>.jsonl`
- `sessions/<session_id>/session_meta_<session_id>.json`
- `sessions/<session_id>/input_<session_id>.caf` (optional, if recording enabled)
- `bundles/bundle_<YYYY-MM-DD>_<rev>.json`

**Input picker** in the UI shows/selects active microphone or line input device. The output path is input-driven (no synthetic test-tone fallback).

## Debugging & Development Tips

### Run Tests with Verbose Output

```bash
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' -only-testing:TheTubHarnessTests test -v
```

### Build Cache Troubleshooting

If you encounter stale build artifacts:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' clean build
```

### Inspect Test Artifacts

After running tests, check the derived data directory:

```bash
ls -la ~/Library/Developer/Xcode/DerivedData/
```

The test bundle and logs are in the project's Xcode build folder.

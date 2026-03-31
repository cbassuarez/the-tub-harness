# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

THE TUB HARNESS — a macOS SwiftUI app that acts as the real-time audio processing harness for THE TUB. It communicates with an external ML model server over UDP at 10 Hz, processes live audio input through 11 DSP modes (0–10), logs training substrate data as JSONL, and renders a visual stage.

## Build & Test

```bash
# Build
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' build

# Unit tests
xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' -only-testing:TheTubHarnessTests test

# Golden trace integration test (requires model server on localhost:9910)
RUN_GOLDEN_TRACE=1 MODEL_HOST=127.0.0.1 MODEL_PORT=9910 \
  xcodebuild -scheme TheTubHarness -project TheTubHarness/TheTubHarness.xcodeproj \
  -destination 'platform=macOS' -only-testing:TheTubHarnessTests test
```

Tests use Swift Testing (`import Testing`, `@Test` macro, `#expect`), not XCTest.

## Architecture

**Core loop**: `TubMLClient` drives a 10 Hz frame loop — it packages `ModelIn` (features, buttons, mode, session state), sends it to the model server via UDP, decodes the `ModelOut` response, and publishes it. `AudioEngineController` observes the model output and applies mode-specific DSP to the live audio graph. `ContentView` aggregates state from both into a 4-panel control room UI.

**Protocol v2 contract**: `ModeContract.swift` defines the locked contract — canonical params, bounds, required picks, legacy aliases, visual-head schema, and safe defaults for all 11 modes. The contract has a pinned fingerprint (`ModeContract.lockedContractFingerprint`). Fingerprint mismatches between harness and model are release blockers. If you change contract tables or visual schema, bump the protocol/contract version and update the fingerprint in lockstep.

**Packet types**: `ModelPackets.swift` defines `ModelIn`, `ModelOut`, `Features`, `Picks`, `Flags`, `VisualOut`. JSON wire format is snake_case; decoded via `JSONDecoder.convertFromSnakeCase`. Unknown keys are rejected in strict decode.

**Param resolution**: `ModeEngine.swift` resolves params from `ModelOut` with legacy alias fallback and safe defaults. `AudioControl` is the full state struct consumed by the audio engine.

**Manifest routing**: `ManifestCatalog.swift` loads JSON manifests from `Manifests/` (banks, instruments, chords, motifs, spatial_patterns). All picks (preset_id, bank_id, etc.) resolve against these tables. Missing IDs fall back to deterministic per-mode defaults.

**Logging**: `JSONLLogger.swift` writes session artifacts — `frames_*.jsonl` (10 Hz with model I/O, interventions, human labels), `events_*.jsonl`, `session_meta_*.json`. See `docs/log_schema.md`.

**Visual stage**: `VideoOutputController.swift` maps `VisualOut` to scene parameters. `VideoStageView.swift` renders at 24 Hz using SwiftUI Canvas.

**Replay**: The app supports headless replay via CLI args (`--replay <trace.jsonl> --speed <float> --out <path>`). See `ReplayCLI.swift`. UI replay loads sessions by ID and optionally injects recorded input audio.

## Key Conventions

- Observable architecture: `TubMLClient` and `AudioEngineController` are `@ObservableObject`; UI binds via `@Published` properties through Combine.
- Audio safety rails are non-negotiable: reverb wet ≤ 0.50, limiter ceiling at −1 dBFS, per-mode voice caps (mode 5: 8 voices, mode 6: 3 voices). No mode flip as a safety response.
- `mode` is always 0–10 and follows the UI switch only.
- JSON manifests use snake_case; Swift code uses camelCase.
- Threading: main thread for UI, utility/userInitiated queues for audio, logging, and networking.

## Docs

- `docs/mode-contract.md` — Protocol v2 spec: canonical params, aliases, required picks, bounds per mode, visual head schema.
- `docs/log_schema.md` — JSONL training substrate schema for frames, events, and session metadata.

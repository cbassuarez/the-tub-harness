//
//  TheTubHarnessTests.swift
//  TheTubHarnessTests
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import Foundation
import AVFoundation
import Testing
@testable import TheTubHarness

@MainActor
struct TheTubHarnessTests {

    @Test("ModelOut decodes expected snake_case payload")
    func modelOutDecodeHappyPath() throws {
        let payload = """
        {
          "protocol_version": 1,
          "ts_ms": 123456789,
          "mode": 2,
          "params": {
            "level": 0.6,
            "brightness": 0.4,
            "density": 0.2
          },
          "picks": {
            "preset_id": "gran_A",
            "spatial_pattern_id": "orbit_slow"
          },
          "flags": {
            "request_cooldown": false,
            "prefer_stability": true,
            "thin_events": false
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let out = try decoder.decode(ModelOut.self, from: payload)

        #expect(out.protocolVersion == 1)
        #expect(out.mode == 2)
        #expect(out.picks.presetId == "gran_A")
        #expect(out.picks.spatialPatternId == "orbit_slow")
        #expect(out.params["level"] == 0.6)
    }

    @Test("ModelOut decoding rejects unknown fields and invalid mode")
    func modelOutDecodeIsStrict() {
        let payload = """
        {
          "ts_ms": 123456789,
          "mode": 99,
          "params": { "level": 0.5 },
          "picks": { "preset_id": "gran_A" },
          "flags": { "request_cooldown": false, "prefer_stability": true, "thin_events": false },
          "unexpected_field": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        #expect(throws: Error.self) {
            _ = try decoder.decode(ModelOut.self, from: payload)
        }
    }

    @Test("FeatureExtractor tracks sine centroid and bands")
    func featureExtractorSine() {
        let sampleRate = 48_000.0
        let freq = 1_000.0
        let count = Int(sampleRate * 0.1)

        let samples: [Float] = (0..<count).map { i in
            Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
        }

        let extractor = FeatureExtractor(sampleRate: sampleRate)
        let features = extractor.extract(samples: samples)

        #expect(features.loudnessLufs.isFinite)
        #expect(features.specCentroidHz > 800)
        #expect(features.specCentroidHz < 1200)
        #expect(features.bandMid > features.bandLow)
        #expect(features.bandMid > features.bandHigh)
        #expect(features.bandLow >= 0 && features.bandLow <= 1)
        #expect(features.bandMid >= 0 && features.bandMid <= 1)
        #expect(features.bandHigh >= 0 && features.bandHigh <= 1)
        #expect(features.noisiness >= 0 && features.noisiness <= 1)
        #expect(features.pitchConf >= 0 && features.pitchConf <= 1)
        if let pitch = features.pitchHz, features.pitchConf > 0.2 {
            #expect(pitch.isFinite)
            #expect(pitch > 40)
            #expect(pitch < 2_000)
        }
        #expect(features.keyConf >= 0 && features.keyConf <= 1)
    }

    @Test("TraceRecord encodes/decodes and loads replay frames")
    func traceRoundTrip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("thetub-trace-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = try TraceRecorder(sessionId: "unit", directory: dir)

        let modelIn = ModelIn(
            protocolVersion: 1,
            tsMs: 1_000,
            sessionId: "test",
            frameHz: 10,
            mode: 2,
            buttons: Buttons(jolt: false, clear: false),
            features: Features(
                loudnessLufs: -24,
                onsetRateHz: 1.2,
                specCentroidHz: 1_800,
                bandLow: 0.3,
                bandMid: 0.5,
                bandHigh: 0.2,
                noisiness: 0.4
            ),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0)
        )

        let record = TraceRecord(
            recordedAtMs: 1_001,
            modelIn: modelIn,
            modelOut: nil,
            diagnostics: TraceDiagnostics(
                requestId: 1,
                sendTsMs: 1_000,
                recvTsMs: nil,
                roundTripMs: nil,
                timedOut: true,
                decodeError: nil,
                interventions: ["timeout"]
            ),
            featureSource: "audio_in",
            fallbackReason: nil,
            sentPacketJson: "{}"
        )

        recorder.append(record)
        recorder.close()

        let lines = try String(contentsOf: recorder.url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 1)

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try dec.decode(TraceRecord.self, from: Data(lines[0].utf8))

        #expect(decoded.modelIn.mode == 2)
        #expect(decoded.modelIn.protocolVersion == 1)
        #expect(decoded.diagnostics.timedOut)

        let replayFrames = try TraceRecorder.loadReplayFrames(from: recorder.url)
        #expect(replayFrames.count == 1)
        #expect(replayFrames[0].modelIn.mode == 2)
    }

    @Test("ModeContract clamps params and validates picks")
    func modeContractClampAndValidate() {
        let clamped = ModeContract.clamp(
            params: [
                "grain_density": 2.0,
                "freeze_prob": -1.0,
                "grain_size_ms": 40.0,
                "not_allowed": 0.2,
            ],
            mode: 2
        )
        #expect(clamped.clamped["grain_density"] == 0.9)
        #expect(clamped.clamped["freeze_prob"] == 0.0)
        #expect(clamped.clamped["grain_size_ms"] == 40.0)
        #expect(clamped.clamped["not_allowed"] == nil)
        #expect(clamped.violations.contains(where: { $0.contains("param_not_allowed:not_allowed") }))

        let pickViolations = ModeContract.validate(
            picks: Picks(presetId: nil, bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: nil, sceneId: nil),
            mode: 2
        )
        #expect(pickViolations.contains("missing_pick:preset_id"))
        #expect(pickViolations.contains("missing_pick:spatial_pattern_id"))
    }

    @Test("ModeContract accepts legacy aliases for modes 0, 1, 4, 7, 8, 9")
    func modeContractLegacyAliases() {
        let mode0 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 0,
            params: [
                "reverb_size": 0.18,
                "reverb_decay": 0.32,
            ],
            picks: ModeContract.defaultPicksByMode[0] ?? Picks(),
            flags: Flags()
        )
        let enforced0 = ModeContract.enforceIncoming(modelOut: mode0, currentMode: 0)
        #expect(enforced0.1.isEmpty)
        #expect(enforced0.0.params["reverb_mix"] == 0.18)

        let mode1 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 1,
            params: [
                "repeat_grid": 0.33,
                "stutter_len": 0.44,
                "motion_speed": 0.55,
            ],
            picks: ModeContract.defaultPicksByMode[1] ?? Picks(),
            flags: Flags()
        )
        let enforced1 = ModeContract.enforceIncoming(modelOut: mode1, currentMode: 1)
        #expect(enforced1.1.isEmpty)
        #expect(enforced1.0.params["loop_len_s"] != nil)
        #expect(enforced1.0.params["stutter_len_ms"] != nil)
        #expect(enforced1.0.params["motion_speed"] == 0.55)

        let mode4 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 4,
            params: [
                "sample_level": 0.31,
                "interruptiveness": 0.63,
                "memory_weight": 0.42,
            ],
            picks: ModeContract.defaultPicksByMode[4] ?? Picks(),
            flags: Flags()
        )
        let enforced4 = ModeContract.enforceIncoming(modelOut: mode4, currentMode: 4)
        #expect(enforced4.1.isEmpty)
        #expect(enforced4.0.params["sample_mix"] == 0.31)
        #expect(enforced4.0.params["density"] == 0.63)
        #expect(enforced4.0.params["stability"] == 0.42)

        let mode7 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 7,
            params: [
                "swap_rate": 0.66,
            ],
            picks: ModeContract.defaultPicksByMode[7] ?? Picks(),
            flags: Flags()
        )
        let enforced7 = ModeContract.enforceIncoming(modelOut: mode7, currentMode: 7)
        #expect(enforced7.1.isEmpty)
        #expect(enforced7.0.params["swap_rate_hz"] != nil)

        let mode8 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 8,
            params: [
                "motion_speed": 0.35,
                "spread": 0.70,
                "reverb_rand_amt": 0.22,
                "reverb_decay": 0.40,
            ],
            picks: ModeContract.defaultPicksByMode[8] ?? Picks(),
            flags: Flags()
        )
        let enforced8 = ModeContract.enforceIncoming(modelOut: mode8, currentMode: 8)
        #expect(enforced8.1.isEmpty)
        #expect(enforced8.0.params["spread"] == 0.70)
        #expect(enforced8.0.params["reverb_rand_amt"] == 0.22)

        let mode9 = ModelOut(
            protocolVersion: 1,
            tsMs: 1000,
            mode: 9,
            params: [
                "band_low": 0.41,
                "band_high": 0.36,
                "motion_speed": 0.47,
            ],
            picks: ModeContract.defaultPicksByMode[9] ?? Picks(),
            flags: Flags()
        )
        let enforced9 = ModeContract.enforceIncoming(modelOut: mode9, currentMode: 9)
        #expect(enforced9.1.isEmpty)
        #expect(enforced9.0.params["particle_density"] == 0.41)
        #expect(enforced9.0.params["particle_brightness"] == 0.36)
        #expect(enforced9.0.params["motion_speed"] == 0.47)
    }

    @Test("Control Surface sweep applies bounded params per mode")
    func controlSurfaceSweep() {
        let engine = ModeEngine()
        for mode in 0...10 {
            let defaults = ModeContract.defaultPicksByMode[mode] ?? Picks()
            let bounds = ModeContract.modeBounds[mode] ?? [:]
            for (param, range) in bounds {
                for value in [range.0, range.1] {
                    let out = ModelOut(
                        protocolVersion: 1,
                        tsMs: 3_000,
                        mode: mode,
                        params: [param: value],
                        picks: defaults,
                        flags: Flags()
                    )
                    let enforced = ModeContract.enforceIncoming(modelOut: out, currentMode: mode)
                    #expect(!enforced.1.contains(where: { $0.hasPrefix("missing_pick:") || $0.hasPrefix("param_not_allowed:") }))
                    let control = engine.makeControl(out: enforced.0, sentButtons: Buttons())
                    #expect(control.level.isFinite)
                    #expect(control.dryLevel.isFinite)
                    #expect(control.wetLevel.isFinite)
                    #expect(control.reverb.wet.isFinite)
                }
            }
        }
    }

    @Test("Out-of-range params clamp and emit intervention hints")
    func controlSurfaceClampInterventions() {
        let out = ModelOut(
            protocolVersion: 1,
            tsMs: 4_000,
            mode: 2,
            params: [
                "grain_density": 5.0,
                "freeze_prob": -2.0,
                "grain_size_ms": 500.0,
            ],
            picks: ModeContract.defaultPicksByMode[2] ?? Picks(),
            flags: Flags()
        )
        let enforced = ModeContract.enforceIncoming(modelOut: out, currentMode: 2)
        #expect(enforced.0.params["grain_density"] == 0.9)
        #expect(enforced.0.params["freeze_prob"] == 0.0)
        #expect(enforced.0.params["grain_size_ms"] == 120.0)
        #expect(enforced.1.contains(where: { $0.contains("density_cap") }))
        #expect(enforced.1.contains(where: { $0.hasPrefix("clamp_keys:") }))

        let parsed = FrameInterventions.from(enforced.1.map { "contract_violation:\($0)" })
        #expect(parsed.densityCap)
        #expect(parsed.contractViolation)
    }

    @Test("Manifest catalog resolves picks with deterministic fallbacks")
    func manifestCatalogResolution() {
        let catalog = ManifestCatalog.shared
        if catalog.banks.isEmpty || catalog.instruments.isEmpty || catalog.spatialPatterns.isEmpty {
            #expect(!catalog.validationWarnings.isEmpty)
        } else {
            #expect(catalog.banks["samples_A"] != nil)
            #expect(catalog.instruments["inst_A"] != nil)
            #expect(catalog.spatialPatterns["drift_slow"] != nil)
        }

        let resolvedMode4 = catalog.resolve(
            mode: 4,
            picks: Picks(
                presetId: nil,
                bankId: "unknown_bank",
                sampleId: "unknown_sample",
                midiInstId: nil,
                spatialPatternId: "unknown_pattern",
                sceneId: nil
            )
        )
        #expect(resolvedMode4.picks.bankId == "samples_A")
        #expect(resolvedMode4.picks.sampleId == "s000")
        #expect(resolvedMode4.picks.spatialPatternId == "cluster_rotate")
        #expect(!resolvedMode4.notes.isEmpty)

        let resolvedMode9 = catalog.resolve(
            mode: 9,
            picks: Picks(
                presetId: nil,
                bankId: nil,
                sampleId: nil,
                midiInstId: nil,
                spatialPatternId: "orbit_mid",
                sceneId: nil
            )
        )
        #expect(resolvedMode9.picks.bankId != nil)
        #expect(resolvedMode9.picks.midiInstId != nil)
        #expect(resolvedMode9.picks.spatialPatternId == "orbit_mid")
    }

    @Test("ModeEngine target modes switch with finite controls")
    func modeEngineTargetModesStable() {
        let engine = ModeEngine()
        let modes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 7, 4, 1, 9, 2, 3, 5, 6]
        for mode in modes {
            let out = ModelOut(
                protocolVersion: 1,
                tsMs: 1000,
                mode: mode,
                params: [
                    "dry_level": 0.8,
                    "wet_level": 0.3,
                    "reverb_wet": 0.2,
                    "reverb_decay": 0.4,
                    "motion_speed": 0.5,
                    "spread": 0.6,
                    "grain_density": 0.5,
                    "drive": 0.4,
                    "band_low_level": 0.4,
                    "band_mid_level": 0.35,
                    "band_high_level": 0.25,
                    "repeat_prob": 0.65,
                    "window_norm": 0.35,
                    "stutter_len_norm": 0.25,
                    "gesture_rate": 0.55,
                    "interruptiveness": 0.35,
                    "similarity_target": 0.72,
                    "morph_rate": 0.45,
                    "crossfade": 0.52,
                    "sharpness": 0.66,
                    "bias": 0.48,
                    "wet": 0.10,
                ],
                picks: ModeContract.defaultPicksByMode[mode] ?? Picks(),
                flags: Flags()
            )
            let control = engine.makeControl(out: out, sentButtons: Buttons(jolt: false, clear: false))
            #expect(control.mode == mode)
            #expect(control.level.isFinite)
            #expect(control.dryLevel.isFinite)
            #expect(control.wetLevel.isFinite)
            #expect(control.reverb.wet.isFinite)
            #expect(control.reverb.wet >= 0.0 && control.reverb.wet <= 0.50)
            #expect(control.motionSpeed >= 0.0 && control.motionSpeed <= 1.0)
            if mode == 1 {
                #expect(control.gridDiv == "1/8" || control.gridDiv == "1/16")
            }
            if mode == 7 {
                #expect(control.wetLevel >= 0.75)
            }
            if mode == 5 {
                #expect(control.dryLevel == 0.0)
                #expect(control.midiInstId == "inst_A")
                #expect(control.chordSetId == "cs_neutral")
            }
        }
    }

    @Test("Mode 5/6 clear and flag reset produce resonifier reset hint")
    func mode56ClearSetsResetVoices() {
        let engine = ModeEngine()
        let mode5Out = ModelOut(
            protocolVersion: 1,
            tsMs: 2_000,
            mode: 5,
            params: [
                "note_rate": 0.5,
                "voice_cap": 0.4,
                "velocity_bias": 0.5,
                "pitch_follow": 0.6,
                "inharmonicity": 0.2,
            ],
            picks: ModeContract.defaultPicksByMode[5] ?? Picks(),
            flags: Flags(resetVoices: true)
        )
        let c5 = engine.makeControl(out: mode5Out, sentButtons: Buttons(jolt: false, clear: false))
        #expect(c5.mode == 5)
        #expect(c5.resetVoices)
        #expect(c5.dryLevel == 0.0)

        let mode6Out = ModelOut(
            protocolVersion: 1,
            tsMs: 2_100,
            mode: 6,
            params: [
                "note_rate": 0.4,
                "voice_cap": 0.3,
                "velocity_bias": 0.6,
                "pitch_follow": 0.5,
                "inharmonicity": 0.1,
                "dry_level": 0.7,
            ],
            picks: ModeContract.defaultPicksByMode[6] ?? Picks(),
            flags: Flags(resetVoices: false)
        )
        let c6 = engine.makeControl(out: mode6Out, sentButtons: Buttons(jolt: false, clear: true))
        #expect(c6.mode == 6)
        #expect(c6.resetVoices)
        #expect(c6.dryLevel >= 0.45)
    }

    @Test("Grid spatializer gains are normalized")
    func pannerNormalization() {
        let gains = GridSpatializer.normalizedPointGains(x: 0.1, y: -0.2, spread: 0.6)
        #expect(gains.count == 6)
        let sum = gains.reduce(0, +)
        #expect(abs(sum - 1.0) < 0.0015)
        for g in gains {
            #expect(g >= 0)
            #expect(g.isFinite)
        }
    }

    @Test("Reverb crossfade ramp is smooth and energy-preserving")
    func reverbCrossfadeRamp() {
        var ramp = ReverbCrossfadeRamp()
        ramp.begin(fromAtoB: true, samples: 120)

        var prevB: Float = ramp.mixB
        for _ in 0..<120 {
            ramp.advance()
            #expect(ramp.mixA >= 0 && ramp.mixA <= 1)
            #expect(ramp.mixB >= 0 && ramp.mixB <= 1)
            #expect(abs((ramp.mixA + ramp.mixB) - 1.0) < 0.0001)
            #expect(ramp.mixB >= prevB)
            prevB = ramp.mixB
        }
        #expect(ramp.mixB > 0.99)
    }

    @Test("CPU guard throttles and recovers")
    func cpuGuardBehavior() {
        var guardrail = CPUGuard()
        for _ in 0..<3 {
            guardrail.note(renderTimeNs: 90_000, budgetNs: 100_000)
        }
        #expect(guardrail.currentAction.active)
        #expect(guardrail.currentAction.voiceLimit < 24)
        for _ in 0..<170 {
            guardrail.note(renderTimeNs: 10_000, budgetNs: 100_000)
        }
        #expect(!guardrail.currentAction.active)
    }

    @Test("Golden trace integration replay (set RUN_GOLDEN_TRACE=1)")
    func goldenTraceIntegrationReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_GOLDEN_TRACE"] == "1" else {
            return
        }

        let host = env["MODEL_HOST"] ?? "127.0.0.1"
        let port = UInt16(env["MODEL_PORT"] ?? "9910") ?? 9910
        let maxLatencyMs = Int(env["GOLDEN_MAX_LATENCY_MS"] ?? "100") ?? 100
        let medianLatencyMs = Int(env["GOLDEN_MEDIAN_LATENCY_MS"] ?? "50") ?? 50

        let testFileURL = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/golden_trace.jsonl")
        #expect(FileManager.default.fileExists(atPath: fixtureURL.path))

        let expectedFrames = try TraceRecorder.loadReplayFrames(from: fixtureURL).count
        #expect(expectedFrames > 0)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-replay-\(UUID().uuidString).jsonl")
        let replayURL = try TraceReplayer.replay(
            inputURL: fixtureURL,
            host: host,
            port: port,
            speed: 0.0,
            timeoutMs: 1_000,
            outputURL: outURL
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rawLines = try String(contentsOf: replayURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let records = try rawLines.map { line in
            try decoder.decode(TraceRecord.self, from: Data(line.utf8))
        }

        #expect(records.count == expectedFrames)

        let failedResponses = records.filter { rec in
            rec.modelOut == nil || rec.diagnostics.timedOut
        }
        if !failedResponses.isEmpty {
            Issue.record("Golden trace replay had missing/timed-out responses. Ensure tub-ml server is running on \(host):\(port).")
        }
        #expect(failedResponses.isEmpty)

        var latencies = records.compactMap(\.diagnostics.roundTripMs)
        latencies.sort()
        if let maxLatency = latencies.last {
            #expect(maxLatency <= maxLatencyMs)
        }
        if !latencies.isEmpty {
            let median = latencies[latencies.count / 2]
            #expect(median <= medianLatencyMs)
        }

        for record in records {
            guard let out = record.modelOut else { continue }
            #expect(out.mode == record.modelIn.mode)

            let clamped = ModeContract.clamp(params: out.params, mode: out.mode)
            #expect(clamped.violations.isEmpty)

            let pickViolations = ModeContract.validate(picks: out.picks, mode: out.mode)
            #expect(pickViolations.isEmpty)
        }
    }

    @Test("Training frame log schema includes required keys")
    func trainingFrameLogSchemaKeys() throws {
        let line = TrainingFrameLogLine(
            tsMs: 1_000,
            frameIndex: 1,
            sessionId: "session_test",
            frameHz: 10,
            mode: 2,
            buttons: Buttons(jolt: false, clear: false),
            features: Features(
                loudnessLufs: -20,
                onsetRateHz: 1.5,
                specCentroidHz: 1_500,
                bandLow: 0.2,
                bandMid: 0.5,
                bandHigh: 0.3,
                noisiness: 0.4,
                pitchHz: 220,
                pitchConf: 0.7,
                keyEstimate: "A",
                keyConf: 0.5
            ),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0),
            modelIn: ModelIn(
                protocolVersion: 1,
                tsMs: 1_000,
                sessionId: "session_test",
                frameHz: 10,
                mode: 2,
                buttons: Buttons(jolt: false, clear: false),
                features: Features(
                    loudnessLufs: -20,
                    onsetRateHz: 1.5,
                    specCentroidHz: 1_500,
                    bandLow: 0.2,
                    bandMid: 0.5,
                    bandHigh: 0.3,
                    noisiness: 0.4,
                    pitchHz: 220,
                    pitchConf: 0.7,
                    keyEstimate: "A",
                    keyConf: 0.5
                ),
                state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0)
            ),
            modelOut: nil,
            diagnostics: TraceDiagnostics(
                requestId: 1,
                sendTsMs: 1_000,
                recvTsMs: nil,
                roundTripMs: nil,
                timedOut: false,
                decodeError: nil,
                interventions: []
            ),
            interventions: FrameInterventions.from([]),
            label: .good,
            bundleId: "bundle_2026-03-24_test"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(line)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(obj?.keys.map { $0 } ?? [String]())

        for key in ["ts_ms", "frame_index", "session_id", "mode", "buttons", "features", "model_out", "interventions", "label", "bundle_id"] {
            #expect(keys.contains(key))
        }
        let features = obj?["features"] as? [String: Any]
        #expect(features?["pitch_hz"] != nil)
        #expect(features?["pitch_conf"] != nil)
        #expect(features?["key_estimate"] != nil)
        #expect(features?["key_conf"] != nil)
    }

    @Test("Bundle JSON contains required version fields")
    func bundleJsonContainsRequiredFields() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("thetub-bundle-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let policyConfig = base.appendingPathComponent("policy.yaml")
        try "policy: rule_policy_v1_1\n".write(to: policyConfig, atomically: true, encoding: .utf8)

        let fixedDate = Date(timeIntervalSince1970: 1_711_334_400) // 2024-03-25
        let out = try RunBundleFactory.create(
            now: fixedDate,
            overrideBundleId: "bundle_2026-03-24_testrev",
            policyConfigPath: policyConfig.path,
            baseDirectory: base
        )

        #expect(out.bundle.bundleId == "bundle_2026-03-24_testrev")
        #expect(out.bundle.contractVersion == ModeContract.contractVersion)
        #expect(FileManager.default.fileExists(atPath: out.fileURL.path))

        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: out.fileURL)) as? [String: Any]
        #expect(payload?["bundle_id"] as? String == "bundle_2026-03-24_testrev")
        #expect(payload?["policy_version"] as? String != nil)
        #expect(payload?["bank_manifest_version"] as? String != nil)
        #expect(payload?["contract_version"] as? String == ModeContract.contractVersion)
    }

    @Test("Label change emits event and frame includes sticky label")
    func labelEventAndFrameLabel() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("thetub-label-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let bundle = RunBundleMetadata(
            bundleId: "bundle_2026-03-24_test",
            createdAt: "2026-03-24T12:00:00Z",
            policyVersion: "policy_hash",
            bankManifestVersion: "bank_hash",
            contractVersion: ModeContract.contractVersion,
            harnessRepoSha: "abc1234",
            modelRepoSha: "def5678"
        )
        let session = try TrainingLogSession(bundle: bundle, sessionId: "s1", baseDirectory: base)
        session.appendLabelChange(from: nil, to: .tooMuch)

        let frame = TrainingFrameLogLine(
            tsMs: 2_000,
            frameIndex: 2,
            sessionId: "s1",
            frameHz: 10,
            mode: 1,
            buttons: Buttons(jolt: false, clear: false),
            features: Features(
                loudnessLufs: -22,
                onsetRateHz: 1.2,
                specCentroidHz: 1_200,
                bandLow: 0.3,
                bandMid: 0.4,
                bandHigh: 0.3,
                noisiness: 0.3
            ),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0),
            modelIn: ModelIn(
                protocolVersion: 1,
                tsMs: 2_000,
                sessionId: "s1",
                frameHz: 10,
                mode: 1,
                buttons: Buttons(jolt: false, clear: false),
                features: Features(
                    loudnessLufs: -22,
                    onsetRateHz: 1.2,
                    specCentroidHz: 1_200,
                    bandLow: 0.3,
                    bandMid: 0.4,
                    bandHigh: 0.3,
                    noisiness: 0.3
                ),
                state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0)
            ),
            modelOut: nil,
            diagnostics: TraceDiagnostics(
                requestId: 2,
                sendTsMs: 2_000,
                recvTsMs: nil,
                roundTripMs: nil,
                timedOut: false,
                decodeError: nil,
                interventions: []
            ),
            interventions: FrameInterventions.from([]),
            label: .tooMuch,
            bundleId: bundle.bundleId
        )
        session.appendFrame(frame)
        session.close()

        let eventText = try String(contentsOf: session.eventURL, encoding: .utf8)
        #expect(eventText.contains("\"event\":\"label_change\""))
        #expect(eventText.contains("\"to\":\"too_much\""))

        let frameText = try String(contentsOf: session.frameURL, encoding: .utf8)
        #expect(frameText.contains("\"label\":\"too_much\""))
        #expect(frameText.contains("\"bundle_id\":\"bundle_2026-03-24_test\""))
    }

    @Test("Session metadata writes required fields and disabled input recording uses null path")
    func sessionMetadataNoInputAudio() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("thetub-meta-off-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let bundle = RunBundleMetadata(
            bundleId: "bundle_meta_off",
            createdAt: "2026-03-25T12:00:00Z",
            policyVersion: "policy_hash",
            bankManifestVersion: "bank_hash",
            contractVersion: ModeContract.contractVersion,
            harnessRepoSha: "abc1234",
            modelRepoSha: "def5678"
        )
        let sessionId = "session_meta_off"
        let session = try TrainingLogSession(
            bundle: bundle,
            sessionId: sessionId,
            recordInputAudioEnabled: false,
            baseDirectory: base
        )

        let frame = TrainingFrameLogLine(
            tsMs: 12_345,
            frameIndex: 1,
            sessionId: sessionId,
            frameHz: 10,
            replayMode: false,
            inputSource: .live,
            mode: 2,
            buttons: Buttons(),
            features: zeroFeatures(),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0),
            modelIn: ModelIn(
                protocolVersion: 1,
                tsMs: 12_345,
                sessionId: sessionId,
                frameHz: 10,
                mode: 2,
                buttons: Buttons(),
                features: zeroFeatures(),
                state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0)
            ),
            modelOut: nil,
            diagnostics: TraceDiagnostics(
                requestId: 1,
                sendTsMs: 12_345,
                recvTsMs: nil,
                roundTripMs: nil,
                timedOut: false,
                decodeError: nil,
                interventions: []
            ),
            interventions: FrameInterventions.from([]),
            label: nil,
            bundleId: bundle.bundleId
        )
        session.appendFrame(frame)
        session.close()

        let metaData = try Data(contentsOf: session.metaURL)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let meta = try dec.decode(SessionMetadata.self, from: metaData)

        #expect(meta.sessionId == sessionId)
        #expect(meta.bundleId == bundle.bundleId)
        #expect(meta.inputAudioPath == nil)
        #expect(meta.recordInputAudioEnabled == false)
        #expect(meta.frameHz == 10)
        #expect(meta.framesPath == session.frameURL.path)
        #expect(meta.eventsPath == session.eventURL.path)
        #expect(meta.alignment.startTsMs == 12_345)
        #expect(meta.inputAudioFormat == "caf")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("sessions/\(sessionId)/input_\(sessionId).caf").path))
    }

    @Test("Session metadata with input recording enabled stores path and replay loader reports audio availability")
    func sessionMetadataWithInputAudioAndReplayLoader() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("thetub-meta-on-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let bundle = RunBundleMetadata(
            bundleId: "bundle_meta_on",
            createdAt: "2026-03-25T12:00:00Z",
            policyVersion: "policy_hash",
            bankManifestVersion: "bank_hash",
            contractVersion: ModeContract.contractVersion,
            harnessRepoSha: "abc1234",
            modelRepoSha: "def5678"
        )
        let sessionId = "session_meta_on"
        let session = try TrainingLogSession(
            bundle: bundle,
            sessionId: sessionId,
            recordInputAudioEnabled: true,
            baseDirectory: base
        )
        guard let inputURL = session.inputAudioURL else {
            throw NSError(domain: "TheTubHarnessTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing input audio URL"])
        }
        try writeTinyCAF(url: inputURL, sampleRate: 48_000, channels: 1)
        session.setAudioCaptureInfo(
            sampleRate: 48_000,
            channels: 1,
            inputAudioFormat: "caf",
            inputAudioPath: inputURL.path
        )
        session.noteAudioAlignment(hostTime: 123, sampleIndex: 0)

        let modelIn = ModelIn(
            protocolVersion: 1,
            tsMs: 20_000,
            sessionId: sessionId,
            frameHz: 10,
            mode: 1,
            buttons: Buttons(),
            features: zeroFeatures(),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0)
        )
        let frame = TrainingFrameLogLine(
            tsMs: 20_000,
            frameIndex: 1,
            sessionId: sessionId,
            frameHz: 10,
            replayMode: false,
            inputSource: .live,
            mode: 1,
            buttons: Buttons(),
            features: zeroFeatures(),
            state: HarnessState(overload: false, cooldown: 0, lastModeMs: 0),
            modelIn: modelIn,
            modelOut: nil,
            diagnostics: TraceDiagnostics(
                requestId: 1,
                sendTsMs: 20_000,
                recvTsMs: nil,
                roundTripMs: nil,
                timedOut: false,
                decodeError: nil,
                interventions: []
            ),
            interventions: FrameInterventions.from([]),
            label: .good,
            bundleId: bundle.bundleId
        )
        session.appendFrame(frame)
        session.close()

        #expect(FileManager.default.fileExists(atPath: inputURL.path))

        let replay = try ReplaySessionLoader.load(
            sessionId: sessionId,
            baseDirectory: base
        )
        #expect(replay.inputAudioURL?.path == inputURL.path)
        #expect(!replay.frames.isEmpty)
        #expect(replay.frames[0].frameIndex == 1)
        #expect(replay.frames[0].tsMs == 20_000)

        // Remove audio and confirm loader reports it missing while still loading frame/event streams.
        try FileManager.default.removeItem(at: inputURL)
        let replayWithoutAudio = try ReplaySessionLoader.load(
            sessionId: sessionId,
            baseDirectory: base
        )
        #expect(replayWithoutAudio.inputAudioURL == nil)
        #expect(!replayWithoutAudio.frames.isEmpty)
    }

    @MainActor
    @Test("Control room state replay flags and alignment warnings")
    func controlRoomStateReplayMapping() {
        let state = ControlRoomState()
        state.setReplayRunning(true)
        state.setReplayStatus("running")
        #expect(state.replay.isRunning)
        #expect(state.transport.isReplayRunning)
        #expect(state.replay.statusMessage == "running")

        let initialCount = state.events.count
        state.noteReplayAlignment(targetTimeS: 0.0, audioTimeS: 0.25)
        #expect(state.events.count >= initialCount + 1)
        #expect(state.events.first?.message.contains("alignment drift") ?? false)
    }

    @Test("Model slot persistence round-trip")
    func modelSlotPersistenceRoundTrip() {
        let appName = "TheTubHarnessTests_\(UUID().uuidString)"
        let slots = [
            ModelSlotProfile(id: UUID(), name: "A", host: "127.0.0.1", port: 9910, notes: "n1"),
            ModelSlotProfile(id: UUID(), name: "B", host: "127.0.0.2", port: 9920, notes: "n2")
        ]
        ModelSlotPersistence.save(slots: slots, appName: appName)
        let loaded = ModelSlotPersistence.load(appName: appName)
        #expect(loaded.count == 2)
        #expect(loaded[0].name == "A")
        #expect(loaded[1].host == "127.0.0.2")
    }

    @MainActor
    @Test("Control room slot management enforces minimum one slot")
    func controlRoomSlotManagement() {
        let state = ControlRoomState()
        state.modelSlots = ModelSlotsPanelViewModel(
            slots: [ModelSlotProfile(id: UUID(), name: "Only", host: "127.0.0.1", port: 9910, notes: "")]
        )
        let firstId = state.modelSlots.slots[0].id
        state.removeSlot(firstId)
        #expect(state.modelSlots.slots.count == 1)

        state.addModelSlot()
        #expect(state.modelSlots.slots.count == 2)
        state.removeSlot(firstId)
        #expect(state.modelSlots.slots.count == 1)
    }

    @Test("Client endpoint reconfigure updates model endpoint")
    func clientEndpointReconfigure() async throws {
        let client = TubMLClient(host: "127.0.0.1", port: 9910)
        client.reconfigureEndpoint(host: "127.0.0.1", port: 9922)

        var endpoint = client.modelEndpoint()
        for _ in 0..<40 {
            endpoint = client.modelEndpoint()
            if endpoint.host == "127.0.0.1" && endpoint.port == 9922 {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port == 9922)
    }

    @Test("Control room state can bind to endpoint updates")
    func controlRoomStateBindsEndpointChanges() async throws {
        let client = TubMLClient(host: "127.0.0.1", port: 9910)
        let audio = AudioEngineController()
        let analyzer = AudioInputAnalyzer()
        let state = ControlRoomState()
        state.bind(client: client, audio: audio, analyzer: analyzer)

        client.reconfigureEndpoint(host: "127.0.0.1", port: 9923)

        for _ in 0..<40 {
            if state.transport.endpointPort == 9923 {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(state.transport.endpointHost == "127.0.0.1")
        #expect(state.transport.endpointPort == 9923)
    }

    @Test("Client endpoint reconfigure keeps modelEndpoint stable for readers")
    func clientEndpointReconfigureImmediateRead() {
        let client = TubMLClient(host: "127.0.0.1", port: 9910)
        client.reconfigureEndpoint(host: "127.0.0.1", port: 9922)

        // Ensure method is always callable synchronously while updates settle.
        _ = client.modelEndpoint()
    }

    @Test("Client endpoint reconfigure updates model endpoint (legacy check)")
    func clientEndpointReconfigureLegacyCheck() async throws {
        let client = TubMLClient(host: "127.0.0.1", port: 9910)
        client.reconfigureEndpoint(host: "127.0.0.1", port: 9922)

        for _ in 0..<40 {
            let endpoint = client.modelEndpoint()
            #expect(endpoint.host == "127.0.0.1")
            if endpoint.port == 9922 {
                #expect(endpoint.port == 9922)
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let endpoint = client.modelEndpoint()
        #expect(endpoint.port == 9922)
    }

    @Test("Mode 1 clock locks to stable onsets and quantizes 1/8 step")
    func mode1ClockQuantization() {
        var clock = Mode1ClockState()
        let sampleRate: Float = 48_000
        clock.configure(sampleRate: sampleRate)

        for _ in 0..<10 {
            clock.advance(samples: 24_000)
            clock.noteOnset(intervalSamples: 24_000, sampleRate: sampleRate)
        }

        #expect(clock.confidence > 0.75)
        #expect(abs(clock.effectiveBeatSamples(sampleRate: sampleRate) - 24_000) < 1_500)
        #expect(abs(clock.stepSamples(gridDiv: "1/8", sampleRate: sampleRate) - 12_000) < 800)
    }

    @Test("Mode 1 clock falls back to 60 BPM when confidence is low")
    func mode1ClockFallback() {
        var clock = Mode1ClockState()
        let sampleRate: Float = 48_000
        clock.configure(sampleRate: sampleRate)

        clock.advance(samples: Int(sampleRate * 8))
        for _ in 0..<64 {
            clock.confidenceDecay()
        }

        #expect(clock.confidence < 0.42)
        #expect(clock.effectiveBeatSamples(sampleRate: sampleRate) == Int(sampleRate))
        #expect(clock.stepSamples(gridDiv: "1/8", sampleRate: sampleRate) == Int(sampleRate / 2))
    }

    @Test("Mode 2 freeze scene bounds and pitch spread mapping")
    func mode2FreezeAndPitchSpreadMapping() {
        var state = Mode2GranulatorState()
        state.beginFreeze(sampleRate: 48_000, requestedLenSec: 12.0)
        #expect(state.freezeSamplesRemaining <= Int(48_000 * 3.2))
        #expect(state.freezeSamplesRemaining > 0)
        #expect(state.freezeCooldownSamples > 0)

        let engine = ModeEngine()
        let out = ModelOut(
            protocolVersion: 1,
            tsMs: 42_000,
            mode: 2,
            params: [
                "grain_size_ms": 40.0,
                "grain_density": 0.55,
                "scan_rate": 0.4,
                "freeze_prob": 0.2,
                "freeze_len_s": 2.2,
                "pitch_spread_cents": 35.0,
            ],
            picks: ModeContract.defaultPicksByMode[2] ?? Picks(),
            flags: Flags()
        )
        let control = engine.makeControl(out: out, sentButtons: Buttons())
        #expect(control.mode == 2)
        #expect(control.grainPitchSpread > 0.95)
        #expect(control.scanJumpProb >= 0.70)
    }

    @Test("CPU guard throttling degrades interpolation quality after density/voices")
    func cpuGuardInterpolationDegradeOrder() {
        var guardrail = CPUGuard()
        for _ in 0..<3 {
            guardrail.note(renderTimeNs: 90_000, budgetNs: 100_000)
        }
        #expect(guardrail.currentAction.active)
        #expect(guardrail.currentAction.densityScale < 1.0)
        #expect(guardrail.currentAction.voiceLimit < 24)
        #expect(guardrail.currentAction.interpolationQuality < 1.0)
    }

    @Test("Mode 7 contract stays v1-compatible")
    func mode7ContractCompatibility() {
        let allowed = ModeContract.canonicalAllowedParams(for: 7)
        #expect(allowed == Set(["swap_rate_hz", "crossfade_ms", "bucket_sharpness", "mapping_entropy", "mix"]))
        let required = ModeContract.requiredPicks(for: 7)
        #expect(required.contains("preset_id"))
        #expect(required.contains("spatial_pattern_id"))
        #expect(!required.contains("mapping_id"))
        let defaults = ModeContract.defaultPicksByMode[7] ?? Picks()
        #expect(defaults.mappingId == "swap_pairs")
        #expect(defaults.mappingFamily == "bucket_swap")
    }

    @Test("Mode 7 clock adapts to stable onsets then falls back to 60 BPM")
    func mode7ClockHybridFallback() {
        var clock = Mode7ClockState()
        let sampleRate: Float = 48_000
        clock.configure(sampleRate: sampleRate)

        var sampleCounter: Int64 = 0
        for _ in 0..<10 {
            sampleCounter += 24_000
            clock.advance(samples: 24_000)
            clock.noteOnset(sampleCounter: sampleCounter, sampleRate: sampleRate)
        }
        #expect(clock.confidence > 0.65)
        #expect(abs(clock.effectiveBeatSamples(sampleRate: sampleRate) - 24_000) < 1_800)
        let quantized = clock.stepSamples(sampleRate: sampleRate, swapRateNorm: 0.7)
        #expect(quantized > 64)
        #expect(quantized < 24_000)

        for _ in 0..<360 {
            clock.confidenceDecay()
        }
        #expect(clock.confidence < 0.40)
        #expect(clock.effectiveBeatSamples(sampleRate: sampleRate) == Int(sampleRate))
    }

    @Test("Mode 7 scene builder is deterministic and normalized")
    func mode7SceneMatrixDeterministic() {
        let a = Mode7SceneBuilder.buildMatrix(
            mappingId: "swap_pairs",
            mappingFamily: "bucket_swap",
            sharpness: 0.72,
            entropy: 0.55,
            varianceAmt: 0.30,
            seed: 17,
            sceneStep: 3
        )
        let b = Mode7SceneBuilder.buildMatrix(
            mappingId: "swap_pairs",
            mappingFamily: "bucket_swap",
            sharpness: 0.72,
            entropy: 0.55,
            varianceAmt: 0.30,
            seed: 17,
            sceneStep: 3
        )
        #expect(a == b)
        var hasDifference = false
        let c = Mode7SceneBuilder.buildMatrix(
            mappingId: "swap_pairs",
            mappingFamily: "bucket_swap",
            sharpness: 0.72,
            entropy: 0.55,
            varianceAmt: 0.30,
            seed: 17,
            sceneStep: 4
        )
        for i in 0..<a.count where abs(a[i] - c[i]) > 1e-5 {
            hasDifference = true
            break
        }
        #expect(hasDifference)
        for src in 0..<8 {
            var row: Float = 0
            for dst in 0..<8 {
                row += a[src * 8 + dst]
            }
            #expect(abs(row - 1.0) < 0.001)
        }
    }

    @Test("Mode 7 scheduler crossfade duration and final target lock")
    func mode7SchedulerCrossfadeTiming() {
        var scheduler = Mode7SwapScheduler()
        scheduler.configure(sampleRate: 48_000)
        let target = Mode7SceneBuilder.buildMatrix(
            mappingId: "octave_flip",
            mappingFamily: "bucket_swap",
            sharpness: 0.6,
            entropy: 0.7,
            varianceAmt: 0.25,
            seed: 23,
            sceneStep: 2
        )
        scheduler.beginCrossfade(to: target, crossfadeSamples: 240)
        var ticks = 0
        while scheduler.crossfadeRemaining > 0, ticks < 1_000 {
            scheduler.advanceMatrix()
            ticks += 1
        }
        #expect(ticks == 240)
        #expect(scheduler.crossfadeRemaining == 0)
        var matrixMatches = true
        for i in 0..<64 where abs(scheduler.liveMatrix[i] - target[i]) > 1e-5 {
            matrixMatches = false
            break
        }
        #expect(matrixMatches)
    }

    @Test("Mode 7 identity mapping reconstructs near-unity from filterbank")
    func mode7IdentityReconstruction() {
        var state = Mode7RedistributorState()
        let sampleRate: Float = 48_000
        state.configure(sampleRate: sampleRate)

        let sampleCount = 8_192
        var input = [Float](repeating: 0, count: sampleCount)
        var output = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Float(i) / sampleRate
            let x = (0.42 * sinf(2.0 * .pi * 180.0 * t)) +
                (0.30 * sinf(2.0 * .pi * 740.0 * t)) +
                (0.22 * sinf(2.0 * .pi * 2_200.0 * t))
            input[i] = x
            output[i] = state.identityReconstructionSample(x)
        }

        // The crossover bank is IIR-based, so account for startup/group delay.
        let warmup = 512
        var bestRel = Double.greatestFiniteMagnitude
        for lag in 0...256 {
            let start = warmup + lag
            if start >= sampleCount { break }
            var err2: Double = 0
            var ref2: Double = 0
            for i in start..<sampleCount {
                let x = Double(input[i - lag])
                let y = Double(output[i])
                let e = y - x
                err2 += e * e
                ref2 += x * x
            }
            let rel = sqrt(err2 / max(ref2, 1e-9))
            bestRel = min(bestRel, rel)
        }
        #expect(bestRel < 0.16)
    }

    private func writeTinyCAF(url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format!.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format!, frameCapacity: 256) else {
            throw NSError(domain: "TheTubHarnessTests", code: 1, userInfo: nil)
        }
        buffer.frameLength = 256
        if let data = buffer.floatChannelData {
            for ch in 0..<Int(channels) {
                for i in 0..<Int(buffer.frameLength) {
                    data[ch][i] = (i % 32 == 0) ? 0.2 : 0
                }
            }
        }
        try file.write(from: buffer)
    }

    private func zeroFeatures() -> Features {
        Features(
            loudnessLufs: -80,
            onsetRateHz: 0,
            specCentroidHz: 0,
            bandLow: 0,
            bandMid: 0,
            bandHigh: 0,
            noisiness: 0,
            pitchHz: nil,
            pitchConf: 0,
            keyEstimate: nil,
            keyConf: 0
        )
    }
}

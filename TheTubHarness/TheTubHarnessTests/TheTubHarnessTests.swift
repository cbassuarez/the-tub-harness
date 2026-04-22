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
          "protocol_version": 2,
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
          },
          "visual": {
            "scene_id": "relay_mesh",
            "density": 0.52,
            "cohesion": 0.44,
            "disruption": 0.38,
            "token_salience": 0.61,
            "wordmark_integrity": 0.57,
            "decay_ms": 980,
            "flash_bias": 0.24,
            "anchor_weights": [0.2, 0.5, 0.3],
            "thought": "listening"
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let out = try decoder.decode(ModelOut.self, from: payload)

        #expect(out.protocolVersion == ModeContract.supportedProtocolVersion)
        #expect(out.mode == 2)
        #expect(out.picks.presetId == "gran_A")
        #expect(out.picks.spatialPatternId == "orbit_slow")
        #expect(out.params["level"] == 0.6)
    }

    @Test("ModelOut decoding rejects unknown fields and invalid mode")
    func modelOutDecodeIsStrict() {
        let payload = """
        {
          "protocol_version": 2,
          "ts_ms": 123456789,
          "mode": 99,
          "params": { "level": 0.5 },
          "picks": { "preset_id": "gran_A" },
          "flags": { "request_cooldown": false, "prefer_stability": true, "thin_events": false },
          "visual": {
            "scene_id": "grid_lock",
            "density": 0.5,
            "cohesion": 0.5,
            "disruption": 0.5,
            "token_salience": 0.5,
            "wordmark_integrity": 0.5,
            "decay_ms": 1000,
            "flash_bias": 0.5,
            "anchor_weights": [0.34, 0.33, 0.33],
            "thought": "idle"
          },
          "unexpected_field": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        #expect(throws: Error.self) {
            _ = try decoder.decode(ModelOut.self, from: payload)
        }
    }

    @Test("ModelOut decoding rejects protocol v1 and missing visual head")
    func modelOutDecodeRejectsLegacyProtocol() {
        let payload = """
        {
          "protocol_version": 1,
          "ts_ms": 123456789,
          "mode": 2,
          "params": { "level": 0.5 },
          "picks": { "preset_id": "gran_A" },
          "flags": { "request_cooldown": false, "prefer_stability": true, "thin_events": false }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        #expect(throws: Error.self) {
            _ = try decoder.decode(ModelOut.self, from: payload)
        }
    }

    @Test("StageTextModeration redacts profanity with leetspeak and obfuscation")
    func stageTextModerationRedactsSpeechLines() {
        #expect(
            StageTextModeration.sanitizeSpeechLine("this is sh1t, wow.")
                == "this is [REDACTED], wow."
        )
        #expect(
            StageTextModeration.sanitizeSpeechLine("f.u.c.k")
                == "[REDACTED]"
        )
    }

    @Test("StageTextModeration sanitizes visual thought and thought log")
    func stageTextModerationSanitizesVisual() {
        let visual = VisualOut(
            sceneId: "relay_mesh",
            density: 0.4,
            cohesion: 0.5,
            disruption: 0.2,
            tokenSalience: 0.6,
            wordmarkIntegrity: 0.7,
            decayMs: 900,
            flashBias: 0.3,
            anchorWeights: [0.4, 0.3, 0.3],
            thought: "fucking",
            thoughtLog: [
                "VOICE: f.u.c.k",
                "TRACKING SIGNAL"
            ]
        )

        let sanitized = StageTextModeration.sanitizeVisual(visual)
        #expect(sanitized.thought == StageTextModeration.thoughtFallback)
        #expect(sanitized.thoughtLog.first == "VOICE: [REDACTED]")
        #expect(sanitized.thoughtLog.count == 2)
    }

    @Test("StageTextModeration Bedrock path falls back to local sanitizer when unavailable")
    func stageTextModerationBedrockFallbacksToLocal() async {
        let value = await StageTextModeration.sanitizeSpeechLineUsingBedrockIfAvailable("f.u.c.k")
        #expect(value == "[REDACTED]")
    }

    @Test("AudienceSessionServer handshake payload advertises transport capabilities")
    func audienceHandshakePayloadAdvertisesTransports() throws {
        let server = AudienceSessionServer()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let baselineData = server.handshakePayloadDataForTesting(now: now)
        let baselineJSON = try JSONSerialization.jsonObject(with: baselineData) as? [String: Any]
        let baselineTransports = baselineJSON?["transports"] as? [String] ?? []
        #expect(baselineTransports.contains("direct_tcp"))
        #expect((baselineJSON?["relayJoinCode"] as? String) == nil)

        let relayExpiry = now.addingTimeInterval(300)
        server.setRelayAnnouncementForTesting(
            wsURL: "wss://relay.example.com/v1/link/ws",
            joinCode: "ABC123",
            expiresAt: relayExpiry
        )

        let relayData = server.handshakePayloadDataForTesting(now: now)
        let relayJSON = try JSONSerialization.jsonObject(with: relayData) as? [String: Any]
        let relayTransports = relayJSON?["transports"] as? [String] ?? []

        #expect(relayTransports.contains("direct_tcp"))
        #expect(relayTransports.contains("relay_ws"))
        #expect((relayJSON?["relayJoinCode"] as? String) == "ABC123")
        #expect((relayJSON?["relayWsURL"] as? String) == "wss://relay.example.com/v1/link/ws")
        #expect((relayJSON?["relaySessionExpiresAt"] as? String) != nil)
    }

    @Test("AudienceSessionServer NDJSON parser handles fragmented and multi-message chunks")
    func audienceEnvelopeFramingHandlesFragmentedChunks() throws {
        let server = AudienceSessionServer()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let one = AudienceEnvelope(kind: .sessionOpen, sessionId: "session-1")
        let two = AudienceEnvelope(kind: .queryState, sessionId: "session-1")

        var lineOne = try encoder.encode(one)
        var lineTwo = try encoder.encode(two)
        lineOne.append(0x0A)
        lineTwo.append(0x0A)

        let merged = lineOne + lineTwo
        let splitA = merged.prefix(11)
        let splitB = merged.dropFirst(11).prefix(9)
        let splitC = merged.dropFirst(20)

        let decoded = server.decodeEnvelopesForTesting(
            chunks: [Data(splitA), Data(splitB), Data(splitC)]
        )
        #expect(decoded.count == 2)
        #expect(decoded[0].kind == .sessionOpen)
        #expect(decoded[1].kind == .queryState)
    }

    @Test("AudienceSessionServer routes envelope kinds into preference events")
    func audienceEnvelopeRoutingMapsToPreferenceEvents() {
        let server = AudienceSessionServer()

        let steerEnvelope = AudienceEnvelope(
            kind: .steerVector,
            sessionId: "session-1",
            steerVector: SteerVectorPayload(
                pointX: 0.25,
                pointY: 0.75,
                velocityX: 0.04,
                velocityY: -0.03,
                intensity: 0.7,
                descriptorId: "dense",
                descriptorLabel: "DENSE"
            )
        )

        let holdEnvelope = AudienceEnvelope(
            kind: .holdState,
            sessionId: "session-1",
            holdState: HoldStatePayload(isHolding: false, durationSeconds: 0.9, intensity: 0.8)
        )

        let nudgeEnvelope = AudienceEnvelope(
            kind: .intensityNudge,
            sessionId: "session-1",
            intensityNudge: IntensityNudgePayload(direction: .less, intensity: 1.0)
        )

        let compareEnvelope = AudienceEnvelope(
            kind: .compareChoice,
            sessionId: "session-1",
            compareChoice: CompareChoicePayload(
                pairId: "pair-a-b",
                leftDescriptorId: "a",
                rightDescriptorId: "b",
                chosenDescriptorId: "b",
                intensity: 1
            )
        )

        let steerEvent = server.routePreferenceForTesting(steerEnvelope)
        let holdEvent = server.routePreferenceForTesting(holdEnvelope)
        let nudgeEvent = server.routePreferenceForTesting(nudgeEnvelope)
        let compareEvent = server.routePreferenceForTesting(compareEnvelope)

        #expect(steerEvent?.eventType == .dragTowardDescriptor)
        #expect(steerEvent?.descriptorLabel == "DENSE")
        #expect(holdEvent?.eventType == .release)
        #expect(nudgeEvent?.eventType == .lessAction)
        #expect(compareEvent?.eventType == .pairwiseCompare)
        #expect(compareEvent?.descriptorLabel == "B")
    }

    @Test("AudienceSessionServer NDJSON parser decodes stage snapshot envelopes")
    func audienceEnvelopeParserDecodesStageSnapshot() throws {
        let server = AudienceSessionServer()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let snapshot = StageSnapshotPayload(
            mode: 2,
            sceneId: "relay_mesh",
            thought: "listening",
            thoughtLog: ["LISTENING", "AUDIENCE DENSE 45%"],
            density: 0.41,
            cohesion: 0.62,
            disruption: 0.27,
            isRunning: true,
            isWaiting: false,
            waitingReason: nil,
            paramLines: ["LEVEL 54", "MIX 42"],
            pickLines: ["PRESET ORBIT"],
            changeLines: ["PARAM LEVEL 54"],
            audio: StageAudioSummaryPayload(
                rms: 0.21,
                transientFlux: 0.16,
                lowBand: 0.18,
                midBand: 0.35,
                highBand: 0.26,
                peak: 0.42,
                brightness: 0.31,
                overloadPulse: 0.0
            ),
            joltHeld: false,
            timestamp: Date()
        )

        let envelope = AudienceEnvelope(
            kind: .stageSnapshot,
            sessionId: "session-1",
            stageSnapshot: snapshot
        )

        var line = try encoder.encode(envelope)
        line.append(0x0A)

        let chunks = [
            Data(line.prefix(14)),
            Data(line.dropFirst(14).prefix(11)),
            Data(line.dropFirst(25))
        ]

        let decoded = server.decodeEnvelopesForTesting(chunks: chunks)
        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .stageSnapshot)
        #expect(decoded[0].stageSnapshot?.sceneId == "relay_mesh")
        #expect(decoded[0].stageSnapshot?.thoughtLog.count == 2)
    }

    @Test("AudienceSessionServer NDJSON parser decodes operator vector envelopes")
    func audienceEnvelopeParserDecodesOperatorVector() throws {
        let server = AudienceSessionServer()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let envelope = AudienceEnvelope(
            kind: .operatorVector,
            sessionId: "session-op",
            operatorVector: OperatorVectorPayload(
                paramVector: 0.7,
                thoughtVector: -0.3,
                audioVector: 0.2,
                ttlSeconds: 1800
            )
        )

        var line = try encoder.encode(envelope)
        line.append(0x0A)
        let decoded = server.decodeEnvelopesForTesting(chunks: [line])

        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .operatorVector)
        #expect(decoded[0].operatorVector?.paramVector == 0.7)
        #expect(decoded[0].operatorVector?.thoughtVector == -0.3)
        #expect(decoded[0].operatorVector?.ttlSeconds == 1800)
    }

    @Test("AudienceSessionServer NDJSON parser decodes operator activity envelopes")
    func audienceEnvelopeParserDecodesOperatorActivity() throws {
        let server = AudienceSessionServer()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let event = OperatorActivityEvent(
            sessionId: "session-ops",
            surface: .play,
            action: .playGridTrigger,
            label: "0A",
            intensity: 0.64,
            position: CGPoint(x: 0.5, y: 0.25)
        )
        let snapshot = OperatorActivitySnapshot(events: [event], serverTimestamp: Date())

        let eventEnvelope = AudienceEnvelope(
            kind: .operatorActivity,
            sessionId: "session-ops",
            operatorActivity: event
        )
        let snapshotEnvelope = AudienceEnvelope(
            kind: .operatorActivitySnapshot,
            sessionId: "SYSTEM",
            operatorActivitySnapshot: snapshot
        )

        var lineOne = try encoder.encode(eventEnvelope)
        var lineTwo = try encoder.encode(snapshotEnvelope)
        lineOne.append(0x0A)
        lineTwo.append(0x0A)

        let decoded = server.decodeEnvelopesForTesting(chunks: [lineOne + lineTwo])
        #expect(decoded.count == 2)
        #expect(decoded[0].kind == .operatorActivity)
        #expect(decoded[0].operatorActivity?.action == .playGridTrigger)
        #expect(decoded[1].kind == .operatorActivitySnapshot)
        #expect(decoded[1].operatorActivitySnapshot?.events.count == 1)
    }

    @Test("AudienceSessionServer includes operator activity snapshot on session open and query state")
    func audienceSessionServerSendsOperatorActivitySnapshotOnOpenAndQuery() {
        let server = AudienceSessionServer()
        server.enableOutgoingEnvelopeCaptureForTesting(true)

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-open"),
            connectionKey: "conn-open"
        )
        let openEnvelopes = server.takeOutgoingEnvelopesForTesting()
        #expect(openEnvelopes.contains(where: { $0.kind == .operatorActivitySnapshot }))

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .queryState, sessionId: "session-open"),
            connectionKey: "conn-open"
        )
        let queryEnvelopes = server.takeOutgoingEnvelopesForTesting()
        #expect(queryEnvelopes.contains(where: { $0.kind == .operatorActivitySnapshot }))
    }

    @Test("AudienceSessionServer turns steer vectors into operator activity broadcasts")
    func audienceSessionServerBroadcastsSteerOperatorActivity() {
        let server = AudienceSessionServer()
        server.enableOutgoingEnvelopeCaptureForTesting(true)

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-a"),
            connectionKey: "conn-a"
        )
        _ = server.takeOutgoingEnvelopesForTesting()
        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-b"),
            connectionKey: "conn-b"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .steerVector,
                sessionId: "session-a",
                steerVector: SteerVectorPayload(
                    pointX: 0.34,
                    pointY: 0.62,
                    velocityX: 0.04,
                    velocityY: -0.03,
                    intensity: 0.79,
                    descriptorId: "dense",
                    descriptorLabel: "DENSE"
                )
            ),
            connectionKey: "conn-a"
        )

        let activity = server
            .takeOutgoingEnvelopesForTesting()
            .filter { $0.kind == .operatorActivity }

        #expect(activity.count == 2)
        #expect(activity.allSatisfy { $0.operatorActivity?.surface == .steer })
        #expect(activity.allSatisfy { $0.operatorActivity?.action == .steerVector })
    }

    @Test("AudienceSessionServer rebroadcasts play activity and throttles long sweeps")
    func audienceSessionServerRebroadcastsPlayActivityAndThrottlesSweep() {
        let server = AudienceSessionServer()
        server.enableOutgoingEnvelopeCaptureForTesting(true)

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-a"),
            connectionKey: "conn-a"
        )
        _ = server.takeOutgoingEnvelopesForTesting()
        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-b"),
            connectionKey: "conn-b"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        let sweepOne = OperatorActivityEvent(
            eventId: "sweep-1",
            sessionId: "session-a",
            surface: .play,
            action: .playLongSweep,
            label: "LONG_A",
            intensity: 0.35,
            position: CGPoint(x: 0.2, y: 0.5)
        )
        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorActivity,
                sessionId: "session-a",
                timestamp: sweepOne.timestamp,
                operatorActivity: sweepOne
            ),
            connectionKey: "conn-a"
        )
        let firstSweepBroadcast = server
            .takeOutgoingEnvelopesForTesting()
            .filter { $0.kind == .operatorActivity && $0.operatorActivity?.eventId == "sweep-1" }
        #expect(firstSweepBroadcast.count == 2)

        let sweepTwo = OperatorActivityEvent(
            eventId: "sweep-2",
            sessionId: "session-a",
            surface: .play,
            action: .playLongSweep,
            label: "LONG_A",
            intensity: 0.36,
            position: CGPoint(x: 0.23, y: 0.5)
        )
        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorActivity,
                sessionId: "session-a",
                timestamp: sweepTwo.timestamp,
                operatorActivity: sweepTwo
            ),
            connectionKey: "conn-a"
        )
        let secondSweepBroadcast = server
            .takeOutgoingEnvelopesForTesting()
            .filter { $0.kind == .operatorActivity && $0.operatorActivity?.eventId == "sweep-2" }
        #expect(secondSweepBroadcast.isEmpty)

        let gridTrigger = OperatorActivityEvent(
            eventId: "grid-1",
            sessionId: "session-a",
            surface: .play,
            action: .playGridTrigger,
            label: "0A"
        )
        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorActivity,
                sessionId: "session-a",
                timestamp: gridTrigger.timestamp,
                operatorActivity: gridTrigger
            ),
            connectionKey: "conn-a"
        )
        let gridBroadcast = server
            .takeOutgoingEnvelopesForTesting()
            .filter { $0.kind == .operatorActivity && $0.operatorActivity?.eventId == "grid-1" }
        #expect(gridBroadcast.count == 2)
    }

    @Test("AudiencePreferenceOverlay less action uses symmetric intensity key path")
    func audiencePreferenceOverlayLessActionSymmetry() {
        let overlay = AudiencePreferenceOverlay()
        let sessionId = "session-symmetry"

        overlay.recordPreferenceEvent(
            AudiencePreferenceEvent(sessionId: sessionId, eventType: .moreAction, intensity: 1)
        )
        overlay.recordPreferenceEvent(
            AudiencePreferenceEvent(sessionId: sessionId, eventType: .lessAction, intensity: 1)
        )

        let mirror = Mirror(reflecting: overlay)
        let sessionWeights = mirror.children.first(where: { $0.label == "sessionWeights" })?.value as? [String: [String: Double]]
        let intensityWeight = sessionWeights?[sessionId]?["_intensity_"] ?? 999

        #expect(abs(intensityWeight) < 0.0001)
    }

    @Test("AudiencePreferenceOverlay applies and expires operator vectors")
    func audiencePreferenceOverlayOperatorVectorLifecycle() {
        let overlay = AudiencePreferenceOverlay()
        let sessionId = "session-vector"
        let activeSessions: [String: AudienceSessionState] = [
            sessionId: AudienceSessionState(sessionId: sessionId, sessionType: .appCompanion)
        ]

        overlay.recordOperatorVector(
            OperatorVectorPayload(paramVector: 0.8, thoughtVector: 0.4, audioVector: -0.5, ttlSeconds: 10),
            for: sessionId,
            at: Date().addingTimeInterval(-12)
        )
        #expect(overlay.activeOperatorVectorSession(activeSessions: activeSessions) == nil)

        overlay.recordOperatorVector(
            OperatorVectorPayload(paramVector: 0.8, thoughtVector: 0.4, audioVector: -0.5, ttlSeconds: 3600),
            for: sessionId
        )
        #expect(overlay.activeOperatorVectorSession(activeSessions: activeSessions) == sessionId)

        var modelOut = ModelOut(
            tsMs: 1,
            mode: 2,
            params: [
                "density": 0.4,
                "brightness": 0.4,
                "level": 0.4
            ],
            picks: Picks(),
            flags: Flags(),
            visual: VisualOut.defaultForMode(2)
        )

        let result = overlay.applyOverlay(to: &modelOut, for: sessionId, activeSessions: activeSessions)
        #expect(result != nil)
        #expect((modelOut.params["level"] ?? 0) != 0.4)
    }

    @Test("AudiencePreferenceOverlay returns canonical active operator vector state")
    func audiencePreferenceOverlayCanonicalOperatorVectorState() {
        let overlay = AudiencePreferenceOverlay()
        let activeSessions: [String: AudienceSessionState] = [
            "session-a": AudienceSessionState(sessionId: "session-a", sessionType: .appCompanion),
            "session-b": AudienceSessionState(sessionId: "session-b", sessionType: .appCompanion)
        ]

        overlay.recordOperatorVector(
            OperatorVectorPayload(paramVector: 0.22, thoughtVector: -0.1, audioVector: 0.08, ttlSeconds: 300),
            for: "session-a"
        )
        overlay.recordOperatorVector(
            OperatorVectorPayload(paramVector: 0.81, thoughtVector: 0.25, audioVector: -0.2, ttlSeconds: 300),
            for: "session-b"
        )

        let state = overlay.activeOperatorVectorState(activeSessions: activeSessions)
        #expect(state?.sessionId == "session-b")
        #expect((state?.payload.ttlSeconds ?? 0) > 0)
        #expect(abs((state?.payload.paramVector ?? 0) - 0.81) < 0.02)
    }

    @Test("AudienceSessionServer broadcasts canonical operator vectors and switches source")
    func audienceSessionServerBroadcastsCanonicalOperatorVectors() {
        let server = AudienceSessionServer()
        server.enableOutgoingEnvelopeCaptureForTesting(true)

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-a"),
            connectionKey: "conn-a"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-b"),
            connectionKey: "conn-b"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorVector,
                sessionId: "session-a",
                operatorVector: OperatorVectorPayload(
                    paramVector: 0.2,
                    thoughtVector: 0.1,
                    audioVector: 0.1,
                    ttlSeconds: 300
                )
            ),
            connectionKey: "conn-a"
        )
        let firstBroadcast = server.takeOutgoingEnvelopesForTesting().filter { $0.kind == .operatorVector }
        #expect(firstBroadcast.count == 2)
        #expect(firstBroadcast.allSatisfy { $0.sessionId == "session-a" })

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorVector,
                sessionId: "session-b",
                operatorVector: OperatorVectorPayload(
                    paramVector: 0.9,
                    thoughtVector: -0.1,
                    audioVector: 0.2,
                    ttlSeconds: 300
                )
            ),
            connectionKey: "conn-b"
        )
        let secondBroadcast = server.takeOutgoingEnvelopesForTesting().filter { $0.kind == .operatorVector }
        #expect(secondBroadcast.count == 2)
        #expect(secondBroadcast.allSatisfy { $0.sessionId == "session-b" })
    }

    @Test("AudienceSessionServer session open includes canonical operator vector snapshot when available")
    func audienceSessionServerSessionOpenIncludesOperatorVectorSnapshot() {
        let server = AudienceSessionServer()
        server.enableOutgoingEnvelopeCaptureForTesting(true)

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-source"),
            connectionKey: "conn-source"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorVector,
                sessionId: "session-source",
                operatorVector: OperatorVectorPayload(
                    paramVector: 0.55,
                    thoughtVector: -0.2,
                    audioVector: 0.12,
                    ttlSeconds: 300
                )
            ),
            connectionKey: "conn-source"
        )
        _ = server.takeOutgoingEnvelopesForTesting()

        server.simulateEnvelopeForTesting(
            AudienceEnvelope(kind: .sessionOpen, sessionId: "session-late"),
            connectionKey: "conn-late"
        )
        let openEnvelopes = server.takeOutgoingEnvelopesForTesting()
        let descriptor = openEnvelopes.first(where: { $0.kind == .descriptorSnapshot })
        let canonicalVector = openEnvelopes.first(where: { $0.kind == .operatorVector })

        #expect(descriptor != nil)
        #expect(canonicalVector?.sessionId == "session-source")
        #expect((canonicalVector?.operatorVector?.ttlSeconds ?? 0) > 0)
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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
        #expect(decoded.modelIn.protocolVersion == ModeContract.supportedProtocolVersion)
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

    @Test("ModeContract fingerprint is locked")
    func modeContractFingerprintLocked() {
        let computed = ModeContract.contractFingerprint()
        if computed != ModeContract.lockedContractFingerprint {
            Issue.record("ModeContract fingerprint mismatch. locked=\(ModeContract.lockedContractFingerprint) computed=\(computed)")
        }
        #expect(computed == ModeContract.lockedContractFingerprint)
        let status = ModeContract.contractLockStatus()
        #expect(status.matched)
        #expect(status.lockedFingerprint == ModeContract.lockedContractFingerprint)
        #expect(status.computedFingerprint == computed)
    }

    @Test("ModeContract accepts legacy aliases for modes 0, 1, 3, 4, 7, 8, 9")
    func modeContractLegacyAliases() {
        let mode0 = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 1000,
            mode: 1,
            params: [
                "repeat_grid": 0.33,
                "stutter_len": 0.44,
                "feedback": 0.52,
                "motion_speed": 0.55,
            ],
            picks: ModeContract.defaultPicksByMode[1] ?? Picks(),
            flags: Flags()
        )
        let enforced1 = ModeContract.enforceIncoming(modelOut: mode1, currentMode: 1)
        #expect(enforced1.1.isEmpty)
        #expect(enforced1.0.params["hold_len_s"] != nil)
        #expect(enforced1.0.params["scene_rate_hz"] != nil)
        #expect(enforced1.0.params["hold_len_s"]! >= 6.0)
        #expect(enforced1.0.params["hold_len_s"]! <= 12.0)
        #expect(enforced1.0.params["motion_speed"] == 0.55)

        let mode3 = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 1000,
            mode: 3,
            params: [
                "bit_depth": 0.32,
                "downsample": 0.61,
                "resonance": 0.57,
                "brightness": 0.22,
            ],
            picks: ModeContract.defaultPicksByMode[3] ?? Picks(),
            flags: Flags()
        )
        let enforced3 = ModeContract.enforceIncoming(modelOut: mode3, currentMode: 3)
        #expect(enforced3.1.isEmpty)
        #expect(enforced3.0.params["bit_depth_bits"] != nil)
        #expect(enforced3.0.params["downsample_amt"] == 0.61)
        #expect(enforced3.0.params["res_shift"] == 0.57)
        #expect(enforced3.0.params["tone_db"] != nil)

        let mode4 = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 1000,
            mode: 9,
            params: [
                "band_low": 0.41,
                "band_high": 0.36,
                "motion_speed": 0.47,
            ],
            picks: Picks(
                presetId: "field_diffuse",
                bankId: nil,
                sampleId: nil,
                midiInstId: nil,
                spatialPatternId: "orbit_mid",
                sceneId: nil
            ),
            flags: Flags()
        )
        let enforced9 = ModeContract.enforceIncoming(modelOut: mode9, currentMode: 9)
        #expect(enforced9.1.isEmpty)
        #expect(enforced9.0.params["particle_density"] == 0.41)
        #expect(enforced9.0.params["particle_brightness"] == 0.36)
        #expect(enforced9.0.params["motion_speed"] == 0.47)
    }

    @Test("ML monitor renders only canonical params for the current mode")
    func mlMonitorCurrentModeParamsOnly() {
        let snapshot = MLMonitorMapper.buildSnapshot(
            currentMode: 4,
            context: ModelMonitorContext(
                rawPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 4,
                    params: ["gesture_rate": 0.4, "wet": 0.8],
                    picks: ModeContract.defaultPicksByMode[4] ?? Picks(),
                    flags: Flags()
                ),
                resolvedPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 4,
                    params: [
                        "density": 0.35,
                        "gesture_rate_hz": 2.4,
                        "sample_mix": 0.80,
                        "dry_level": 0.70,
                        "stability": 0.65
                    ],
                    picks: ModeContract.defaultPicksByMode[4] ?? Picks(),
                    flags: Flags()
                ),
                latencyMs: 17,
                contractViolations: [],
                pickNotes: [],
                receivedAt: Date()
            ),
            modeEngine: ModeEngine(),
            previous: nil
        )

        #expect(snapshot.waitingReason == nil)
        #expect(snapshot.resolvedKnobs.count == 5)
        #expect(snapshot.resolvedKnobs.map(\.canonicalKey) == ["density", "gesture_rate_hz", "sample_mix", "dry_level", "stability"])
    }

    @Test("ML monitor marks alias and defaulted params as harness-adjusted")
    func mlMonitorDiffsAliasAndDefaults() {
        let resolvedParams = ModeContract.clamp(
            params: [
                "repeat_prob": 0.9,
                "jitter_ms": 96.0
            ],
            mode: 1
        ).clamped

        let snapshot = MLMonitorMapper.buildSnapshot(
            currentMode: 1,
            context: ModelMonitorContext(
                rawPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 1,
                    params: [
                        "repeat_prob": 0.9,
                        "jitter_ms": 96.0
                    ],
                    picks: ModeContract.defaultPicksByMode[1] ?? Picks(),
                    flags: Flags()
                ),
                resolvedPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 1,
                    params: resolvedParams,
                    picks: ModeContract.defaultPicksByMode[1] ?? Picks(),
                    flags: Flags()
                ),
                latencyMs: 22,
                contractViolations: [],
                pickNotes: [],
                receivedAt: Date()
            ),
            modeEngine: ModeEngine(),
            previous: nil
        )

        let fracture = snapshot.resolvedKnobs.first(where: { $0.canonicalKey == "fracture" })
        let hold = snapshot.resolvedKnobs.first(where: { $0.canonicalKey == "hold_len_s" })

        #expect(fracture?.changedByHarness == true)
        #expect(fracture?.rawDisplayValue != nil)
        #expect(hold?.changedByHarness == true)
        #expect(hold?.rawDisplayValue == nil)
        #expect(snapshot.mismatchCount >= 2)
    }

    @Test("ML monitor shows pick diffs for manifest-resolved picks")
    func mlMonitorPickDiffs() {
        let raw = Picks(
            presetId: "ultrachunk_A",
            bankId: "samples_A",
            sampleId: "missing_sample",
            midiInstId: nil,
            chordSetId: nil,
            motifId: nil,
            articulationId: nil,
            spatialPatternId: "cluster_rotate",
            sceneId: nil,
            gridDiv: nil,
            repeatStyleId: nil,
            categoryId: "general",
            gestureTypeId: "call_response",
            mappingId: nil,
            varianceAmt: nil,
            variantSeed: nil,
            mappingFamily: nil
        )
        let resolved = ManifestCatalog.shared.resolve(mode: 4, picks: raw).picks
        let snapshot = MLMonitorMapper.buildSnapshot(
            currentMode: 4,
            context: ModelMonitorContext(
                rawPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 4,
                    params: ModeContract.safeModeParams[4] ?? [:],
                    picks: raw,
                    flags: Flags()
                ),
                resolvedPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 4,
                    params: ModeContract.safeModeParams[4] ?? [:],
                    picks: resolved,
                    flags: Flags()
                ),
                latencyMs: 13,
                contractViolations: [],
                pickNotes: ["sample_id_defaulted"],
                receivedAt: Date()
            ),
            modeEngine: ModeEngine(),
            previous: nil
        )

        let samplePick = snapshot.picks.first(where: { $0.pickKey == "sample_id" })
        #expect(samplePick != nil)
        #expect(samplePick?.changedByHarness == true)
        #expect(samplePick?.rawValue == "missing_sample")
    }

    @Test("ML monitor waits when the last packet mode does not match the selected mode")
    func mlMonitorWaitingOnModeSwitch() {
        let snapshot = MLMonitorMapper.buildSnapshot(
            currentMode: 7,
            context: ModelMonitorContext(
                rawPacket: nil,
                resolvedPacket: ModelOut(
                    protocolVersion: ModeContract.supportedProtocolVersion,
                    tsMs: 1000,
                    mode: 4,
                    params: ModeContract.safeModeParams[4] ?? [:],
                    picks: ModeContract.defaultPicksByMode[4] ?? Picks(),
                    flags: Flags()
                ),
                latencyMs: 19,
                contractViolations: [],
                pickNotes: [],
                receivedAt: Date()
            ),
            modeEngine: ModeEngine(),
            previous: nil
        )

        #expect(snapshot.isWaiting)
        #expect(snapshot.resolvedKnobs.isEmpty)
        #expect(snapshot.waitingReason?.contains("Mode 4") == true)
    }

    @Test("Held jolt remains high across control snapshots until release")
    func heldJoltPersistsAcrossSnapshots() {
        let client = TubMLClient(host: "127.0.0.1", port: 9910)

        client.setJoltHeld(true)
        let first = client.testingSnapshotButtons()
        let second = client.testingSnapshotButtons()
        client.setJoltHeld(false)
        let released = client.testingSnapshotButtons()

        #expect(first.jolt == true)
        #expect(second.jolt == true)
        #expect(released.jolt == false)
    }

    @Test("Video stage snapshot maps current mode picks and params")
    func videoStageSnapshotMapsCurrentMode() {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = VideoStageStore()
        let context = ModelMonitorContext(
            rawPacket: ModelOut(
                protocolVersion: ModeContract.supportedProtocolVersion,
                tsMs: 1_000,
                mode: 5,
                params: ["note_rate_notes_per_s": 1.2, "pitch_follow": 0.7],
                picks: Picks(
                    presetId: "room_clean",
                    bankId: "sf_A",
                    midiInstId: "inst_A",
                    chordSetId: "triads",
                    motifId: "motif_a"
                ),
                flags: Flags()
            ),
            resolvedPacket: ModelOut(
                protocolVersion: ModeContract.supportedProtocolVersion,
                tsMs: 1_000,
                mode: 5,
                params: [
                    "note_rate_notes_per_s": 1.2,
                    "voice_cap": 4,
                    "pitch_follow": 0.7,
                    "velocity_bias": 0.4,
                    "level": 0.66,
                    "stability": 0.55
                ],
                picks: Picks(
                    presetId: "room_clean",
                    bankId: "sf_A",
                    midiInstId: "inst_A",
                    chordSetId: "triads",
                    motifId: "motif_a"
                ),
                flags: Flags()
            ),
            latencyMs: 14,
            contractViolations: [],
            pickNotes: [],
            receivedAt: now
        )

        store.testingRebuild(context: context, mode: 5, isRunning: true, isJoltHeld: true, audioFeatures: .silence, now: now)
        let snapshot = store.snapshot

        #expect(snapshot.isRunning)
        #expect(snapshot.mode == 5)
        #expect(snapshot.wordmark.glitchStyle == ModeVisualProfile.forMode(5).wordmarkStyle)
        #expect(snapshot.params.map(\.id) == ["note_rate_notes_per_s", "voice_cap", "pitch_follow", "velocity_bias", "level", "stability"])
        #expect(snapshot.picks.contains(where: { $0.id == "bank_id" && $0.resolvedToken == "sf_A" }))
        #expect(snapshot.picks.contains(where: { $0.id == "midi_inst_id" && $0.resolvedToken == "inst_A" }))
        #expect(snapshot.joltHeld == true)
    }

    @Test("Video stage snapshot records recent param and pick changes")
    func videoStageSnapshotTracksRecentChanges() {
        let base = Date(timeIntervalSince1970: 2_000)
        let store = VideoStageStore()
        let initialContext = ModelMonitorContext(
            rawPacket: nil,
            resolvedPacket: ModelOut(
                protocolVersion: ModeContract.supportedProtocolVersion,
                tsMs: 2_000,
                mode: 4,
                params: [
                    "density": 0.35,
                    "gesture_rate_hz": 2.0,
                    "sample_mix": 0.72,
                    "dry_level": 0.62,
                    "stability": 0.48
                ],
                picks: Picks(
                    presetId: "ultrachunk_A",
                    bankId: "samples_A",
                    sampleId: "s000",
                    spatialPatternId: "cluster_rotate"
                ),
                flags: Flags()
            ),
            latencyMs: 11,
            contractViolations: [],
            pickNotes: [],
            receivedAt: base
        )
        let changedContext = ModelMonitorContext(
            rawPacket: nil,
            resolvedPacket: ModelOut(
                protocolVersion: ModeContract.supportedProtocolVersion,
                tsMs: 2_100,
                mode: 4,
                params: [
                    "density": 0.66,
                    "gesture_rate_hz": 2.0,
                    "sample_mix": 0.72,
                    "dry_level": 0.62,
                    "stability": 0.48
                ],
                picks: Picks(
                    presetId: "ultrachunk_A",
                    bankId: "samples_A",
                    sampleId: "s004",
                    spatialPatternId: "cluster_rotate"
                ),
                flags: Flags()
            ),
            latencyMs: 9,
            contractViolations: [],
            pickNotes: [],
            receivedAt: base.addingTimeInterval(0.2)
        )

        store.testingRebuild(context: initialContext, mode: 4, isRunning: true, isJoltHeld: false, audioFeatures: .silence, now: base)
        store.testingRebuild(context: changedContext, mode: 4, isRunning: true, isJoltHeld: false, audioFeatures: .silence, now: base.addingTimeInterval(0.2))
        let snapshot = store.snapshot
        let densityChange = snapshot.changes.first { $0.kind == .param && $0.token == "DENSITY" }
        let sampleChange = snapshot.changes.first { $0.kind == .pick && $0.token == "SAMPLE_ID" }

        #expect(densityChange?.resolvedToken == "0.66")
        #expect(sampleChange?.resolvedToken == "s004")
        #expect(snapshot.changes.count >= 2)
    }

    @Test("Video stage store piano tuner takeover flag toggles on and off")
    func videoStageStorePianoTunerFlagLifecycle() {
        let store = VideoStageStore()
        #expect(store.pianoTunerActive == false)

        store.setPianoTunerActive(true)
        #expect(store.pianoTunerActive == true)

        // Idempotent set should stay stable.
        store.setPianoTunerActive(true)
        #expect(store.pianoTunerActive == true)

        store.setPianoTunerActive(false)
        #expect(store.pianoTunerActive == false)
    }

    @Test("Manifest defaults resolve cleanly for modes 4 and 9")
    func manifestDefaultsResolveMode4AndMode9() {
        let manifests = ManifestCatalog.shared
        for mode in [4, 9] {
            let defaults = ModeContract.defaultPicksByMode[mode] ?? Picks()
            let resolved = manifests.resolve(mode: mode, picks: defaults)
            #expect(resolved.notes.isEmpty)
        }
    }

    @Test("Manifest resolution is case-insensitive for mode 4 and mode 9 picks")
    func manifestResolutionCaseInsensitiveMode4AndMode9() {
        let manifests = ManifestCatalog.shared

        let mode4 = manifests.resolve(
            mode: 4,
            picks: Picks(
                presetId: "ultrachunk_A",
                bankId: "SAMPLES_A",
                sampleId: "S000",
                midiInstId: nil,
                spatialPatternId: "CLUSTER_ROTATE",
                sceneId: nil
            )
        )
        #expect(mode4.picks.bankId == "samples_A")
        #expect(mode4.picks.sampleId == "s000")
        #expect(mode4.picks.spatialPatternId == "cluster_rotate")
        #expect(mode4.notes.isEmpty)

        let mode9 = manifests.resolve(
            mode: 9,
            picks: Picks(
                presetId: "field_diffuse",
                bankId: "PARTICLES_A",
                sampleId: nil,
                midiInstId: "INST_P",
                spatialPatternId: "ORBIT_MID",
                sceneId: nil
            )
        )
        #expect(mode9.picks.bankId == "particles_A")
        #expect(mode9.picks.midiInstId == "inst_P")
        #expect(mode9.picks.spatialPatternId == "orbit_mid")
        #expect(mode9.notes.isEmpty)
    }

    @Test("Mode 9 silently defaults optional bank and instrument picks")
    func manifestResolutionMode9SilentlyDefaultsOptionalPicks() {
        let manifests = ManifestCatalog.shared
        let resolved = manifests.resolve(
            mode: 9,
            picks: Picks(
                presetId: "field_diffuse",
                bankId: "unknown_particles_bank",
                sampleId: nil,
                midiInstId: "unknown_inst",
                spatialPatternId: "orbit_mid",
                sceneId: nil
            )
        )

        #expect(resolved.picks.bankId == "particles_A")
        #expect(resolved.picks.midiInstId == "inst_P")
        #expect(resolved.notes.isEmpty)
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
                        protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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

    @Test("Mode 3 mapping is wet-forward and bit/downsample-led")
    func mode3MappingBitFirstPosture() {
        let engine = ModeEngine()
        let defaults = ModeContract.defaultPicksByMode[3] ?? Picks()

        let baseOut = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 5_000,
            mode: 3,
            params: ModeContract.safeModeParams[3] ?? [:],
            picks: defaults,
            flags: Flags()
        )
        let base = engine.makeControl(out: baseOut, sentButtons: Buttons())
        #expect(base.mode == 3)
        #expect(base.wetLevel > base.dryLevel)
        #expect(base.wetLevel >= 0.40 && base.wetLevel <= 0.60)
        #expect(base.dryLevel >= 0.20 && base.dryLevel <= 0.56)
        #expect(base.exciteAmount >= 0.0 && base.exciteAmount <= 1.0)

        let driveHeavyOut = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 5_010,
            mode: 3,
            params: [
                "drive": 0.85,
                "bit_depth_bits": 12.0,
                "downsample_amt": 0.44,
                "res_shift": 0.64,
                "tone_db": -3.0,
            ],
            picks: defaults,
            flags: Flags()
        )
        let driveHeavy = engine.makeControl(out: driveHeavyOut, sentButtons: Buttons())

        let crushHeavyOut = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 5_020,
            mode: 3,
            params: [
                "drive": 0.52,
                "bit_depth_bits": 8.0,
                "downsample_amt": 1.0,
                "res_shift": 0.64,
                "tone_db": -3.0,
            ],
            picks: defaults,
            flags: Flags()
        )
        let crushHeavy = engine.makeControl(out: crushHeavyOut, sentButtons: Buttons())

        let driveDelta = abs(driveHeavy.wetLevel - base.wetLevel)
        let crushDelta = abs(crushHeavy.wetLevel - base.wetLevel)
        #expect(crushDelta > driveDelta)
        #expect(crushHeavy.wetLevel >= driveHeavy.wetLevel)
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
        #expect(resolvedMode9.notes == ["preset_id fallback to field_diffuse"])
    }

    @Test("ModeEngine target modes switch with finite controls")
    func modeEngineTargetModesStable() {
        let engine = ModeEngine()
        let modes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 7, 4, 1, 9, 2, 3, 5, 6]
        for mode in modes {
            let out = ModelOut(
                protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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

    @Test("Mode 1 scene macros map and scene_id override is honored")
    func mode1SceneMacroMappingAndSceneOverride() {
        let engine = ModeEngine()
        let out = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 2_400,
            mode: 1,
            params: [
                "fracture": 0.72,
                "mutation": 0.44,
                "pitch_lock": 0.81,
                "hold_len_s": 10.5,
                "tail_fade_ms": 820.0,
                "scene_rate_hz": 6.0,
                "motion_speed": 0.65,
                "spread": 0.74,
            ],
            picks: Picks(
                presetId: "beat_A",
                bankId: nil,
                sampleId: nil,
                midiInstId: nil,
                spatialPatternId: "orbit_pulse",
                sceneId: "spectral_melt",
                gridDiv: "1/16",
                repeatStyleId: "stutter_b"
            ),
            flags: Flags()
        )
        let control = engine.makeControl(out: out, sentButtons: Buttons(jolt: true, clear: true))
        #expect(control.mode == 1)
        #expect(control.mode1SceneId == "spectral_melt")
        #expect(control.mode1Fracture > 0.70)
        #expect(control.mode1Mutation > 0.40)
        #expect(control.mode1PitchLock > 0.75)
        #expect(control.mode1HoldLenSec >= 6.0 && control.mode1HoldLenSec <= 12.0)
        #expect(control.mode1TailFadeMs >= 150.0 && control.mode1TailFadeMs <= 1_200.0)
        #expect(control.mode1SceneRateHz >= 0.25 && control.mode1SceneRateHz <= 12.0)
        #expect(control.mode1ClearRequest)
        #expect(control.mode1JoltRequest)
    }

    @Test("Mode 1 legacy params deterministically map into scene macros")
    func mode1LegacyParamsMapToSceneMacros() {
        let engine = ModeEngine()
        let out = ModelOut(
            protocolVersion: ModeContract.supportedProtocolVersion,
            tsMs: 2_450,
            mode: 1,
            params: [
                "repeat_prob": 0.80,
                "jitter_ms": 72.0,
                "feedback": 0.40,
                "stutter_len_ms": 90.0,
            ],
            picks: Picks(
                presetId: "beat_A",
                bankId: nil,
                sampleId: nil,
                midiInstId: nil,
                spatialPatternId: "orbit_pulse",
                sceneId: nil,
                gridDiv: "1/8",
                repeatStyleId: "stutter_a"
            ),
            flags: Flags()
        )
        let control = engine.makeControl(out: out, sentButtons: Buttons())
        #expect(control.mode == 1)
        #expect(control.mode1Fracture >= 0.79)
        #expect(control.mode1Mutation > 0.50)
        #expect(control.mode1HoldLenSec > 9.0)
        #expect(control.mode1SceneRateHz > 1.0)
        #expect(control.mode1SceneId == "razor_gate")
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
                protocolVersion: ModeContract.supportedProtocolVersion,
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
        #expect(out.bundle.contractFingerprint == ModeContract.lockedContractFingerprint)
        #expect(FileManager.default.fileExists(atPath: out.fileURL.path))

        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: out.fileURL)) as? [String: Any]
        #expect(payload?["bundle_id"] as? String == "bundle_2026-03-24_testrev")
        #expect(payload?["policy_version"] as? String != nil)
        #expect(payload?["bank_manifest_version"] as? String != nil)
        #expect(payload?["contract_version"] as? String == ModeContract.contractVersion)
        #expect(payload?["contract_fingerprint"] as? String == ModeContract.lockedContractFingerprint)

        let banner = RunBundleFactory.startupBanner(bundle: out.bundle)
        #expect(banner.contains("lock=ok"))
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
            contractFingerprint: ModeContract.lockedContractFingerprint,
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
                protocolVersion: ModeContract.supportedProtocolVersion,
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
            contractFingerprint: ModeContract.lockedContractFingerprint,
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
                protocolVersion: ModeContract.supportedProtocolVersion,
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
            contractFingerprint: ModeContract.lockedContractFingerprint,
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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

    @Test("Mode 1 sample-hold planner stays grid-quantized in lock and fallback")
    func mode1SampleHoldPlannerQuantization() {
        let sampleRate: Float = 48_000

        var lockedClock = Mode1ClockState()
        lockedClock.configure(sampleRate: sampleRate)
        for _ in 0..<10 {
            lockedClock.advance(samples: 24_000)
            lockedClock.noteOnset(intervalSamples: 24_000, sampleRate: sampleRate)
        }
        let lockedGrid = lockedClock.stepSamples(gridDiv: "1/8", sampleRate: sampleRate)
        let lockedPlan = Mode1SampleHoldPlanner.plan(
            gridSamples: lockedGrid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.32,
            repeatStyleId: "stutter_a"
        )
        #expect(lockedPlan.outputHoldSamples > 0 && lockedPlan.outputHoldSamples <= lockedGrid)
        #expect(lockedPlan.feedbackHoldSamples > 0 && lockedPlan.feedbackHoldSamples <= lockedGrid)
        let lockedOutRatio = Float(lockedPlan.outputHoldSamples) / Float(lockedGrid)
        let lockedFbRatio = Float(lockedPlan.feedbackHoldSamples) / Float(lockedGrid)

        var fallbackClock = Mode1ClockState()
        fallbackClock.configure(sampleRate: sampleRate)
        fallbackClock.advance(samples: Int(sampleRate * 8))
        for _ in 0..<64 {
            fallbackClock.confidenceDecay()
        }
        let fallbackGrid = fallbackClock.stepSamples(gridDiv: "1/8", sampleRate: sampleRate)
        let fallbackPlan = Mode1SampleHoldPlanner.plan(
            gridSamples: fallbackGrid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.32,
            repeatStyleId: "stutter_a"
        )
        #expect(fallbackGrid == Int(sampleRate / 2))
        #expect(fallbackPlan.outputHoldSamples > 0 && fallbackPlan.outputHoldSamples <= fallbackGrid)
        #expect(fallbackPlan.feedbackHoldSamples > 0 && fallbackPlan.feedbackHoldSamples <= fallbackGrid)
        let fallbackOutRatio = Float(fallbackPlan.outputHoldSamples) / Float(fallbackGrid)
        let fallbackFbRatio = Float(fallbackPlan.feedbackHoldSamples) / Float(fallbackGrid)
        #expect(abs(fallbackOutRatio - lockedOutRatio) < 0.02)
        #expect(abs(fallbackFbRatio - lockedFbRatio) < 0.02)
        #expect(fallbackPlan.outputHoldSamples >= lockedPlan.outputHoldSamples)
        #expect(fallbackPlan.feedbackHoldSamples >= lockedPlan.feedbackHoldSamples)
    }

    @Test("Mode 1 sample-hold stutter_b is more aggressive than stutter_a")
    func mode1SampleHoldStyleSplitAggression() {
        let sampleRate: Float = 48_000
        let grid = 12_000
        let aPlan = Mode1SampleHoldPlanner.plan(
            gridSamples: grid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.32,
            repeatStyleId: "stutter_a"
        )
        let bPlan = Mode1SampleHoldPlanner.plan(
            gridSamples: grid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.32,
            repeatStyleId: "stutter_b"
        )
        #expect(bPlan.outputDepth > aPlan.outputDepth)
        #expect(bPlan.feedbackDepth > aPlan.feedbackDepth)
        #expect(bPlan.outputHoldSamples >= aPlan.outputHoldSamples)
        #expect(bPlan.feedbackHoldSamples >= aPlan.feedbackHoldSamples)
    }

    @Test("Mode 1 feedback parameter increases sample-hold feedback severity")
    func mode1SampleHoldFeedbackSeverity() {
        let sampleRate: Float = 48_000
        let grid = 12_000
        let low = Mode1SampleHoldPlanner.plan(
            gridSamples: grid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.10,
            repeatStyleId: "stutter_a"
        )
        let high = Mode1SampleHoldPlanner.plan(
            gridSamples: grid,
            sampleRate: sampleRate,
            stutterNorm: 0.10,
            gateNorm: 0.70,
            repeatProb: 0.66,
            feedbackNorm: 0.90,
            repeatStyleId: "stutter_a"
        )
        #expect(high.feedbackDepth > low.feedbackDepth)
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
            protocolVersion: ModeContract.supportedProtocolVersion,
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

    @Test("Output routing profile clamps mapping and calibration bounds")
    func outputRoutingProfileSanitize() {
        var profile = OutputRoutingProfile.defaultProfile(for: "dev_A", hardwareChannels: 4)
        profile.channels[0].hardwareOutput = 99
        profile.channels[1].hardwareOutput = -7
        profile.channels[2].gainDb = 99
        profile.channels[3].gainDb = -99
        profile.channels[4].delayMs = 999
        profile.channels[5].delayMs = -20
        profile.masterGainDb = 99
        profile.testLevelDb = -99

        profile.sanitize(for: 4)

        #expect(profile.channels[0].hardwareOutput == 4)
        #expect(profile.channels[1].hardwareOutput == 1)
        #expect(profile.channels[2].gainDb == OutputRoutingProfile.maxGainDb)
        #expect(profile.channels[3].gainDb == OutputRoutingProfile.minGainDb)
        #expect(profile.channels[4].delayMs == OutputRoutingProfile.maxDelayMs)
        #expect(profile.channels[5].delayMs == OutputRoutingProfile.minDelayMs)
        #expect(profile.masterGainDb == OutputRoutingProfile.maxMasterGainDb)
        #expect(profile.testLevelDb == OutputRoutingProfile.minTestLevelDb)
    }

    @Test("Output route planner falls back when 6ch lock is unavailable")
    func outputRoutePlannerFallback() {
        let failBind = OutputRoutePlanner.decide(preferredMode: .gallery6Locked, hardwareChannels: 6, bindSucceeded: false)
        #expect(failBind.mode == .stereoFallback)
        #expect(failBind.warning == "output_bind_failed")

        let short = OutputRoutePlanner.decide(preferredMode: .gallery6Locked, hardwareChannels: 2, bindSucceeded: true)
        #expect(short.mode == .stereoFallback)
        #expect(short.warning == "output_channel_shortfall_2")

        let ok = OutputRoutePlanner.decide(preferredMode: .gallery6Locked, hardwareChannels: 8, bindSucceeded: true)
        #expect(ok.mode == .gallery6Locked)
        #expect(ok.locked)
        #expect(ok.warning == nil)
    }

    @Test("Output routing persistence round-trips per-device profiles")
    func outputRoutingPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tub-output-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("output_routing.json")

        var pA = OutputRoutingProfile.defaultProfile(for: "dev_A", hardwareChannels: 8)
        pA.channels[0].hardwareOutput = 6
        pA.channels[0].gainDb = -3
        pA.preferredMode = .gallery6Locked

        var pB = OutputRoutingProfile.defaultProfile(for: "dev_B", hardwareChannels: 2)
        pB.preferredMode = .stereoFallback
        pB.channels[1].solo = true

        let state = OutputRoutingStore(
            selectedOutputUID: "dev_A",
            profilesByUID: [
                "dev_A": pA,
                "dev_B": pB
            ]
        )

        OutputRoutingPersistence.saveState(state, fileURL: url)
        let loaded = OutputRoutingPersistence.loadState(fileURL: url)
        #expect(loaded.selectedOutputUID == "dev_A")
        #expect(loaded.profilesByUID["dev_A"]?.channels[0].hardwareOutput == 6)
        #expect(loaded.profilesByUID["dev_B"]?.preferredMode == .stereoFallback)
        #expect(loaded.profilesByUID["dev_B"]?.channels[1].solo == true)
    }

    @Test("Input routing profile preserves locked primary and clamps channel count")
    func inputRoutingProfileSanitize() {
        var profile = InputRoutingProfile(
            deviceUID: "dev_in",
            activeChannels: [false, true, true, true, true],
            channelGainDb: [36, 1, -3, -40, 12]
        )
        let warning = profile.sanitize(for: 3)

        #expect(warning == "input_channel_shortfall_3")
        #expect(profile.activeChannels.count == 3)
        #expect(profile.channelGainDb.count == 3)
        #expect(profile.activeChannels[0] == true)
        #expect(profile.activeChannels[1] == true)
        #expect(profile.activeChannels[2] == true)
        #expect(profile.channelGainDb[0] == InputRoutingProfile.maxChannelGainDb)
        #expect(profile.channelGainDb[1] == 1)
        #expect(profile.channelGainDb[2] == -3)
    }

    @Test("Input routing persistence round-trips per-device active paths")
    func inputRoutingPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tub-input-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("input_routing.json")

        var pA = InputRoutingProfile.defaultProfile(for: "dev_A", inputChannels: 4)
        pA.activeChannels = [true, true, false, true]
        pA.channelGainDb = [0, 6, -3, 1.5]
        var pB = InputRoutingProfile.defaultProfile(for: "dev_B", inputChannels: 2)
        pB.activeChannels = [true, false]
        pB.channelGainDb = [0, -12]

        let state = InputRoutingStore(
            selectedInputUID: "dev_A",
            profilesByUID: [
                "dev_A": pA,
                "dev_B": pB
            ]
        )

        InputRoutingPersistence.saveState(state, fileURL: url)
        let loaded = InputRoutingPersistence.loadState(fileURL: url)
        #expect(loaded.selectedInputUID == "dev_A")
        #expect(loaded.profilesByUID["dev_A"]?.activeChannels == [true, true, false, true])
        #expect(loaded.profilesByUID["dev_A"]?.channelGainDb == [0, 6, -3, 1.5])
        #expect(loaded.profilesByUID["dev_B"]?.activeChannels == [true, false])
        #expect(loaded.profilesByUID["dev_B"]?.channelGainDb == [0, -12])
    }

    @Test("Input channel router mixes only active channels, applies gain, and keeps primary hot")
    func inputChannelRouterMixesActiveChannels() {
        let channels: [[Float]] = [
            [1.0, 1.0, 1.0],
            [0.0, 2.0, 4.0],
            [6.0, 6.0, 6.0]
        ]

        let mixedPrimaryOnly = InputChannelRouter.mixChannels(channels, activeMask: [false, false, false])
        #expect(mixedPrimaryOnly == [1.0, 1.0, 1.0])

        let mixedPrimaryPlusSecond = InputChannelRouter.mixChannels(channels, activeMask: [true, true, false])
        #expect(mixedPrimaryPlusSecond[0] == 0.5)
        #expect(mixedPrimaryPlusSecond[1] == 1.5)
        #expect(mixedPrimaryPlusSecond[2] == 2.5)

        let mixedWithGain = InputChannelRouter.mixChannels(
            channels,
            activeMask: [true, true, false],
            channelGainDb: [0, 6, 0]
        )
        #expect(mixedWithGain[0] == mixedPrimaryPlusSecond[0])
        #expect(mixedWithGain[1] > mixedPrimaryPlusSecond[1])
        #expect(mixedWithGain[2] > mixedPrimaryPlusSecond[2])
    }

    @Test("Input resampler preserves equal-rate live buffers")
    func inputResamplerEqualRate() {
        var state = InputResampleState()
        let samples: [Float] = [0.0, 0.5, -0.25, 1.0, -1.0]
        let out = InputResampler.resample(
            samples: samples,
            sourceSampleRate: 48_000,
            outputSampleRate: 48_000,
            state: &state
        )

        #expect(out.count == samples.count)
        for idx in samples.indices {
            #expect(abs(out[idx] - samples[idx]) < 0.0001)
        }
    }

    @Test("Input resampler expands slower input toward faster output rate")
    func inputResamplerUpsamples() {
        var state = InputResampleState()
        let samples: [Float] = [0.0, 1.0, 0.0, -1.0]
        let out = InputResampler.resample(
            samples: samples,
            sourceSampleRate: 24_000,
            outputSampleRate: 48_000,
            state: &state
        )

        #expect(out.count >= 7)
        #expect(abs(out.first! - samples.first!) < 0.0001)
        #expect(abs(out.last! - samples.last!) < 0.0001)
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

    // MARK: - SoftLink

    @Test("SoftLink activatePairing emits pairingStarted and injects sprites into VideoStageStore")
    @MainActor
    func softLinkActivatePairingEmitsAndInjectsSprites() {
        let coordinator = SoftLinkCoordinator()
        let store = VideoStageStore()

        coordinator.videoStore = store

        #expect(coordinator.globalState == .idle)
        coordinator.activatePairing()
        #expect({
            if case .listening = coordinator.globalState { return true }
            return false
        }())
        #expect(store.snapshot.sprites.contains(where: { $0.token == "PAIRING MODE" }))
    }

    @Test("SoftLink gesture detects 3 taps then hold")
    func softLinkGestureDetectsPattern() {
        var gesture = JoltLinkGesture()
        let start = Date()

        // 3 quick taps
        for i in 0..<3 {
            let t = start.addingTimeInterval(Double(i) * 0.3)
            gesture.holdBegan(at: t)
            gesture.holdEnded(at: t.addingTimeInterval(0.1))
        }

        #expect(gesture.recentTapCount(at: start.addingTimeInterval(1.0)) == 3)

        // 4th press + hold for 0.6s
        let holdStart = start.addingTimeInterval(1.0)
        gesture.holdBegan(at: holdStart)
        let checkTime = holdStart.addingTimeInterval(0.6)
        #expect(gesture.shouldTrigger(at: checkTime))
    }

    // MARK: - KinectUDPProvider

    @Test("KinectUDPProvider parses valid body detection packet")
    func kinectUDPProviderParsesPacket() {
        let provider = KinectUDPProvider()
        let json = """
        {"bodies":[
            {"bodyIndex":0,"x":960.0,"y":540.0,"depthZ":2.5,"confidence":0.9,"isTracked":true},
            {"bodyIndex":1,"x":300.0,"y":400.0,"depthZ":3.2,"confidence":0.7,"isTracked":true}
        ]}
        """
        provider.parsePacket(Data(json.utf8))

        let bodies = provider.getActiveBodies()
        #expect(bodies.count == 2)
        #expect(bodies[0].bodyIndex == 0)
        #expect(bodies[0].position.x == 960.0)
        #expect(bodies[0].depthZ == 2.5)
        #expect(bodies[0].confidence == 0.9)
        #expect(bodies[1].bodyIndex == 1)
        #expect(bodies[1].depthZ == 3.2)
    }

    @Test("KinectUDPProvider handles empty bodies array")
    func kinectUDPProviderEmptyBodies() {
        let provider = KinectUDPProvider()
        provider.parsePacket(Data(#"{"bodies":[]}"#.utf8))

        let bodies = provider.getActiveBodies()
        #expect(bodies.isEmpty)
    }

    @Test("KinectUDPProvider filters untracked bodies")
    func kinectUDPProviderFiltersUntracked() {
        let provider = KinectUDPProvider()
        let json = """
        {"bodies":[
            {"bodyIndex":0,"x":100.0,"y":200.0,"depthZ":1.5,"confidence":0.8,"isTracked":true},
            {"bodyIndex":1,"x":300.0,"y":400.0,"depthZ":2.0,"confidence":0.3,"isTracked":false}
        ]}
        """
        provider.parsePacket(Data(json.utf8))

        let bodies = provider.getActiveBodies()
        #expect(bodies.count == 1)
        #expect(bodies[0].bodyIndex == 0)
    }

    @Test("KinectUDPProvider getNearestBody returns closest")
    func kinectUDPProviderNearestBody() {
        let provider = KinectUDPProvider()
        let json = """
        {"bodies":[
            {"bodyIndex":0,"x":100.0,"y":100.0,"depthZ":2.0,"confidence":0.9,"isTracked":true},
            {"bodyIndex":1,"x":900.0,"y":500.0,"depthZ":3.0,"confidence":0.8,"isTracked":true}
        ]}
        """
        provider.parsePacket(Data(json.utf8))

        let nearest = provider.getNearestBody(to: CGPoint(x: 850, y: 450))
        #expect(nearest?.bodyIndex == 1)
    }

    @Test("KinectUDPProvider ignores malformed packets")
    func kinectUDPProviderMalformedPacket() {
        let provider = KinectUDPProvider()
        // First set valid data
        provider.parsePacket(Data(#"{"bodies":[{"bodyIndex":0,"x":100.0,"y":200.0,"depthZ":1.0,"confidence":0.5,"isTracked":true}]}"#.utf8))
        #expect(provider.getActiveBodies().count == 1)

        // Malformed packet should be ignored, previous data remains
        provider.parsePacket(Data("not json".utf8))
        #expect(provider.getActiveBodies().count == 1)
    }
}

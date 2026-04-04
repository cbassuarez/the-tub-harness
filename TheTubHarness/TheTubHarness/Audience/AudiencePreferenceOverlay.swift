//
//  AudiencePreferenceOverlay.swift
//  TheTubHarness
//
//  Post-ML overlay that applies audience preference influence.
//  Bounded, reversible, applies to params and thought output.
//

import Foundation

struct AudienceOverlayResult {
    let visualChanged: Bool
    let adjustedParameterKeys: [String]
    let thought: String
}

struct ActiveOperatorVectorState: Equatable {
    let sessionId: String
    let payload: OperatorVectorPayload
}

class AudiencePreferenceOverlay {
    private let maxBias: Double = 0.5
    private let minBias: Double = -0.5

    private struct OperatorVectorEntry {
        let paramVector: Double
        let thoughtVector: Double
        let audioVector: Double
        let setAt: Date
        let ttlSeconds: TimeInterval
    }
    
    private var activeBiases: [String: ThoughtBias] = [:]
    private var sessionWeights: [String: [String: Double]] = [:]
    private var biasActivatedAt: [String: Date] = [:]
    private var operatorVectors: [String: OperatorVectorEntry] = [:]
    private let biasLock = NSLock()
    
    func recordPreferenceEvent(_ event: AudiencePreferenceEvent) {
        biasLock.lock()
        defer { biasLock.unlock() }
        
        let sessionId = event.sessionId
        
        switch event.eventType {
        case .dragTowardDescriptor:
            if let descriptor = event.descriptorLabel {
                var weights = sessionWeights[sessionId] ?? [:]
                weights[descriptor] = (weights[descriptor] ?? 0.0) + (event.intensity * 0.1)
                sessionWeights[sessionId] = weights
            }
        
        case .hold:
            // Reinforce current state
            let bias = ThoughtBias(biasFactor: event.intensity * 0.2, sustainDurationMs: 1000)
            activeBiases[sessionId] = bias
            biasActivatedAt[sessionId] = event.timestamp
        
        case .moreAction:
            // Increase general intensity
            var weights = sessionWeights[sessionId] ?? [:]
            weights["_intensity_"] = (weights["_intensity_"] ?? 0.0) + (event.intensity * 0.1)
            sessionWeights[sessionId] = weights
        
        case .lessAction:
            // Decrease general intensity
            var weights = sessionWeights[sessionId] ?? [:]
            weights["_intensity_"] = (weights["_intensity_"] ?? 0.0) - (event.intensity * 0.1)
            sessionWeights[sessionId] = weights
        
        case .release:
            activeBiases.removeValue(forKey: sessionId)
            biasActivatedAt.removeValue(forKey: sessionId)

        case .pairwiseCompare:
            break
        }
    }

    func recordOperatorVector(_ payload: OperatorVectorPayload, for sessionId: String, at timestamp: Date = Date()) {
        biasLock.lock()
        defer { biasLock.unlock() }

        let clampedParam = min(max(payload.paramVector, -1), 1)
        let clampedThought = min(max(payload.thoughtVector, -1), 1)
        let clampedAudio = min(max(payload.audioVector, -1), 1)
        let ttl = max(0, payload.ttlSeconds)

        if ttl <= 0 || (abs(clampedParam) < 0.0001 && abs(clampedThought) < 0.0001 && abs(clampedAudio) < 0.0001) {
            operatorVectors.removeValue(forKey: sessionId)
            return
        }

        operatorVectors[sessionId] = OperatorVectorEntry(
            paramVector: clampedParam,
            thoughtVector: clampedThought,
            audioVector: clampedAudio,
            setAt: timestamp,
            ttlSeconds: ttl
        )
    }

    func activeOperatorVectorSession(activeSessions: [String: AudienceSessionState], now: Date = Date()) -> String? {
        activeOperatorVectorState(activeSessions: activeSessions, now: now)?.sessionId
    }

    func activeOperatorVectorState(
        activeSessions: [String: AudienceSessionState],
        now: Date = Date()
    ) -> ActiveOperatorVectorState? {
        biasLock.lock()
        defer { biasLock.unlock() }
        pruneExpiredOperatorVectors(now: now)

        var bestSessionId: String?
        var bestVector: (paramVector: Double, thoughtVector: Double, audioVector: Double)?
        var bestRemainingTTL: TimeInterval = 0
        var bestMagnitude: Double = 0
        for (sessionId, entry) in operatorVectors where activeSessions[sessionId] != nil {
            let vector = decayedOperatorVector(from: entry, now: now)
            let remainingTTL = max(0, entry.ttlSeconds - now.timeIntervalSince(entry.setAt))
            guard remainingTTL > 0 else { continue }
            let magnitude = max(abs(vector.paramVector), max(abs(vector.thoughtVector), abs(vector.audioVector)))
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestSessionId = sessionId
                bestVector = vector
                bestRemainingTTL = remainingTTL
            }
        }

        guard
            let sessionId = bestSessionId,
            let vector = bestVector
        else {
            return nil
        }

        return ActiveOperatorVectorState(
            sessionId: sessionId,
            payload: OperatorVectorPayload(
                paramVector: vector.paramVector,
                thoughtVector: vector.thoughtVector,
                audioVector: vector.audioVector,
                ttlSeconds: bestRemainingTTL
            )
        )
    }
    
    func applyOverlay(
        to modelOut: inout ModelOut,
        for sessionId: String,
        activeSessions: [String: AudienceSessionState]
    ) -> AudienceOverlayResult? {
        biasLock.lock()
        defer { biasLock.unlock() }

        let now = Date()
        pruneExpiredOperatorVectors(now: now)
        
        guard activeSessions[sessionId] != nil else { return nil }
        
        var visual = modelOut.visual
        var visualModified = false
        var params = modelOut.params
        var adjustedParameterKeys: Set<String> = []
        
        func clamped(_ value: Double) -> Double {
            min(1.0, max(0.0, value))
        }
        
        func adjustParam(_ key: String, delta: Double) {
            let current = params[key] ?? 0.5
            let next = clamped(current + delta)
            if abs(next - current) > 0.000_1 {
                params[key] = next
                adjustedParameterKeys.insert(key)
            }
        }
        
        // Apply explicit thought bias only when authoritatively provided.
        if let bias = activeBiases[sessionId] {
            let isBiasFresh: Bool
            if let activatedAt = biasActivatedAt[sessionId] {
                let ageMs = Date().timeIntervalSince(activatedAt) * 1000
                isBiasFresh = ageMs <= Double(bias.sustainDurationMs)
            } else {
                isBiasFresh = false
            }

            if !isBiasFresh {
                activeBiases.removeValue(forKey: sessionId)
                biasActivatedAt.removeValue(forKey: sessionId)
            } else if let newThought = bias.targetThoughts.first, !newThought.isEmpty, newThought != visual.thought {
                visual = VisualOut(
                    sceneId: visual.sceneId,
                    density: visual.density,
                    cohesion: visual.cohesion,
                    disruption: visual.disruption,
                    tokenSalience: visual.tokenSalience,
                    wordmarkIntegrity: visual.wordmarkIntegrity,
                    decayMs: visual.decayMs,
                    flashBias: visual.flashBias,
                    anchorWeights: visual.anchorWeights,
                    thought: newThought,
                    thoughtLog: visual.thoughtLog
                )
                visualModified = true
            }
        }
        
        // Apply param weightings (bounded)
        if let weights = sessionWeights[sessionId] {
            var densityDelta: Double = 0
            var brightnessDelta: Double = 0
            var levelDelta: Double = 0
            var disruptionDelta: Double = 0
            var flashDelta: Double = 0

            for (key, weight) in weights {
                let boundedWeight = min(max(weight, minBias), maxBias)
                let token = key.uppercased()

                switch token {
                case "_INTENSITY_":
                    levelDelta += boundedWeight * 0.28
                    brightnessDelta += boundedWeight * 0.20
                    densityDelta += boundedWeight * 0.12
                case "DENSE":
                    densityDelta += boundedWeight * 0.30
                case "SPARSE":
                    densityDelta -= boundedWeight * 0.30
                case "WARM":
                    brightnessDelta += boundedWeight * 0.16
                    disruptionDelta -= boundedWeight * 0.08
                case "COLD":
                    brightnessDelta -= boundedWeight * 0.18
                case "DRIFT":
                    disruptionDelta += boundedWeight * 0.14
                case "STRIKE":
                    disruptionDelta += boundedWeight * 0.18
                    flashDelta += boundedWeight * 0.22
                case "STABLE":
                    disruptionDelta -= boundedWeight * 0.18
                case "ABERRANT":
                    disruptionDelta += boundedWeight * 0.24
                default:
                    break
                }
            }

            adjustParam("density", delta: densityDelta)
            adjustParam("brightness", delta: brightnessDelta)
            adjustParam("level", delta: levelDelta)

            let nextDisruption = clamped(visual.disruption + disruptionDelta)
            let nextFlash = clamped(visual.flashBias + flashDelta)
            let nextDensity = params["density"] ?? visual.density

            if abs(nextDisruption - visual.disruption) > 0.000_1 ||
                abs(nextFlash - visual.flashBias) > 0.000_1 ||
                abs(nextDensity - visual.density) > 0.000_1 {
                visual = VisualOut(
                    sceneId: visual.sceneId,
                    density: nextDensity,
                    cohesion: visual.cohesion,
                    disruption: nextDisruption,
                    tokenSalience: visual.tokenSalience,
                    wordmarkIntegrity: visual.wordmarkIntegrity,
                    decayMs: visual.decayMs,
                    flashBias: nextFlash,
                    anchorWeights: visual.anchorWeights,
                    thought: visual.thought,
                    thoughtLog: visual.thoughtLog
                )
                visualModified = true
            }
        }

        // Apply temporary operator vectors with wall-clock decay.
        if let entry = operatorVectors[sessionId] {
            let vector = decayedOperatorVector(from: entry, now: now)
            if max(abs(vector.paramVector), max(abs(vector.thoughtVector), abs(vector.audioVector))) > 0.0001 {
                adjustParam("density", delta: vector.paramVector * 0.22)
                adjustParam("level", delta: vector.audioVector * 0.26)
                adjustParam("brightness", delta: (vector.audioVector * 0.20) + (vector.paramVector * 0.08))

                let nextDisruption = clamped(visual.disruption + (vector.thoughtVector * 0.22) + (vector.paramVector * 0.08))
                let nextCohesion = clamped(visual.cohesion - (vector.thoughtVector * 0.17))
                let nextFlash = clamped(visual.flashBias + (vector.paramVector * 0.16))
                let nextDensity = params["density"] ?? visual.density

                let currentThought = visual.thought
                let thoughtPrefix: String
                if vector.thoughtVector >= 0.12 {
                    thoughtPrefix = "focus"
                } else if vector.thoughtVector <= -0.12 {
                    thoughtPrefix = "drift"
                } else {
                    thoughtPrefix = ""
                }
                let nextThought = thoughtPrefix.isEmpty ? currentThought : "\(thoughtPrefix) \(currentThought)"

                if abs(nextDisruption - visual.disruption) > 0.000_1 ||
                    abs(nextCohesion - visual.cohesion) > 0.000_1 ||
                    abs(nextFlash - visual.flashBias) > 0.000_1 ||
                    abs(nextDensity - visual.density) > 0.000_1 ||
                    nextThought != currentThought {
                    visual = VisualOut(
                        sceneId: visual.sceneId,
                        density: nextDensity,
                        cohesion: nextCohesion,
                        disruption: nextDisruption,
                        tokenSalience: visual.tokenSalience,
                        wordmarkIntegrity: visual.wordmarkIntegrity,
                        decayMs: visual.decayMs,
                        flashBias: nextFlash,
                        anchorWeights: visual.anchorWeights,
                        thought: nextThought,
                        thoughtLog: visual.thoughtLog
                    )
                    visualModified = true
                }
            }
        }

        guard visualModified || !adjustedParameterKeys.isEmpty else {
            return nil
        }

        modelOut = ModelOut(
            protocolVersion: modelOut.protocolVersion,
            tsMs: modelOut.tsMs,
            mode: modelOut.mode,
            params: params,
            picks: modelOut.picks,
            flags: modelOut.flags,
            visual: visual
        )

        return AudienceOverlayResult(
            visualChanged: visualModified,
            adjustedParameterKeys: Array(adjustedParameterKeys).sorted(),
            thought: visual.thought
        )
    }
    
    func clearSession(_ sessionId: String) {
        biasLock.lock()
        defer { biasLock.unlock() }
        
        activeBiases.removeValue(forKey: sessionId)
        biasActivatedAt.removeValue(forKey: sessionId)
        sessionWeights.removeValue(forKey: sessionId)
        operatorVectors.removeValue(forKey: sessionId)
    }

    private func pruneExpiredOperatorVectors(now: Date) {
        operatorVectors = operatorVectors.filter { _, entry in
            now.timeIntervalSince(entry.setAt) < entry.ttlSeconds
        }
    }

    private func decayedOperatorVector(
        from entry: OperatorVectorEntry,
        now: Date
    ) -> (paramVector: Double, thoughtVector: Double, audioVector: Double) {
        guard entry.ttlSeconds > 0 else { return (0, 0, 0) }
        let elapsed = max(0, now.timeIntervalSince(entry.setAt))
        let remaining = max(0, entry.ttlSeconds - elapsed)
        let factor = max(0, min(1, remaining / entry.ttlSeconds))
        return (
            entry.paramVector * factor,
            entry.thoughtVector * factor,
            entry.audioVector * factor
        )
    }
}

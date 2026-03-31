//
//  ModelPackets.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import Foundation

// MARK: - Strict decoding helper

struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

@inline(__always)
private func requireMode0to10(_ mode: Int, decoder: Decoder) throws {
    guard (0...10).contains(mode) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "mode out of range 0...10: \(mode)"
        ))
    }
}

@inline(__always)
private func assertNoUnknownKeys(
    _ type: Any.Type,
    decoder: Decoder,
    allowedKeys: Set<String>
) throws {
    let all = try decoder.container(keyedBy: AnyCodingKey.self)
    let unknown = Set(all.allKeys.map(\.stringValue)).subtracting(allowedKeys)
    if !unknown.isEmpty {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown keys for \(type): \(unknown.sorted())"
            )
        )
    }
}

// MARK: - Packets (mirror Python Pydantic)

struct Buttons: Codable, Equatable {
    let jolt: Bool
    let clear: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case jolt, clear }

    init(jolt: Bool = false, clear: Bool = false) {
        self.jolt = jolt
        self.clear = clear
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(Buttons.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jolt = try c.decodeIfPresent(Bool.self, forKey: .jolt) ?? false
        self.clear = try c.decodeIfPresent(Bool.self, forKey: .clear) ?? false
    }
}

struct Features: Codable, Equatable {
    let loudnessLufs: Double
    let onsetRateHz: Double
    let specCentroidHz: Double
    let bandLow: Double
    let bandMid: Double
    let bandHigh: Double
    let noisiness: Double
    let pitchHz: Double?
    let pitchConf: Double
    let keyEstimate: String?
    let keyConf: Double

    enum CodingKeys: String, CodingKey, CaseIterable {
        case loudnessLufs, onsetRateHz, specCentroidHz, bandLow, bandMid, bandHigh, noisiness
        case pitchHz, pitchConf, keyEstimate, keyConf
    }

    init(loudnessLufs: Double, onsetRateHz: Double, specCentroidHz: Double,
         bandLow: Double, bandMid: Double, bandHigh: Double, noisiness: Double,
         pitchHz: Double? = nil, pitchConf: Double = 0.0, keyEstimate: String? = nil, keyConf: Double = 0.0) {
        self.loudnessLufs = loudnessLufs
        self.onsetRateHz = onsetRateHz
        self.specCentroidHz = specCentroidHz
        self.bandLow = bandLow
        self.bandMid = bandMid
        self.bandHigh = bandHigh
        self.noisiness = noisiness
        self.pitchHz = pitchHz
        self.pitchConf = min(max(pitchConf, 0.0), 1.0)
        self.keyEstimate = keyEstimate
        self.keyConf = min(max(keyConf, 0.0), 1.0)
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(Features.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.loudnessLufs = try c.decode(Double.self, forKey: .loudnessLufs)
        self.onsetRateHz = try c.decode(Double.self, forKey: .onsetRateHz)
        self.specCentroidHz = try c.decode(Double.self, forKey: .specCentroidHz)
        self.bandLow = try c.decode(Double.self, forKey: .bandLow)
        self.bandMid = try c.decode(Double.self, forKey: .bandMid)
        self.bandHigh = try c.decode(Double.self, forKey: .bandHigh)
        self.noisiness = try c.decode(Double.self, forKey: .noisiness)
        self.pitchHz = try c.decodeIfPresent(Double.self, forKey: .pitchHz)
        self.pitchConf = min(max(try c.decodeIfPresent(Double.self, forKey: .pitchConf) ?? 0.0, 0.0), 1.0)
        self.keyEstimate = try c.decodeIfPresent(String.self, forKey: .keyEstimate)
        self.keyConf = min(max(try c.decodeIfPresent(Double.self, forKey: .keyConf) ?? 0.0, 0.0), 1.0)
    }
}

extension Features {
    static let silence = Features(
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

struct HarnessState: Codable, Equatable {
    let overload: Bool
    let cooldown: Double
    let lastModeMs: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case overload, cooldown, lastModeMs }

    init(overload: Bool = false, cooldown: Double = 0.0, lastModeMs: Int = 0) {
        self.overload = overload
        self.cooldown = cooldown
        self.lastModeMs = lastModeMs
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(HarnessState.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.overload = try c.decodeIfPresent(Bool.self, forKey: .overload) ?? false
        self.cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldown) ?? 0.0
        self.lastModeMs = try c.decodeIfPresent(Int.self, forKey: .lastModeMs) ?? 0
    }
}

struct ModelIn: Codable, Equatable {
    let protocolVersion: Int
    let tsMs: Int
    let sessionId: String
    let frameHz: Int
    let mode: Int
    let buttons: Buttons
    let features: Features
    let state: HarnessState?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion, tsMs, sessionId, frameHz, mode, buttons, features, state
    }

    init(protocolVersion: Int = ModeContract.supportedProtocolVersion, tsMs: Int, sessionId: String, frameHz: Int = 10, mode: Int,
         buttons: Buttons, features: Features, state: HarnessState? = nil) {
        self.protocolVersion = protocolVersion
        self.tsMs = tsMs
        self.sessionId = sessionId
        self.frameHz = frameHz
        self.mode = mode
        self.buttons = buttons
        self.features = features
        self.state = state
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(ModelIn.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        guard self.protocolVersion == ModeContract.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: c,
                debugDescription: "Unsupported protocolVersion \(self.protocolVersion)"
            )
        }
        self.tsMs = try c.decode(Int.self, forKey: .tsMs)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.frameHz = try c.decodeIfPresent(Int.self, forKey: .frameHz) ?? 10
        self.mode = try c.decode(Int.self, forKey: .mode)
        try requireMode0to10(self.mode, decoder: decoder)
        self.buttons = try c.decode(Buttons.self, forKey: .buttons)
        self.features = try c.decode(Features.self, forKey: .features)
        self.state = try c.decodeIfPresent(HarnessState.self, forKey: .state)
    }
}

struct Flags: Codable, Equatable {
    let requestCooldown: Bool
    let preferStability: Bool
    let thinEvents: Bool
    let resetVoices: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case requestCooldown, preferStability, thinEvents, resetVoices }

    init(requestCooldown: Bool = false, preferStability: Bool = true, thinEvents: Bool = false, resetVoices: Bool = false) {
        self.requestCooldown = requestCooldown
        self.preferStability = preferStability
        self.thinEvents = thinEvents
        self.resetVoices = resetVoices
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(Flags.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.requestCooldown = try c.decodeIfPresent(Bool.self, forKey: .requestCooldown) ?? false
        self.preferStability = try c.decodeIfPresent(Bool.self, forKey: .preferStability) ?? true
        self.thinEvents = try c.decodeIfPresent(Bool.self, forKey: .thinEvents) ?? false
        self.resetVoices = try c.decodeIfPresent(Bool.self, forKey: .resetVoices) ?? false
    }
}

struct VisualOut: Codable, Equatable {
    let sceneId: String
    let density: Double
    let cohesion: Double
    let disruption: Double
    let tokenSalience: Double
    let wordmarkIntegrity: Double
    let decayMs: Int
    let flashBias: Double
    let anchorWeights: [Double]
    let thought: String
    let thoughtLog: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sceneId, density, cohesion, disruption, tokenSalience, wordmarkIntegrity, decayMs, flashBias, anchorWeights, thought, thoughtLog
    }

    init(
        sceneId: String,
        density: Double,
        cohesion: Double,
        disruption: Double,
        tokenSalience: Double,
        wordmarkIntegrity: Double,
        decayMs: Int,
        flashBias: Double,
        anchorWeights: [Double],
        thought: String = "idle",
        thoughtLog: [String] = []
    ) {
        self.sceneId = sceneId
        self.density = density
        self.cohesion = cohesion
        self.disruption = disruption
        self.tokenSalience = tokenSalience
        self.wordmarkIntegrity = wordmarkIntegrity
        self.decayMs = decayMs
        self.flashBias = flashBias
        self.anchorWeights = anchorWeights
        self.thought = thought
        self.thoughtLog = thoughtLog
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(VisualOut.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sceneId = try c.decode(String.self, forKey: .sceneId)
        self.density = try c.decode(Double.self, forKey: .density)
        self.cohesion = try c.decode(Double.self, forKey: .cohesion)
        self.disruption = try c.decode(Double.self, forKey: .disruption)
        self.tokenSalience = try c.decode(Double.self, forKey: .tokenSalience)
        self.wordmarkIntegrity = try c.decode(Double.self, forKey: .wordmarkIntegrity)
        self.decayMs = try c.decode(Int.self, forKey: .decayMs)
        self.flashBias = try c.decode(Double.self, forKey: .flashBias)
        self.anchorWeights = try c.decode([Double].self, forKey: .anchorWeights)
        self.thought = try c.decode(String.self, forKey: .thought)
        self.thoughtLog = try c.decodeIfPresent([String].self, forKey: .thoughtLog) ?? []
    }

    static func defaultForMode(_ mode: Int) -> VisualOut {
        let normalized = max(0, min(10, mode))
        switch normalized {
        case 0:
            return VisualOut(sceneId: "quiet_watch", density: 0.20, cohesion: 0.78, disruption: 0.16, tokenSalience: 0.26, wordmarkIntegrity: 0.88, decayMs: 1_700, flashBias: 0.18, anchorWeights: [0.56, 0.22, 0.22], thought: "idle")
        case 1:
            return VisualOut(sceneId: "relay_mesh", density: 0.58, cohesion: 0.62, disruption: 0.48, tokenSalience: 0.62, wordmarkIntegrity: 0.58, decayMs: 980, flashBias: 0.52, anchorWeights: [0.34, 0.32, 0.34], thought: "idle")
        case 2:
            return VisualOut(sceneId: "memory_drift", density: 0.62, cohesion: 0.46, disruption: 0.52, tokenSalience: 0.54, wordmarkIntegrity: 0.44, decayMs: 1_100, flashBias: 0.34, anchorWeights: [0.18, 0.52, 0.30], thought: "idle")
        case 3:
            return VisualOut(sceneId: "fault_lattice", density: 0.44, cohesion: 0.50, disruption: 0.68, tokenSalience: 0.48, wordmarkIntegrity: 0.50, decayMs: 920, flashBias: 0.44, anchorWeights: [0.24, 0.28, 0.48], thought: "idle")
        case 4:
            return VisualOut(sceneId: "fault_lattice", density: 0.70, cohesion: 0.34, disruption: 0.82, tokenSalience: 0.74, wordmarkIntegrity: 0.36, decayMs: 760, flashBias: 0.68, anchorWeights: [0.18, 0.24, 0.58], thought: "idle")
        case 5:
            return VisualOut(sceneId: "relay_mesh", density: 0.52, cohesion: 0.74, disruption: 0.28, tokenSalience: 0.56, wordmarkIntegrity: 0.72, decayMs: 1_250, flashBias: 0.24, anchorWeights: [0.42, 0.36, 0.22], thought: "idle")
        case 6:
            return VisualOut(sceneId: "grid_lock", density: 0.30, cohesion: 0.82, disruption: 0.18, tokenSalience: 0.38, wordmarkIntegrity: 0.84, decayMs: 1_450, flashBias: 0.14, anchorWeights: [0.16, 0.58, 0.26], thought: "idle")
        case 7:
            return VisualOut(sceneId: "memory_drift", density: 0.60, cohesion: 0.48, disruption: 0.40, tokenSalience: 0.62, wordmarkIntegrity: 0.60, decayMs: 1_020, flashBias: 0.30, anchorWeights: [0.33, 0.34, 0.33], thought: "idle")
        case 8:
            return VisualOut(sceneId: "quiet_watch", density: 0.24, cohesion: 0.84, disruption: 0.12, tokenSalience: 0.22, wordmarkIntegrity: 0.90, decayMs: 1_900, flashBias: 0.12, anchorWeights: [0.28, 0.24, 0.48], thought: "idle")
        case 9:
            return VisualOut(sceneId: "alarm_splay", density: 0.72, cohesion: 0.28, disruption: 0.70, tokenSalience: 0.80, wordmarkIntegrity: 0.42, decayMs: 780, flashBias: 0.74, anchorWeights: [0.46, 0.18, 0.36], thought: "idle")
        default:
            return VisualOut(sceneId: "alarm_splay", density: 0.78, cohesion: 0.22, disruption: 0.88, tokenSalience: 0.86, wordmarkIntegrity: 0.34, decayMs: 680, flashBias: 0.90, anchorWeights: [0.36, 0.28, 0.36], thought: "idle")
        }
    }
}

struct Picks: Codable, Equatable {
    let presetId: String?
    let bankId: String?
    let sampleId: String?
    let midiInstId: String?
    let chordSetId: String?
    let motifId: String?
    let articulationId: String?
    let spatialPatternId: String?
    let sceneId: String?
    let gridDiv: String?
    let repeatStyleId: String?
    let categoryId: String?
    let gestureTypeId: String?
    let mappingId: String?
    let varianceAmt: Double?
    let variantSeed: Int?
    let mappingFamily: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case presetId, bankId, sampleId, midiInstId, chordSetId, motifId, articulationId, spatialPatternId, sceneId
        case gridDiv, repeatStyleId, categoryId, gestureTypeId, mappingId, varianceAmt, variantSeed, mappingFamily
    }

    init(presetId: String? = nil, bankId: String? = nil, sampleId: String? = nil,
         midiInstId: String? = nil, chordSetId: String? = nil, motifId: String? = nil, articulationId: String? = nil,
         spatialPatternId: String? = nil, sceneId: String? = nil,
         gridDiv: String? = nil, repeatStyleId: String? = nil, categoryId: String? = nil,
         gestureTypeId: String? = nil, mappingId: String? = nil, varianceAmt: Double? = nil,
         variantSeed: Int? = nil, mappingFamily: String? = nil) {
        self.presetId = presetId
        self.bankId = bankId
        self.sampleId = sampleId
        self.midiInstId = midiInstId
        self.chordSetId = chordSetId
        self.motifId = motifId
        self.articulationId = articulationId
        self.spatialPatternId = spatialPatternId
        self.sceneId = sceneId
        self.gridDiv = gridDiv
        self.repeatStyleId = repeatStyleId
        self.categoryId = categoryId
        self.gestureTypeId = gestureTypeId
        self.mappingId = mappingId
        self.varianceAmt = varianceAmt
        self.variantSeed = variantSeed
        self.mappingFamily = mappingFamily
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(Picks.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.presetId = try c.decodeIfPresent(String.self, forKey: .presetId)
        self.bankId = try c.decodeIfPresent(String.self, forKey: .bankId)
        self.sampleId = try c.decodeIfPresent(String.self, forKey: .sampleId)
        self.midiInstId = try c.decodeIfPresent(String.self, forKey: .midiInstId)
        self.chordSetId = try c.decodeIfPresent(String.self, forKey: .chordSetId)
        self.motifId = try c.decodeIfPresent(String.self, forKey: .motifId)
        self.articulationId = try c.decodeIfPresent(String.self, forKey: .articulationId)
        self.spatialPatternId = try c.decodeIfPresent(String.self, forKey: .spatialPatternId)
        self.sceneId = try c.decodeIfPresent(String.self, forKey: .sceneId)
        self.gridDiv = try c.decodeIfPresent(String.self, forKey: .gridDiv)
        self.repeatStyleId = try c.decodeIfPresent(String.self, forKey: .repeatStyleId)
        self.categoryId = try c.decodeIfPresent(String.self, forKey: .categoryId)
        self.gestureTypeId = try c.decodeIfPresent(String.self, forKey: .gestureTypeId)
        self.mappingId = try c.decodeIfPresent(String.self, forKey: .mappingId)
        self.varianceAmt = try c.decodeIfPresent(Double.self, forKey: .varianceAmt)
        self.variantSeed = try c.decodeIfPresent(Int.self, forKey: .variantSeed)
        self.mappingFamily = try c.decodeIfPresent(String.self, forKey: .mappingFamily)
    }
}

struct ModelOut: Codable, Equatable {
    let protocolVersion: Int
    let tsMs: Int
    let mode: Int
    let params: [String: Double]
    let picks: Picks
    let flags: Flags
    let visual: VisualOut

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion, tsMs, mode, params, picks, flags, visual
    }

    init(
        protocolVersion: Int = ModeContract.supportedProtocolVersion,
        tsMs: Int,
        mode: Int,
        params: [String: Double],
        picks: Picks,
        flags: Flags,
        visual: VisualOut? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.tsMs = tsMs
        self.mode = mode
        self.params = params
        self.picks = picks
        self.flags = flags
        self.visual = visual ?? VisualOut.defaultForMode(mode)
    }

    init(from decoder: Decoder) throws {
        try assertNoUnknownKeys(ModelOut.self, decoder: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        guard self.protocolVersion == ModeContract.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: c,
                debugDescription: "Unsupported protocolVersion \(self.protocolVersion)"
            )
        }
        self.tsMs = try c.decode(Int.self, forKey: .tsMs)
        self.mode = try c.decode(Int.self, forKey: .mode)
        try requireMode0to10(self.mode, decoder: decoder)
        self.params = try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
        self.picks = try c.decodeIfPresent(Picks.self, forKey: .picks) ?? Picks()
        self.flags = try c.decodeIfPresent(Flags.self, forKey: .flags) ?? Flags()
        self.visual = try c.decode(VisualOut.self, forKey: .visual)
    }
}

struct ModelMonitorContext: Equatable {
    let rawPacket: ModelOut?
    let resolvedPacket: ModelOut
    let latencyMs: Int
    let contractViolations: [String]
    let pickNotes: [String]
    let receivedAt: Date
}

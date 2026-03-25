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

    init(protocolVersion: Int = 1, tsMs: Int, sessionId: String, frameHz: Int = 10, mode: Int,
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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion, tsMs, mode, params, picks, flags
    }

    init(
        protocolVersion: Int = ModeContract.supportedProtocolVersion,
        tsMs: Int,
        mode: Int,
        params: [String: Double],
        picks: Picks,
        flags: Flags
    ) {
        self.protocolVersion = protocolVersion
        self.tsMs = tsMs
        self.mode = mode
        self.params = params
        self.picks = picks
        self.flags = flags
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
    }
}

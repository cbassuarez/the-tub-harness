import Foundation

enum BankType: String, Codable {
    case samples
    case midiPhrases = "midi_phrases"
    case particles
}

struct BankAsset: Codable, Equatable {
    let id: String
    let path: String
    let gain: Double?
    let category: String?
}

struct BankManifestEntry: Codable, Equatable {
    let type: BankType
    let defaultSampleId: String?
    let defaultPhraseId: String?
    let defaultProfileId: String?
    let assets: [BankAsset]
}

enum InstrumentType: String, Codable {
    case sampler
    case particleSynth = "particle_synth"
}

struct InstrumentManifestEntry: Codable, Equatable {
    let type: InstrumentType
    let preset: String?
    let polyphony: Int?
    let samplePackPath: String?
    let soundfontPath: String?
    let samplerPresetRef: String?
    let gainDb: Double?
    let polyphonyHint: Int?
    let velocityLayers: Int?
    let roundRobinCount: Int?
}

struct ChordSetManifestEntry: Codable, Equatable {
    let key: String?
    let intervals: [Int]
}

struct MotifManifestEntry: Codable, Equatable {
    let notes: [Int]
    let durationsMs: [Int]
    let velocityScale: Double?
}

enum SpatialPatternAlgo: String, Codable {
    case drift
    case orbit
    case `static`
    case fragment
    case orbitPulse = "orbit_pulse"
    case jumpCut = "jump_cut"
    case clusterRotate = "cluster_rotate"
}

struct SpatialPatternManifestEntry: Codable, Equatable {
    let algo: SpatialPatternAlgo
    let speed: Double?
    let spread: Double?
    let jumpProb: Double?
    let jitter: Double?
}

struct ResolvedManifestRouting {
    let bankId: String?
    let bank: BankManifestEntry?
    let bankAsset: BankAsset?
    let instrumentId: String?
    let instrument: InstrumentManifestEntry?
    let spatialPatternId: String?
    let spatialPattern: SpatialPatternManifestEntry?
}

struct PicksResolution {
    let picks: Picks
    let routing: ResolvedManifestRouting
    let notes: [String]
}

final class ManifestCatalog {
    static let shared: ManifestCatalog = .loadDefault()

    let banks: [String: BankManifestEntry]
    let instruments: [String: InstrumentManifestEntry]
    let chords: [String: ChordSetManifestEntry]
    let motifs: [String: MotifManifestEntry]
    let spatialPatterns: [String: SpatialPatternManifestEntry]
    let sourceDirectory: URL?
    let validationWarnings: [String]

    private init(
        banks: [String: BankManifestEntry],
        instruments: [String: InstrumentManifestEntry],
        chords: [String: ChordSetManifestEntry],
        motifs: [String: MotifManifestEntry],
        spatialPatterns: [String: SpatialPatternManifestEntry],
        sourceDirectory: URL?,
        validationWarnings: [String]
    ) {
        self.banks = banks
        self.instruments = instruments
        self.chords = chords
        self.motifs = motifs
        self.spatialPatterns = spatialPatterns
        self.sourceDirectory = sourceDirectory
        self.validationWarnings = validationWarnings
    }

    func logValidationSummary(context: String = "manifest") {
        if let sourceDirectory {
            print("[\(context)] loaded manifests from \(sourceDirectory.path)")
        } else {
            print("[\(context)] manifests not found; using runtime defaults")
        }
        for warning in validationWarnings {
            print("[\(context)] warning: \(warning)")
        }
    }

    func resolve(mode: Int, picks: Picks) -> PicksResolution {
        let modeClamped = max(0, min(10, mode))
        let required = ModeContract.requiredPicks(for: modeClamped)
        let defaults = ModeContract.defaultPicksByMode[modeClamped]
            ?? Picks(
                presetId: "fallback_\(modeClamped)",
                bankId: nil,
                sampleId: nil,
                midiInstId: nil,
                spatialPatternId: "drift_slow",
                sceneId: nil
            )

        var notes: [String] = []

        var presetId = picks.presetId
        if required.contains("preset_id") {
            if isBlank(presetId) {
                let fallback = defaults.presetId ?? "fallback_\(modeClamped)"
                notes.append("preset_id fallback to \(fallback)")
                presetId = fallback
            }
        }

        var spatialPatternId = picks.spatialPatternId
        if isBlank(spatialPatternId) || spatialPatterns[spatialPatternId ?? ""] == nil {
            let fallback = defaults.spatialPatternId ?? "drift_slow"
            if spatialPatternId != fallback {
                notes.append("spatial_pattern_id fallback to \(fallback)")
            }
            spatialPatternId = fallback
        }
        let spatial = spatialPatternId.flatMap { spatialPatterns[$0] }

        var bankId = picks.bankId
        var bank = bankId.flatMap { banks[$0] }
        if required.contains("bank_id") {
            if isBlank(bankId) || bank == nil {
                let fallback = defaults.bankId
                    ?? banks.keys.sorted().first
                    ?? "missing_bank_m\(modeClamped)"
                if bankId != fallback {
                    notes.append("bank_id fallback to \(fallback)")
                }
                bankId = fallback
                bank = banks[fallback]
            }
        } else if let raw = bankId, bank == nil {
            notes.append("bank_id \(raw) unknown, ignoring")
            bankId = nil
            bank = nil
        }

        var sampleId = picks.sampleId
        var resolvedBankAsset: BankAsset?
        let shouldResolveSample = required.contains("sample_id") || (bank?.type == .samples && required.contains("bank_id"))
        if shouldResolveSample {
            let requested = sampleId ?? ""
            let validRequested = bank?.assets.first(where: { $0.id == requested })
            if let validRequested {
                resolvedBankAsset = validRequested
            } else {
                let fallbackId = bank?.defaultSampleId
                    ?? bank?.assets.first?.id
                    ?? defaults.sampleId
                    ?? "missing_sample_m\(modeClamped)"
                if sampleId != fallbackId {
                    notes.append("sample_id fallback to \(fallbackId)")
                }
                sampleId = fallbackId
                resolvedBankAsset = bank?.assets.first(where: { $0.id == fallbackId })
            }
        }

        var midiInstId = picks.midiInstId
        var instrument = midiInstId.flatMap { instruments[$0] }
        if required.contains("midi_inst_id") {
            if isBlank(midiInstId) || instrument == nil {
                let fallback = defaults.midiInstId
                    ?? instruments.keys.sorted().first
                    ?? "missing_inst_m\(modeClamped)"
                if midiInstId != fallback {
                    notes.append("midi_inst_id fallback to \(fallback)")
                }
                midiInstId = fallback
                instrument = instruments[fallback]
            }
        }

        var chordSetId = picks.chordSetId
        if required.contains("chord_set_id") {
            if isBlank(chordSetId) || chords[chordSetId ?? ""] == nil {
                let fallback = defaults.chordSetId
                    ?? chords.keys.sorted().first
                    ?? "cs_neutral"
                if chordSetId != fallback {
                    notes.append("chord_set_id fallback to \(fallback)")
                }
                chordSetId = fallback
            }
        }
        let motifId = picks.motifId ?? defaults.motifId
        let articulationId = picks.articulationId ?? defaults.articulationId

        var sceneId = picks.sceneId
        if required.contains("scene_id"), isBlank(sceneId) {
            let fallback = defaults.sceneId ?? "scene_\(modeClamped)"
            if sceneId != fallback {
                notes.append("scene_id fallback to \(fallback)")
            }
            sceneId = fallback
        }

        var gridDiv = picks.gridDiv
        if required.contains("grid_div") {
            let allowed = ["1/8", "1/16"]
            if isBlank(gridDiv) || !allowed.contains(gridDiv ?? "") {
                let fallback = defaults.gridDiv ?? "1/8"
                if gridDiv != fallback {
                    notes.append("grid_div fallback to \(fallback)")
                }
                gridDiv = fallback
            }
        }

        var repeatStyleId = picks.repeatStyleId
        if required.contains("repeat_style_id"), isBlank(repeatStyleId) {
            let fallback = defaults.repeatStyleId ?? "stutter_a"
            if repeatStyleId != fallback {
                notes.append("repeat_style_id fallback to \(fallback)")
            }
            repeatStyleId = fallback
        }

        var gestureTypeId = picks.gestureTypeId
        if required.contains("gesture_type_id"), isBlank(gestureTypeId) {
            let fallback = defaults.gestureTypeId ?? "call_response"
            if gestureTypeId != fallback {
                notes.append("gesture_type_id fallback to \(fallback)")
            }
            gestureTypeId = fallback
        }

        let categoryId = picks.categoryId ?? defaults.categoryId

        var mappingId = picks.mappingId
        if required.contains("mapping_id"), isBlank(mappingId) {
            let fallback = defaults.mappingId ?? "swap_pairs"
            if mappingId != fallback {
                notes.append("mapping_id fallback to \(fallback)")
            }
            mappingId = fallback
        }
        let varianceAmt = picks.varianceAmt ?? defaults.varianceAmt
        let variantSeed = picks.variantSeed ?? defaults.variantSeed
        let mappingFamily = picks.mappingFamily ?? defaults.mappingFamily

        let resolvedPicks = Picks(
            presetId: presetId,
            bankId: bankId,
            sampleId: sampleId,
            midiInstId: midiInstId,
            chordSetId: chordSetId,
            motifId: motifId,
            articulationId: articulationId,
            spatialPatternId: spatialPatternId,
            sceneId: sceneId,
            gridDiv: gridDiv,
            repeatStyleId: repeatStyleId,
            categoryId: categoryId,
            gestureTypeId: gestureTypeId,
            mappingId: mappingId,
            varianceAmt: varianceAmt,
            variantSeed: variantSeed,
            mappingFamily: mappingFamily
        )

        return PicksResolution(
            picks: resolvedPicks,
            routing: ResolvedManifestRouting(
                bankId: bankId,
                bank: bank,
                bankAsset: resolvedBankAsset,
                instrumentId: midiInstId,
                instrument: instrument,
                spatialPatternId: spatialPatternId,
                spatialPattern: spatial
            ),
            notes: notes
        )
    }

    private static func loadDefault() -> ManifestCatalog {
        var warnings: [String] = []
        let dir = resolveManifestDirectory()
        if dir == nil {
            warnings.append("manifest directory not found")
        }

        let banks: [String: BankManifestEntry] = loadJSON(
            [String: BankManifestEntry].self,
            fileName: "banks.json",
            in: dir,
            warnings: &warnings
        ) ?? defaultBanks()
        let instruments: [String: InstrumentManifestEntry] = loadJSON(
            [String: InstrumentManifestEntry].self,
            fileName: "instruments.json",
            in: dir,
            warnings: &warnings
        ) ?? defaultInstruments()
        let chords: [String: ChordSetManifestEntry] = loadJSON(
            [String: ChordSetManifestEntry].self,
            fileName: "chords.json",
            in: dir,
            warnings: &warnings
        ) ?? defaultChordSets()
        let motifs: [String: MotifManifestEntry] = loadJSON(
            [String: MotifManifestEntry].self,
            fileName: "motifs.json",
            in: dir,
            warnings: &warnings
        ) ?? defaultMotifs()
        let spatialPatterns: [String: SpatialPatternManifestEntry] = loadJSON(
            [String: SpatialPatternManifestEntry].self,
            fileName: "spatial_patterns.json",
            in: dir,
            warnings: &warnings
        ) ?? defaultSpatialPatterns()

        warnings.append(contentsOf: validateModeDefaults(
            banks: banks,
            instruments: instruments,
            chords: chords,
            motifs: motifs,
            spatialPatterns: spatialPatterns
        ))

        return ManifestCatalog(
            banks: banks,
            instruments: instruments,
            chords: chords,
            motifs: motifs,
            spatialPatterns: spatialPatterns,
            sourceDirectory: dir,
            validationWarnings: warnings
        )
    }

    private static func resolveManifestDirectory() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let envDir = env["TUB_MANIFESTS_DIR"], !envDir.isEmpty {
            let url = URL(fileURLWithPath: envDir, isDirectory: true)
            if hasReadableManifestFiles(in: url, fileManager: fm) {
                return url
            }
        }

        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.resourceURL?.appendingPathComponent("Manifests", isDirectory: true),
            Bundle(for: BundleMarker.self).resourceURL,
            Bundle(for: BundleMarker.self).resourceURL?.appendingPathComponent("Manifests", isDirectory: true),
            sourceDir.appendingPathComponent("Manifests", isDirectory: true),
            sourceDir,
        ]

        for c in candidates {
            guard let c else { continue }
            if hasReadableManifestFiles(in: c, fileManager: fm) {
                return c
            }
        }
        return nil
    }

    private static func hasReadableManifestFiles(in dir: URL, fileManager fm: FileManager) -> Bool {
        for name in ["banks.json", "instruments.json", "spatial_patterns.json"] {
            let url = dir.appendingPathComponent(name)
            guard fm.isReadableFile(atPath: url.path) else {
                return false
            }
            do {
                _ = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                return false
            }
        }
        return true
    }

    private static func loadJSON<T: Decodable>(
        _ type: T.Type,
        fileName: String,
        in dir: URL?,
        warnings: inout [String]
    ) -> T? {
        guard let dir else {
            warnings.append("missing \(fileName) because manifest directory is unavailable")
            return nil
        }
        let url = dir.appendingPathComponent(fileName)
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            return try dec.decode(type, from: data)
        } catch {
            warnings.append("failed to parse \(fileName): \(error)")
            return nil
        }
    }

    private static func validateModeDefaults(
        banks: [String: BankManifestEntry],
        instruments: [String: InstrumentManifestEntry],
        chords: [String: ChordSetManifestEntry],
        motifs _: [String: MotifManifestEntry],
        spatialPatterns: [String: SpatialPatternManifestEntry]
    ) -> [String] {
        var warnings: [String] = []
        for mode in 0...10 {
            guard let defaults = ModeContract.defaultPicksByMode[mode] else { continue }

            if let spatial = defaults.spatialPatternId, spatialPatterns[spatial] == nil {
                warnings.append("mode \(mode) default spatial_pattern_id \(spatial) missing from spatial_patterns.json")
            }

            let required = ModeContract.requiredPicks(for: mode)
            if required.contains("bank_id") {
                guard let bankId = defaults.bankId else {
                    warnings.append("mode \(mode) requires bank_id but default is missing")
                    continue
                }
                guard let bank = banks[bankId] else {
                    warnings.append("mode \(mode) default bank_id \(bankId) missing from banks.json")
                    continue
                }
                if required.contains("sample_id") {
                    let sampleId = defaults.sampleId ?? bank.defaultSampleId
                    if sampleId == nil || bank.assets.contains(where: { $0.id == sampleId }) == false {
                        warnings.append("mode \(mode) default sample_id not resolvable in bank \(bankId)")
                    }
                }
            }

            if required.contains("midi_inst_id") {
                guard let midiInstId = defaults.midiInstId else {
                    warnings.append("mode \(mode) requires midi_inst_id but default is missing")
                    continue
                }
                if instruments[midiInstId] == nil {
                    warnings.append("mode \(mode) default midi_inst_id \(midiInstId) missing from instruments.json")
                }
            }
            if required.contains("chord_set_id") {
                guard let chordSetId = defaults.chordSetId else {
                    warnings.append("mode \(mode) requires chord_set_id but default is missing")
                    continue
                }
                if chords[chordSetId] == nil {
                    warnings.append("mode \(mode) default chord_set_id \(chordSetId) missing from chords.json")
                }
            }
        }
        return warnings
    }

    private static func defaultChordSets() -> [String: ChordSetManifestEntry] {
        [
            "cs_neutral": ChordSetManifestEntry(key: "unknown", intervals: [0, 3, 7, 10]),
            "cs_open5": ChordSetManifestEntry(key: "unknown", intervals: [0, 7, 12]),
            "cs_modal": ChordSetManifestEntry(key: "unknown", intervals: [0, 2, 5, 7, 10]),
        ]
    }

    private static func defaultMotifs() -> [String: MotifManifestEntry] {
        [
            "motif_run_up": MotifManifestEntry(notes: [0, 2, 4, 7], durationsMs: [120, 120, 140, 200], velocityScale: 1.0),
            "motif_pulse_low": MotifManifestEntry(notes: [0, -5, 0], durationsMs: [220, 180, 260], velocityScale: 0.85),
        ]
    }

    private static func defaultBanks() -> [String: BankManifestEntry] {
        [
            "samples_A": BankManifestEntry(
                type: .samples,
                defaultSampleId: "s000",
                defaultPhraseId: nil,
                defaultProfileId: nil,
                assets: [
                    BankAsset(id: "s000", path: "Assets/Samples/ultrachunk/s000.wav", gain: 0.95, category: "general"),
                    BankAsset(id: "s001", path: "Assets/Samples/ultrachunk/s001.wav", gain: 0.95, category: "metal"),
                ]
            ),
            "phrases_A": BankManifestEntry(
                type: .midiPhrases,
                defaultSampleId: nil,
                defaultPhraseId: "p000",
                defaultProfileId: nil,
                assets: [
                    BankAsset(id: "p000", path: "Assets/MIDI/phrases/p000.mid", gain: nil, category: nil),
                ]
            ),
        ]
    }

    private static func defaultInstruments() -> [String: InstrumentManifestEntry] {
        [
            "inst_A": InstrumentManifestEntry(
                type: .sampler,
                preset: nil,
                polyphony: 8,
                samplePackPath: "Assets/Sampler/inst_A",
                soundfontPath: nil,
                samplerPresetRef: "SamplerPresets/inst_A.exs",
                gainDb: -1.0,
                polyphonyHint: 8,
                velocityLayers: 3,
                roundRobinCount: 2
            ),
            "inst_B": InstrumentManifestEntry(
                type: .sampler,
                preset: nil,
                polyphony: 8,
                samplePackPath: "Assets/Sampler/inst_B",
                soundfontPath: nil,
                samplerPresetRef: "SamplerPresets/inst_B.exs",
                gainDb: -2.5,
                polyphonyHint: 8,
                velocityLayers: 2,
                roundRobinCount: 1
            ),
        ]
    }

    private static func defaultSpatialPatterns() -> [String: SpatialPatternManifestEntry] {
        [
            "drift_slow": SpatialPatternManifestEntry(algo: .drift, speed: 0.20, spread: 0.65, jumpProb: nil, jitter: nil),
            "orbit_slow": SpatialPatternManifestEntry(algo: .orbit, speed: 0.25, spread: 0.55, jumpProb: nil, jitter: nil),
            "orbit_mid": SpatialPatternManifestEntry(algo: .orbit, speed: 0.45, spread: 0.55, jumpProb: nil, jitter: nil),
            "tight_static": SpatialPatternManifestEntry(algo: .static, speed: nil, spread: 0.25, jumpProb: nil, jitter: nil),
            "fragment_soft": SpatialPatternManifestEntry(algo: .fragment, speed: 0.35, spread: 0.45, jumpProb: 0.25, jitter: nil),
            "orbit_var": SpatialPatternManifestEntry(algo: .orbit, speed: 0.55, spread: 0.60, jumpProb: nil, jitter: 0.20),
            "orbit_pulse": SpatialPatternManifestEntry(algo: .orbitPulse, speed: 0.52, spread: 0.42, jumpProb: nil, jitter: 0.12),
            "jump_cut": SpatialPatternManifestEntry(algo: .jumpCut, speed: 0.70, spread: 0.38, jumpProb: 0.55, jitter: nil),
            "cluster_rotate": SpatialPatternManifestEntry(algo: .clusterRotate, speed: 0.30, spread: 0.62, jumpProb: nil, jitter: 0.08),
        ]
    }

    private func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class BundleMarker {}

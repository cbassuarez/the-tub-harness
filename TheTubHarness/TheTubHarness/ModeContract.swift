import Foundation

enum ModeContract {
    static let supportedProtocolVersion = 1
    static let contractVersion = "control_surface_v1"

    typealias Bounds = (Double, Double)
    typealias Transform = (Double) -> Double

    // Control Surface v1 per-mode canonical params.
    static let modeSpecificParams: [Int: Set<String>] = [
        0: ["dry_level", "reverb_mix", "reverb_decay_s", "pre_delay_ms", "tone_db"],
        1: ["loop_len_s", "repeat_prob", "stutter_len_ms", "jitter_ms", "feedback", "motion_speed", "spread"],
        2: ["grain_size_ms", "grain_density", "scan_rate", "freeze_prob", "freeze_len_s", "pitch_spread_cents"],
        3: ["drive", "bit_depth_bits", "downsample_amt", "res_shift", "tone_db"],
        4: ["density", "gesture_rate_hz", "sample_mix", "dry_level", "stability"],
        5: ["note_rate_notes_per_s", "voice_cap", "pitch_follow", "velocity_bias", "level", "stability"],
        6: ["note_rate_notes_per_s", "voice_cap", "pitch_follow", "velocity_bias", "level", "stability", "dry_level"],
        7: ["swap_rate_hz", "crossfade_ms", "bucket_sharpness", "mapping_entropy", "mix"],
        8: ["reverb_rand_amt", "reverb_decay_base_s", "reverb_decay_range_s", "reverb_color", "twitchiness", "motion_speed", "spread"],
        9: ["particle_density", "particle_voice_cap", "particle_decay_s", "particle_brightness", "motion_speed", "spread"],
        10: ["scene_len_s", "chaos", "blend", "stability"],
    ]

    static let legacyParamAliases: [Int: [String: String]] = [
        0: [
            "reverb_wet": "reverb_mix",
            "reverb_size": "reverb_mix",
            "wet": "reverb_mix",
            "reverb_decay": "reverb_decay_s",
            "pre_delay": "pre_delay_ms",
            "brightness": "tone_db",
        ],
        1: [
            "window_norm": "loop_len_s",
            "repeat_grid": "loop_len_s",
            "stutter_len_norm": "stutter_len_ms",
            "stutter_len": "stutter_len_ms",
            "gate_sharpness": "jitter_ms",
            "threshold_bias": "feedback",
            "motion_intensity": "motion_speed",
        ],
        2: [
            "grain_size": "grain_size_ms",
            "scan_jump_prob": "scan_rate",
            "spread": "pitch_spread_cents",
            "density": "grain_density",
        ],
        3: [
            "bit_depth": "bit_depth_bits",
            "downsample": "downsample_amt",
            "resonance": "res_shift",
            "brightness": "tone_db",
        ],
        4: [
            "gesture_rate": "gesture_rate_hz",
            "gesture_level": "sample_mix",
            "sample_level": "sample_mix",
            "interruptiveness": "density",
            "memory_weight": "stability",
            "wet": "sample_mix",
        ],
        5: [
            "note_rate": "note_rate_notes_per_s",
        ],
        6: [
            "note_rate": "note_rate_notes_per_s",
        ],
        7: [
            "swap_rate": "swap_rate_hz",
            "morph_rate": "swap_rate_hz",
            "crossfade": "crossfade_ms",
            "sharpness": "bucket_sharpness",
            "bias": "mapping_entropy",
            "wet": "mix",
        ],
        8: [
            "reverb_wet": "reverb_rand_amt",
            "reverb_decay": "reverb_decay_base_s",
            "damping": "reverb_color",
            "wet": "reverb_rand_amt",
        ],
        9: [
            "band_motion_speed": "motion_speed",
            "reverb_decay": "particle_decay_s",
            "band_high_level": "particle_brightness",
            "band_high": "particle_brightness",
            "band_low_level": "particle_density",
            "band_low": "particle_density",
            "density": "particle_density",
        ],
        10: [
            "scene_len": "scene_len_s",
        ],
    ]

    static let requiredPicksByMode: [Int: Set<String>] = {
        var out: [Int: Set<String>] = [:]
        for mode in 0...10 {
            out[mode] = ["preset_id", "spatial_pattern_id"]
        }
        out[1, default: []].formUnion(["grid_div", "repeat_style_id"])
        out[4, default: []].formUnion(["bank_id", "sample_id"])
        out[5, default: []].formUnion(["midi_inst_id", "chord_set_id"])
        out[6, default: []].formUnion(["midi_inst_id", "chord_set_id"])
        out[9, default: []].formUnion(["bank_id", "midi_inst_id"])
        out[10, default: []].formUnion(["scene_id"])
        return out
    }()

    static let defaultPicksByMode: [Int: Picks] = [
        0: Picks(presetId: "room_clean", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "drift_slow", sceneId: nil),
        1: Picks(presetId: "beat_A", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "orbit_pulse", sceneId: nil, gridDiv: "1/8", repeatStyleId: "stutter_a"),
        2: Picks(presetId: "fracture", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "fragment_soft", sceneId: nil),
        3: Picks(presetId: "res_default", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "orbit_slow", sceneId: nil),
        4: Picks(presetId: "ultrachunk_A", bankId: "samples_A", sampleId: "s000", midiInstId: nil, spatialPatternId: "cluster_rotate", sceneId: nil, categoryId: "general", gestureTypeId: "call_response"),
        5: Picks(presetId: "midiwet_A", bankId: "phrases_A", sampleId: nil, midiInstId: "inst_A", chordSetId: "cs_neutral", motifId: nil, articulationId: "legato", spatialPatternId: "orbit_mid", sceneId: nil),
        6: Picks(presetId: "mididry_A", bankId: "phrases_A", sampleId: nil, midiInstId: "inst_A", chordSetId: "cs_neutral", motifId: nil, articulationId: "short", spatialPatternId: "orbit_mid", sceneId: nil),
        7: Picks(presetId: "buckets_A", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "cluster_rotate", sceneId: nil, mappingId: "swap_pairs", variantSeed: 7, mappingFamily: "bucket_swap"),
        8: Picks(presetId: "space", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "orbit_slow", sceneId: nil),
        9: Picks(presetId: "field_diffuse", bankId: "particles_A", sampleId: nil, midiInstId: "inst_P", spatialPatternId: "orbit_mid", sceneId: nil),
        10: Picks(presetId: "special_01", bankId: nil, sampleId: nil, midiInstId: nil, spatialPatternId: "orbit_var", sceneId: "special_01"),
    ]

    static let safeModeParams: [Int: [String: Double]] = [
        0: ["dry_level": 0.92, "reverb_mix": 0.12, "reverb_decay_s": 0.9, "pre_delay_ms": 12.0, "tone_db": 0.0],
        1: ["loop_len_s": 0.72, "repeat_prob": 0.62, "stutter_len_ms": 78.0, "jitter_ms": 22.0, "feedback": 0.15, "motion_speed": 0.30, "spread": 0.50],
        2: ["grain_size_ms": 28.0, "grain_density": 0.62, "scan_rate": 0.58, "freeze_prob": 0.08, "freeze_len_s": 0.9, "pitch_spread_cents": 24.0],
        3: ["drive": 0.22, "bit_depth_bits": 18.0, "downsample_amt": 0.08, "res_shift": 0.45, "tone_db": -1.0],
        4: ["density": 0.38, "gesture_rate_hz": 1.2, "sample_mix": 0.30, "dry_level": 0.72, "stability": 0.7],
        5: ["note_rate_notes_per_s": 4.0, "voice_cap": 4.0, "pitch_follow": 0.82, "velocity_bias": 0.55, "level": 0.62, "stability": 0.72],
        6: ["note_rate_notes_per_s": 2.4, "voice_cap": 2.0, "pitch_follow": 0.8, "velocity_bias": 0.52, "level": 0.58, "stability": 0.72, "dry_level": 0.68],
        7: ["swap_rate_hz": 2.6, "crossfade_ms": 70.0, "bucket_sharpness": 0.74, "mapping_entropy": 0.72, "mix": 0.94],
        8: ["reverb_rand_amt": 0.28, "reverb_decay_base_s": 1.0, "reverb_decay_range_s": 0.6, "reverb_color": 0.42, "twitchiness": 0.32, "motion_speed": 0.38, "spread": 0.58],
        9: ["particle_density": 0.42, "particle_voice_cap": 8.0, "particle_decay_s": 0.55, "particle_brightness": 0.45, "motion_speed": 0.35, "spread": 0.65],
        10: ["scene_len_s": 24.0, "chaos": 0.55, "blend": 0.58, "stability": 0.62],
    ]

    static let modeBounds: [Int: [String: Bounds]] = {
        var out: [Int: [String: Bounds]] = [:]
        for mode in 0...10 {
            var bounds: [String: Bounds] = [:]
            for key in modeSpecificParams[mode] ?? [] {
                bounds[key] = (0.0, 1.0)
            }
            out[mode] = bounds
        }

        out[0]?["reverb_decay_s"] = (0.2, 2.8)
        out[0]?["pre_delay_ms"] = (0.0, 60.0)
        out[0]?["tone_db"] = (-6.0, 6.0)

        out[1]?["loop_len_s"] = (0.08, 4.0)
        out[1]?["repeat_prob"] = (0.0, 0.9)
        out[1]?["stutter_len_ms"] = (30.0, 450.0)
        out[1]?["jitter_ms"] = (0.0, 120.0)
        out[1]?["feedback"] = (0.0, 0.65)

        out[2]?["grain_size_ms"] = (12.0, 120.0)
        out[2]?["grain_density"] = (0.1, 0.9)
        out[2]?["freeze_prob"] = (0.0, 0.75)
        out[2]?["freeze_len_s"] = (0.2, 6.0)
        out[2]?["pitch_spread_cents"] = (0.0, 35.0)

        out[3]?["drive"] = (0.0, 0.85)
        out[3]?["bit_depth_bits"] = (8.0, 24.0)
        out[3]?["tone_db"] = (-9.0, 6.0)

        out[4]?["gesture_rate_hz"] = (0.1, 6.0)

        out[5]?["note_rate_notes_per_s"] = (0.0, 12.0)
        out[5]?["voice_cap"] = (2.0, 8.0)
        out[5]?["pitch_follow"] = (0.65, 1.0)

        out[6]?["note_rate_notes_per_s"] = (0.0, 6.0)
        out[6]?["voice_cap"] = (1.0, 3.0)
        out[6]?["pitch_follow"] = (0.65, 1.0)
        out[6]?["dry_level"] = (0.35, 0.95)

        out[7]?["swap_rate_hz"] = (0.1, 6.0)
        out[7]?["crossfade_ms"] = (20.0, 600.0)

        out[8]?["reverb_decay_base_s"] = (0.2, 3.5)
        out[8]?["reverb_decay_range_s"] = (0.0, 2.0)

        out[9]?["particle_voice_cap"] = (1.0, 24.0)
        out[9]?["particle_decay_s"] = (0.05, 2.5)

        out[10]?["scene_len_s"] = (8.0, 90.0)
        return out
    }()

    static let legacyTransforms: [Int: [String: Transform]] = [
        0: [
            "reverb_decay": linear(min: 0.2, max: 2.8),
            "pre_delay": linear(min: 0.0, max: 60.0),
            "brightness": linear(min: -6.0, max: 6.0),
        ],
        1: [
            "window_norm": linear(min: 0.08, max: 4.0),
            "repeat_grid": linear(min: 0.08, max: 4.0),
            "stutter_len_norm": linear(min: 30.0, max: 450.0),
            "stutter_len": linear(min: 30.0, max: 450.0),
            "gate_sharpness": linear(min: 0.0, max: 120.0),
            "threshold_bias": linear(min: 0.0, max: 0.65),
        ],
        2: [
            "grain_size": linear(min: 12.0, max: 120.0),
            "spread": linear(min: 0.0, max: 35.0),
        ],
        3: [
            "bit_depth": linear(min: 8.0, max: 24.0),
            "brightness": linear(min: -9.0, max: 6.0),
        ],
        4: [
            "gesture_rate": linear(min: 0.1, max: 6.0),
        ],
        5: [
            "note_rate": linear(min: 0.0, max: 12.0),
            "voice_cap": linear(min: 2.0, max: 8.0),
            "pitch_follow": linear(min: 0.65, max: 1.0),
        ],
        6: [
            "note_rate": linear(min: 0.0, max: 6.0),
            "voice_cap": linear(min: 1.0, max: 3.0),
            "pitch_follow": linear(min: 0.65, max: 1.0),
        ],
        7: [
            "swap_rate": linear(min: 0.1, max: 6.0),
            "morph_rate": linear(min: 0.1, max: 6.0),
            "crossfade": linear(min: 20.0, max: 600.0),
        ],
        8: [
            "reverb_decay": linear(min: 0.2, max: 3.5),
        ],
        9: [
            "reverb_decay": linear(min: 0.05, max: 2.5),
        ],
        10: [
            "scene_len": linear(min: 8.0, max: 90.0),
        ],
    ]

    static func allowedParams(for mode: Int) -> Set<String> {
        let m = clampMode(mode)
        return canonicalAllowedParams(for: m).union(Set(legacyParamAliases[m, default: [:]].keys))
    }

    static func canonicalAllowedParams(for mode: Int) -> Set<String> {
        modeSpecificParams[clampMode(mode)] ?? []
    }

    static func requiredPicks(for mode: Int) -> Set<String> {
        requiredPicksByMode[clampMode(mode)] ?? ["preset_id", "spatial_pattern_id"]
    }

    static func bounds(for mode: Int, param: String) -> Bounds? {
        let m = clampMode(mode)
        let canonical = canonicalParamKey(mode: m, key: param)
        return modeBounds[m]?[canonical]
    }

    static func canonicalParamKey(mode: Int, key: String) -> String {
        legacyParamAliases[clampMode(mode), default: [:]][key] ?? key
    }

    static func clamp(params: [String: Double], mode: Int) -> (clamped: [String: Double], violations: [String]) {
        let m = clampMode(mode)
        let allowed = canonicalAllowedParams(for: m)
        let aliases = legacyParamAliases[m, default: [:]]
        let transforms = legacyTransforms[m, default: [:]]

        var out: [String: Double] = [:]
        var violations: [String] = []
        var clampedKeys = Set<String>()
        var densityCapped = false
        var voiceCapped = false

        for (key, raw) in params {
            let canonical = allowed.contains(key) ? key : aliases[key]
            guard let canonical else {
                violations.append("param_not_allowed:\(key)")
                continue
            }

            guard raw.isFinite else {
                violations.append("param_not_finite:\(key)")
                continue
            }

            var value = raw
            if let transform = transforms[key], key != canonical {
                value = transform(clamp01(raw))
            }
            out[canonical] = value
        }

        // Derived compatibility fallbacks.
        if m == 0, out["tone_db"] == nil {
            out["tone_db"] = -6.0 + 12.0 * clamp01(params["brightness"] ?? 0.5)
        }
        if m == 2, out["freeze_len_s"] == nil {
            let freezeHint = out["freeze_prob"] ?? params["freeze_prob"] ?? 0.3
            out["freeze_len_s"] = 0.2 + 5.8 * clamp01(freezeHint)
        }
        if m == 3, out["tone_db"] == nil {
            out["tone_db"] = -9.0 + 15.0 * clamp01(params["brightness"] ?? 0.5)
        }
        if m == 4, out["sample_mix"] == nil {
            out["sample_mix"] = clamp01(params["gesture_level"] ?? params["wet"] ?? 0.3)
        }
        if m == 8, out["reverb_decay_range_s"] == nil {
            out["reverb_decay_range_s"] = 2.0 * clamp01(out["reverb_rand_amt"] ?? params["reverb_wet"] ?? 0.2)
        }
        if m == 8, out["twitchiness"] == nil {
            out["twitchiness"] = clamp01(params["motion_speed"] ?? 0.4)
        }
        if m == 9, out["particle_density"] == nil {
            let low = params["band_low_level"] ?? params["band_low"] ?? 0.3
            let mid = params["band_mid_level"] ?? params["band_mid"] ?? 0.3
            let high = params["band_high_level"] ?? params["band_high"] ?? 0.3
            out["particle_density"] = clamp01((low + mid + high) / 3.0)
        }
        if m == 9, out["particle_brightness"] == nil {
            out["particle_brightness"] = clamp01(params["band_high_level"] ?? params["band_high"] ?? 0.5)
        }
        if m == 9, out["particle_voice_cap"] == nil {
            out["particle_voice_cap"] = 1.0 + 23.0 * clamp01(params["level"] ?? 0.5)
        }

        for key in allowed {
            if out[key] == nil {
                out[key] = defaultForKey(mode: m, key: key)
            }
        }

        var clamped: [String: Double] = [:]
        for key in allowed {
            guard let value = out[key], let bounds = modeBounds[m]?[key] else { continue }
            let clampedValue = max(bounds.0, min(bounds.1, value))
            if clampedValue != value {
                if value < bounds.0 {
                    violations.append("param_clamped_low:\(key):\(value)->\(clampedValue)")
                } else {
                    violations.append("param_clamped_high:\(key):\(value)->\(clampedValue)")
                }
                clampedKeys.insert(key)
                if key.contains("density") {
                    densityCapped = true
                }
                if key == "voice_cap" || key == "particle_voice_cap" {
                    voiceCapped = true
                }
            }
            clamped[key] = clampedValue
        }

        if densityCapped {
            violations.append("density_cap")
        }
        if voiceCapped {
            violations.append("voice_cap")
        }
        if !clampedKeys.isEmpty {
            violations.append("clamp_keys:\(clampedKeys.sorted().joined(separator: ","))")
        }

        return (clamped, violations)
    }

    static func validate(picks: Picks, mode: Int) -> [String] {
        var violations: [String] = []
        for key in requiredPicks(for: mode) {
            let value = pickValue(for: key, picks: picks)
            if value == nil || value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                violations.append("missing_pick:\(key)")
            }
        }
        return violations.sorted()
    }

    static func enforceIncoming(modelOut: ModelOut, currentMode: Int) -> (ModelOut, [String]) {
        let mode = clampMode(currentMode)
        var violations: [String] = []

        if modelOut.protocolVersion != supportedProtocolVersion {
            violations.append("protocol_version_mismatch:\(modelOut.protocolVersion)")
        }
        if modelOut.mode != mode {
            violations.append("mode_mismatch:expected=\(mode):actual=\(modelOut.mode)")
        }

        let clamped = clamp(params: modelOut.params, mode: mode)
        let pickViolations = validate(picks: modelOut.picks, mode: mode)
        violations.append(contentsOf: clamped.violations)
        violations.append(contentsOf: pickViolations)

        let hasHardViolation = violations.contains(where: {
            $0.hasPrefix("protocol_version_mismatch:")
            || $0.hasPrefix("mode_mismatch:")
            || $0.hasPrefix("missing_pick:")
            || $0.hasPrefix("param_not_allowed:")
            || $0.hasPrefix("param_not_finite:")
        })

        if hasHardViolation {
            return (safeDefaults(mode: mode, tsMs: modelOut.tsMs, contractViolation: true), violations)
        }

        let sanitized = ModelOut(
            protocolVersion: supportedProtocolVersion,
            tsMs: modelOut.tsMs,
            mode: mode,
            params: clamped.clamped,
            picks: modelOut.picks,
            flags: modelOut.flags
        )
        return (sanitized, violations)
    }

    static func safeDefaults(mode: Int, tsMs: Int = Int(Date().timeIntervalSince1970 * 1000), contractViolation: Bool) -> ModelOut {
        let m = clampMode(mode)
        var params = safeModeParams[m] ?? [:]
        for key in canonicalAllowedParams(for: m) {
            params[key] = params[key] ?? defaultForKey(mode: m, key: key)
        }

        let picks = defaultPicksByMode[m] ?? Picks(
            presetId: "fallback_\(m)",
            bankId: nil,
            sampleId: nil,
            midiInstId: nil,
            chordSetId: nil,
            motifId: nil,
            articulationId: nil,
            spatialPatternId: "center",
            sceneId: nil,
            gridDiv: nil,
            repeatStyleId: nil,
            categoryId: nil,
            gestureTypeId: nil,
            mappingId: nil,
            varianceAmt: nil,
            variantSeed: nil,
            mappingFamily: nil
        )

        return ModelOut(
            protocolVersion: supportedProtocolVersion,
            tsMs: tsMs,
            mode: m,
            params: params,
            picks: picks,
            flags: Flags(requestCooldown: false, preferStability: true, thinEvents: contractViolation)
        )
    }

    static func protocolViolationFallback(mode: Int, tsMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> ModelOut {
        safeDefaults(mode: mode, tsMs: tsMs, contractViolation: true)
    }

    private static func clampMode(_ mode: Int) -> Int {
        Swift.max(0, Swift.min(10, mode))
    }

    private static func defaultForKey(mode: Int, key: String) -> Double {
        guard let b = modeBounds[mode]?[key] else { return 0.5 }
        return (b.0 + b.1) * 0.5
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private static func linear(min: Double, max: Double) -> Transform {
        let span = max - min
        return { value in min + span * value }
    }

    private static func pickValue(for key: String, picks: Picks) -> String? {
        switch key {
        case "preset_id": return picks.presetId
        case "bank_id": return picks.bankId
        case "sample_id": return picks.sampleId
        case "midi_inst_id": return picks.midiInstId
        case "chord_set_id": return picks.chordSetId
        case "spatial_pattern_id": return picks.spatialPatternId
        case "scene_id": return picks.sceneId
        case "grid_div": return picks.gridDiv
        case "repeat_style_id": return picks.repeatStyleId
        case "category_id": return picks.categoryId
        case "gesture_type_id": return picks.gestureTypeId
        case "mapping_id": return picks.mappingId
        case "mapping_family": return picks.mappingFamily
        default: return nil
        }
    }
}

import Foundation

enum SpatialMotion: Equatable {
    case `static`
    case drift
    case orbit
    case fragment
    case orbitPulse
    case jumpCut
    case clusterRotate
}

struct ReverbTarget: Equatable {
    var presetId: String = "room_small"
    var wet: Double = 0.12
    var decay: Double = 0.30
    var preDelay: Double = 0.08
    var damping: Double = 0.45
    var xfadeMs: Double = 450.0

    mutating func clampRails() {
        wet = min(max(wet, 0.0), 0.50)
        decay = min(max(decay, 0.0), 1.0)
        preDelay = min(max(preDelay, 0.0), 1.0)
        damping = min(max(damping, 0.0), 1.0)
        xfadeMs = min(max(xfadeMs, 250.0), 1000.0)
    }
}

struct AudioControl: Equatable {
    var mode: Int = 0
    var level: Double = 0.80
    var dryLevel: Double = 0.90
    var wetLevel: Double = 0.15

    var spread: Double = 0.35
    var motionSpeed: Double = 0.15
    var motionRadius: Double = 0.35
    var spatialMotion: SpatialMotion = .drift

    var reverb: ReverbTarget = ReverbTarget()

    // Mode 2
    var grainSize: Double = 0.45
    var grainDensity: Double = 0.35
    var scanRate: Double = 0.35
    var scanJumpProb: Double = 0.08
    var grainPitchSpread: Double = 0.34
    var freezeProb: Double = 0.03
    var freezeLenSec: Double = 1.0

    // Mode 1
    var mode1Fracture: Double = 0.55
    var mode1Mutation: Double = 0.40
    var mode1PitchLock: Double = 0.68
    var mode1HoldLenSec: Double = 8.0
    var mode1TailFadeMs: Double = 420.0
    var mode1SceneRateHz: Double = 3.0
    var mode1SceneId: String = "razor_gate"
    var mode1ClearRequest: Bool = false
    var mode1JoltRequest: Bool = false
    // Legacy compatibility mirrors retained for internal stability.
    var repeatProb: Double = 0.40
    var thresholdBias: Double = 0.30
    var windowNorm: Double = 0.45
    var stutterLenNorm: Double = 0.28
    var gateSharpness: Double = 0.55
    var motionIntensity: Double = 0.40
    var gridDiv: String = "1/8"
    var repeatStyleId: String = "stutter_a"

    // Mode 3
    var exciteAmount: Double = 0.45
    var resonance: Double = 0.45
    var drive: Double = 0.25
    // Internal representation where 0=>8-bit, 2=>24-bit.
    var bitDepth: Double = 1.0
    var downsample: Double = 0.0
    var resonatorTuningProfileId: String = "res_default"
    var hfClampWetPath: Bool = false

    // Mode 9
    var bandLowLevel: Double = 0.40
    var bandMidLevel: Double = 0.40
    var bandHighLevel: Double = 0.30
    var bandMotionSpeed: Double = 0.35

    // Mode 4
    var gestureRate: Double = 0.45
    var interruptiveness: Double = 0.30
    var callResponseBias: Double = 0.55
    var memoryWeight: Double = 0.65
    var similarityTarget: Double = 0.70
    var gestureLevel: Double = 0.35
    var bankId: String?
    var categoryId: String?
    var gestureTypeId: String = "call_response"

    // Modes 5/6
    var noteRate: Double = 0.45
    var voiceCap: Double = 0.30
    var velocityBias: Double = 0.55
    var pitchFollow: Double = 0.60
    var inharmonicity: Double = 0.12
    var midiInstId: String = "inst_A"
    var chordSetId: String = "cs_neutral"
    var motifId: String?
    var articulationId: String = "legato"
    var resetVoices: Bool = false

    // Mode 7
    var morphRate: Double = 0.40
    var swapCrossfade: Double = 0.58
    var sharpness: Double = 0.62
    var bias: Double = 0.50
    var mappingId: String = "swap_pairs"
    var varianceAmt: Double = 0.20
    var variantSeed: Int = 7
    var mappingFamily: String = "bucket_swap"
}

final class ModeEngine {
    private(set) var currentMode: Int = 0

    func setMode(_ mode: Int) {
        currentMode = max(0, min(10, mode))
    }

    func makeControl(out: ModelOut, sentButtons: Buttons) -> AudioControl {
        let targetMode = out.mode
        setMode(targetMode)

        let resolved = ManifestCatalog.shared.resolve(mode: currentMode, picks: out.picks)
        var control = safeControl(mode: currentMode)
        control.mode = currentMode
        control.spatialMotion = mapSpatialMotion(
            id: resolved.routing.spatialPatternId,
            definition: resolved.routing.spatialPattern
        )
        control.reverb.presetId = mapReverbPreset(mode: currentMode, picks: resolved.picks)

        switch currentMode {
        case 0:
            control.dryLevel = param("dry_level", default: control.dryLevel, from: out.params)
            control.reverb.wet = param("reverb_mix", fallbacks: ["reverb_wet", "reverb_size", "wet"], default: control.reverb.wet, from: out.params)
            let decayS = paramReal("reverb_decay_s", fallback: "reverb_decay", default: 1.0, min: 0.2, max: 2.8, from: out.params)
            control.reverb.decay = normalize(decayS, min: 0.2, max: 2.8)
            let preDelayMs = paramReal("pre_delay_ms", fallback: "pre_delay", default: 12.0, min: 0.0, max: 60.0, from: out.params)
            control.reverb.preDelay = normalize(preDelayMs, min: 0.0, max: 60.0)
            control.motionSpeed = param("motion_speed", default: control.motionSpeed, from: out.params)
            let toneDb = paramReal("tone_db", fallback: "brightness", default: 0.0, min: -6.0, max: 6.0, from: out.params)
            control.level = min(1.0, max(0.0, 0.62 + (toneDb / 24.0)))
            control.wetLevel = control.reverb.wet

        case 1:
            let fracture = param("fracture", fallback: "repeat_prob", default: control.mode1Fracture, from: out.params)
            let mutation: Double = {
                if let value = out.params["mutation"] {
                    return min(max(value, 0.0), 1.0)
                }
                if let jitterRaw = out.params["jitter_ms"] ?? out.params["gate_sharpness"] {
                    if jitterRaw > 1.0 {
                        return min(max(jitterRaw / 120.0, 0.0), 1.0)
                    }
                    return min(max(jitterRaw, 0.0), 1.0)
                }
                return control.mode1Mutation
            }()
            let pitchLock: Double = {
                if let value = out.params["pitch_lock"] {
                    return min(max(value, 0.0), 1.0)
                }
                if let followRaw = out.params["pitch_follow"] {
                    if followRaw > 1.0 {
                        return normalize(followRaw, min: 0.65, max: 1.0)
                    }
                    return min(max(followRaw, 0.0), 1.0)
                }
                return control.mode1PitchLock
            }()
            let holdLenS: Double = {
                if let value = out.params["hold_len_s"] {
                    return min(max(value, 6.0), 12.0)
                }
                if let loopRaw = out.params["loop_len_s"] ?? out.params["window_norm"] ?? out.params["repeat_grid"] {
                    let norm = loopRaw > 1.0 ? normalize(loopRaw, min: 0.08, max: 4.0) : min(max(loopRaw, 0.0), 1.0)
                    return 6.0 + (6.0 * norm)
                }
                if let feedbackRaw = out.params["feedback"] ?? out.params["threshold_bias"] {
                    let norm = min(max(feedbackRaw / 0.65, 0.0), 1.0)
                    return 6.0 + (6.0 * norm)
                }
                return min(max(control.mode1HoldLenSec, 6.0), 12.0)
            }()
            let tailFadeMs = paramReal("tail_fade_ms", default: control.mode1TailFadeMs, min: 150.0, max: 1_200.0, from: out.params)
            let sceneRateHz: Double = {
                if let value = out.params["scene_rate_hz"] {
                    return min(max(value, 0.25), 12.0)
                }
                if let stutterRaw = out.params["stutter_len_ms"] ?? out.params["stutter_len_norm"] ?? out.params["stutter_len"] {
                    let ms = stutterRaw > 1.0
                        ? min(max(stutterRaw, 30.0), 450.0)
                        : 30.0 + (420.0 * min(max(stutterRaw, 0.0), 1.0))
                    let t = normalize(ms, min: 30.0, max: 450.0)
                    return 12.0 - ((12.0 - 0.25) * t)
                }
                return min(max(control.mode1SceneRateHz, 0.25), 12.0)
            }()

            control.mode1Fracture = fracture
            control.mode1Mutation = mutation
            control.mode1PitchLock = pitchLock
            control.mode1HoldLenSec = holdLenS
            control.mode1TailFadeMs = tailFadeMs
            control.mode1SceneRateHz = sceneRateHz
            control.repeatProb = fracture
            control.thresholdBias = min(1.0, max(0.0, (holdLenS - 6.0) / 6.0))
            control.windowNorm = min(1.0, max(0.0, (holdLenS - 6.0) / 6.0))
            control.stutterLenNorm = 1.0 - normalize(sceneRateHz, min: 0.25, max: 12.0)
            control.gateSharpness = mutation
            control.motionIntensity = max(fracture, mutation)
            control.motionSpeed = param("motion_speed", fallback: "motion_intensity", default: max(control.motionSpeed, 0.22 + 0.60 * normalize(sceneRateHz, min: 0.25, max: 12.0)), from: out.params)
            control.spread = max(param("spread", default: control.spread, from: out.params), 0.45 + 0.35 * fracture)
            control.wetLevel = min(0.60, max(0.56, 0.56 + 0.10 * fracture + 0.10 * mutation))
            control.dryLevel = max(0.01, min(0.24, 0.20 - (0.08 * fracture) - (0.06 * mutation)))
            control.level = min(1.0, max(control.level, 0.90 + 0.06 * fracture + 0.04 * mutation))
            control.gridDiv = normalizeGridDiv(resolved.picks.gridDiv ?? control.gridDiv)
            control.repeatStyleId = resolved.picks.repeatStyleId ?? control.repeatStyleId
            control.mode1SceneId = resolveMode1SceneId(
                requestedSceneId: resolved.picks.sceneId,
                repeatStyleId: control.repeatStyleId
            )
            control.reverb.wet = min(0.42, 0.18 + 0.18 * mutation + 0.12 * fracture)
            control.reverb.damping = min(1.0, max(0.0, 0.35 + 0.45 * (1.0 - mutation)))
            control.mode1ClearRequest = sentButtons.clear
            control.mode1JoltRequest = sentButtons.jolt

        case 2:
            let voicing = mode2Voicing(for: resolved.picks.presetId)
            let grainSizeMs = paramReal("grain_size_ms", fallback: "grain_size", default: 44.0, min: 12.0, max: 120.0, from: out.params)
            let grainSizeNorm = normalize(grainSizeMs, min: 12.0, max: 120.0)
            control.grainSize = min(1.0, max(0.0, 0.06 + 0.88 * grainSizeNorm))
            let density = paramReal("grain_density", fallback: "density", default: 0.45, min: 0.1, max: 0.9, from: out.params)
            control.grainDensity = min(1.0, max(0.0, 0.15 + 0.82 * normalize(density, min: 0.1, max: 0.9)))
            control.scanRate = min(1.0, max(0.0, 0.10 + 0.82 * param("scan_rate", default: control.scanRate, from: out.params)))
            let scanJump = param("scan_jump_prob", default: control.scanJumpProb, from: out.params)
            control.scanJumpProb = min(1.0, max(0.0, 0.16 + 0.78 * scanJump))
            let freezeProb = paramReal("freeze_prob", default: 0.12, min: 0.0, max: 0.75, from: out.params)
            control.freezeProb = normalize(freezeProb, min: 0.0, max: 0.75)
            control.freezeLenSec = min(voicing.maxFreezeLenSec, paramReal("freeze_len_s", default: control.freezeLenSec, min: 0.2, max: 6.0, from: out.params))
            let pitchSpread = paramReal("pitch_spread_cents", fallback: "spread", default: 12.0, min: 0.0, max: 35.0, from: out.params)
            let pitchSpreadNorm = normalize(pitchSpread, min: 0.0, max: 35.0)
            control.grainPitchSpread = pitchSpreadNorm
            control.scanJumpProb = max(control.scanJumpProb, pitchSpreadNorm * 0.74)
            control.motionSpeed = param("motion_speed", default: max(control.motionSpeed, control.scanRate), from: out.params)
            control.spread = max(param("spread", default: control.spread, from: out.params), pitchSpreadNorm * 0.65)
            control.wetLevel = min(0.60, (0.30 + 0.42 * control.grainDensity + 0.12 * pitchSpreadNorm) * voicing.wetScale)
            control.dryLevel = max(0.12, min(0.86, voicing.dryBase - (control.wetLevel * 0.90)))
            control.level = min(1.0, max(control.level, 0.88 + 0.10 * control.grainDensity))
            control.reverb.wet = min(0.38, (0.12 + 0.20 * control.grainDensity + 0.08 * pitchSpreadNorm) * voicing.reverbScale)
            control.reverb.damping = min(1.0, max(0.0, 0.35 + 0.40 * (1.0 - control.grainDensity)))

        case 3:
            let drive = paramReal("drive", default: 0.52, min: 0.0, max: 0.85, from: out.params)
            control.drive = normalize(drive, min: 0.0, max: 0.85)
            let bitDepthBits = paramReal("bit_depth_bits", fallback: "bit_depth", default: 12.0, min: 8.0, max: 24.0, from: out.params)
            let bitDepthNorm = normalize(bitDepthBits, min: 8.0, max: 24.0)
            control.bitDepth = (bitDepthBits - 8.0) / 8.0
            control.downsample = param("downsample_amt", fallback: "downsample", default: control.downsample, from: out.params)
            control.resonance = param("res_shift", fallback: "resonance", default: control.resonance, from: out.params)
            let toneDb = paramReal("tone_db", fallback: "brightness", default: -3.0, min: -9.0, max: 6.0, from: out.params)
            let toneNorm = normalize(toneDb, min: -9.0, max: 6.0)
            let crushSeverity = min(1.0, max(0.0, (0.60 * (1.0 - bitDepthNorm)) + (0.40 * control.downsample)))
            control.exciteAmount = toneNorm
            control.wetLevel = min(0.56, max(0.36, 0.36 + (0.16 * crushSeverity) + (0.06 * control.resonance)))
            control.dryLevel = min(0.60, max(0.24, 0.50 - (0.16 * crushSeverity) + (0.10 * (1.0 - control.drive))))
            control.motionSpeed = param("motion_speed", default: control.motionSpeed, from: out.params)
            control.spread = param("spread", default: control.spread, from: out.params)
            control.resonatorTuningProfileId = resolved.picks.presetId ?? "res_default"
            control.reverb.wet = min(0.14, 0.03 + (0.06 * (1.0 - crushSeverity)))
            control.hfClampWetPath = true

        case 4:
            let density = param("density", fallback: "interruptiveness", default: control.interruptiveness, from: out.params)
            let gestureRateHz = paramReal("gesture_rate_hz", fallback: "gesture_rate", default: 1.2, min: 0.1, max: 6.0, from: out.params)
            control.gestureRate = normalize(gestureRateHz, min: 0.1, max: 6.0)
            control.interruptiveness = density
            control.callResponseBias = min(1.0, max(0.0, 0.85 - (0.60 * density)))
            control.memoryWeight = param("stability", fallback: "memory_weight", default: control.memoryWeight, from: out.params)
            control.similarityTarget = min(1.0, max(0.0, 0.25 + 0.65 * control.memoryWeight))
            let dryRequested = paramReal("dry_level", default: control.dryLevel, min: 0.0, max: 0.35, from: out.params)
            control.dryLevel = min(0.18, dryRequested)
            let gestureMix = param(
                "sample_mix",
                fallbacks: ["gesture_level", "sample_level", "wet"],
                default: max(control.gestureLevel, 0.78),
                from: out.params
            )
            control.gestureLevel = max(0.65, gestureMix)
            control.wetLevel = max(0.82, min(1.0, 0.70 + 0.30 * control.gestureLevel))
            control.level = max(control.level, 0.84 + 0.10 * control.gestureLevel)
            control.bankId = resolved.picks.bankId
            control.categoryId = resolved.picks.categoryId
            control.gestureTypeId = resolved.picks.gestureTypeId ?? "call_response"
            control.motionSpeed = max(control.motionSpeed, 0.18 + 0.45 * control.interruptiveness)

        case 5:
            let noteRate = paramReal("note_rate_notes_per_s", fallback: "note_rate", default: 4.0, min: 0.0, max: 12.0, from: out.params)
            control.noteRate = normalize(noteRate, min: 0.0, max: 12.0)
            let voiceCap = paramReal("voice_cap", default: 4.0, min: 2.0, max: 8.0, from: out.params)
            control.voiceCap = normalize(voiceCap, min: 2.0, max: 8.0)
            control.velocityBias = param("velocity_bias", default: control.velocityBias, from: out.params)
            control.pitchFollow = paramReal("pitch_follow", default: control.pitchFollow, min: 0.65, max: 1.0, from: out.params)
            let stability = param("stability", default: 0.72, from: out.params)
            control.inharmonicity = min(1.0, max(0.0, 1.0 - stability))
            control.level = param("level", default: control.level, from: out.params)
            control.dryLevel = 0.0
            control.wetLevel = min(0.60, 0.28 + 0.30 * control.level)
            control.bankId = resolved.picks.bankId
            control.midiInstId = resolved.picks.midiInstId ?? control.midiInstId
            control.chordSetId = resolved.picks.chordSetId ?? control.chordSetId
            control.motifId = resolved.picks.motifId
            control.articulationId = resolved.picks.articulationId ?? "legato"
            control.motionSpeed = max(control.motionSpeed, 0.18 + 0.55 * control.noteRate)
            control.spread = max(control.spread, 0.52)
            control.reverb.wet = min(0.30, 0.08 + 0.22 * control.inharmonicity)
            control.resetVoices = sentButtons.clear || out.flags.resetVoices

        case 6:
            let noteRate = paramReal("note_rate_notes_per_s", fallback: "note_rate", default: 2.4, min: 0.0, max: 6.0, from: out.params)
            control.noteRate = normalize(noteRate, min: 0.0, max: 6.0)
            let voiceCap = paramReal("voice_cap", default: 2.0, min: 1.0, max: 3.0, from: out.params)
            control.voiceCap = normalize(voiceCap, min: 1.0, max: 3.0)
            control.velocityBias = param("velocity_bias", default: control.velocityBias, from: out.params)
            control.pitchFollow = paramReal("pitch_follow", default: control.pitchFollow, min: 0.65, max: 1.0, from: out.params)
            let stability = param("stability", default: 0.72, from: out.params)
            control.inharmonicity = min(1.0, max(0.0, 1.0 - stability))
            control.level = param("level", default: control.level, from: out.params)
            control.dryLevel = paramReal("dry_level", default: 0.66, min: 0.35, max: 0.95, from: out.params)
            control.wetLevel = min(0.45, 0.12 + 0.32 * control.noteRate)
            control.bankId = resolved.picks.bankId
            control.midiInstId = resolved.picks.midiInstId ?? control.midiInstId
            control.chordSetId = resolved.picks.chordSetId ?? control.chordSetId
            control.motifId = resolved.picks.motifId
            control.articulationId = resolved.picks.articulationId ?? "short"
            control.motionSpeed = max(control.motionSpeed, 0.14 + 0.40 * control.noteRate)
            control.spread = max(control.spread, 0.48)
            control.reverb.wet = min(0.24, 0.04 + 0.18 * control.inharmonicity)
            control.resetVoices = sentButtons.clear || out.flags.resetVoices

        case 7:
            control.wetLevel = max(0.90, param("mix", fallback: "wet", default: control.wetLevel, from: out.params))
            control.dryLevel = min(0.08, max(0.0, 0.18 - (control.wetLevel * 0.14)))
            let swapRate = paramReal("swap_rate_hz", fallback: "morph_rate", default: 1.8, min: 0.1, max: 6.0, from: out.params)
            control.morphRate = normalize(swapRate, min: 0.1, max: 6.0)
            let crossfadeMs = paramReal("crossfade_ms", fallback: "crossfade", default: 180.0, min: 20.0, max: 600.0, from: out.params)
            control.swapCrossfade = normalize(crossfadeMs, min: 20.0, max: 600.0)
            control.sharpness = max(0.72, param("bucket_sharpness", fallback: "sharpness", default: control.sharpness, from: out.params))
            control.bias = param("mapping_entropy", fallback: "bias", default: control.bias, from: out.params)
            control.mappingId = resolved.picks.mappingId ?? control.mappingId
            control.varianceAmt = max(0.0, min(1.0, resolved.picks.varianceAmt ?? control.varianceAmt))
            control.variantSeed = resolved.picks.variantSeed ?? control.variantSeed
            control.mappingFamily = resolved.picks.mappingFamily ?? control.mappingFamily
            control.motionSpeed = max(control.motionSpeed, 0.34 + 0.60 * control.morphRate)
            control.spread = max(control.spread, 0.68)
            control.motionRadius = max(control.motionRadius, 0.54)
            control.reverb.wet = min(control.reverb.wet, 0.08)

        case 8:
            control.motionSpeed = param("motion_speed", default: control.motionSpeed, from: out.params)
            control.spread = param("spread", default: control.spread, from: out.params)
            control.motionRadius = max(0.20, control.spread)
            control.reverb.wet = param("reverb_rand_amt", fallbacks: ["reverb_wet", "wet"], default: control.reverb.wet, from: out.params)
            let baseDecay = paramReal("reverb_decay_base_s", fallback: "reverb_decay", default: 1.0, min: 0.2, max: 3.5, from: out.params)
            let decayRange = paramReal("reverb_decay_range_s", default: 0.6, min: 0.0, max: 2.0, from: out.params)
            let twitchiness = param("twitchiness", default: control.motionSpeed, from: out.params)
            let decayS = min(3.5, max(0.2, baseDecay + (decayRange * twitchiness * 0.5)))
            control.reverb.decay = normalize(decayS, min: 0.2, max: 3.5)
            control.reverb.preDelay = 0.05 + 0.25 * control.reverb.wet
            control.reverb.damping = param("reverb_color", fallback: "damping", default: control.reverb.damping, from: out.params)
            control.reverb.xfadeMs = mapXfade(min(1.0, max(0.05, 0.25 + (0.75 * twitchiness))))
            control.dryLevel = max(0.45, 1.0 - control.reverb.wet)
            control.wetLevel = control.reverb.wet

        case 9:
            let density = param("particle_density", fallbacks: ["band_low_level", "density"], default: 0.42, from: out.params)
            let brightness = param("particle_brightness", fallbacks: ["band_high_level", "band_high"], default: 0.45, from: out.params)
            let voiceCap = paramReal("particle_voice_cap", default: 8.0, min: 1.0, max: 24.0, from: out.params)
            let particleDecay = paramReal("particle_decay_s", fallback: "reverb_decay", default: 0.55, min: 0.05, max: 2.5, from: out.params)
            control.bandLowLevel = min(1.0, max(0.15, 0.20 + 0.70 * (1.0 - brightness) + 0.20 * density))
            control.bandMidLevel = min(1.0, max(0.15, 0.30 + 0.55 * (1.0 - abs(0.5 - brightness) * 2.0)))
            control.bandHighLevel = min(1.0, max(0.15, 0.25 + 0.75 * brightness))
            control.spread = param("spread", default: control.spread, from: out.params)
            control.bandMotionSpeed = param("motion_speed", fallback: "band_motion_speed", default: control.bandMotionSpeed, from: out.params)
            control.motionSpeed = control.bandMotionSpeed
            control.reverb.wet = min(0.40, 0.08 + 0.28 * density + 0.12 * normalize(voiceCap, min: 1.0, max: 24.0))
            control.reverb.decay = normalize(particleDecay, min: 0.05, max: 2.5)
            control.reverb.preDelay = 0.04 + 0.16 * density
            control.reverb.damping = 0.25 + 0.60 * brightness
            control.reverb.xfadeMs = mapXfade(min(1.0, max(0.05, 0.30 + (0.60 * control.motionSpeed))))
            normalizeBands(&control)
            control.dryLevel = 0.95
            control.wetLevel = min(0.45, control.reverb.wet)

        default:
            break
        }

        if sentButtons.jolt {
            control.level = min(1.0, max(control.level, 0.88))
            control.wetLevel = min(0.50, control.wetLevel + 0.10)
            control.reverb.wet = min(0.50, control.reverb.wet + 0.10)
            control.motionSpeed = min(1.0, control.motionSpeed + 0.30)
            if currentMode == 2 {
                control.grainDensity = min(1.0, control.grainDensity + 0.20)
                control.scanJumpProb = min(1.0, control.scanJumpProb + 0.15)
                control.grainPitchSpread = min(1.0, control.grainPitchSpread + 0.12)
            } else if currentMode == 5 || currentMode == 6 {
                control.noteRate = min(1.0, control.noteRate + 0.20)
                control.voiceCap = min(1.0, control.voiceCap + 0.15)
            }
        }

        if currentMode != 5 && currentMode != 6 {
            control.resetVoices = false
        }

        clampFinal(&control)
        return control
    }

    // MARK: - Internals

    private struct Mode2Voicing {
        let wetScale: Double
        let reverbScale: Double
        let dryBase: Double
        let maxFreezeLenSec: Double
    }

    private func safeControl(mode: Int) -> AudioControl {
        switch mode {
        case 0:
            return AudioControl(
                mode: 0,
                level: 0.82,
                dryLevel: 0.95,
                wetLevel: 0.12,
                spread: 0.20,
                motionSpeed: 0.12,
                motionRadius: 0.20,
                spatialMotion: .drift,
                reverb: ReverbTarget(presetId: "room_clean", wet: 0.12, decay: 0.28, preDelay: 0.05, damping: 0.50, xfadeMs: 450)
            )
        case 1:
            return AudioControl(
                mode: 1,
                level: 0.92,
                dryLevel: 0.20,
                wetLevel: 0.58,
                spread: 0.62,
                motionSpeed: 0.44,
                motionRadius: 0.40,
                spatialMotion: .orbitPulse,
                reverb: ReverbTarget(presetId: "beat_A", wet: 0.20, decay: 0.28, preDelay: 0.05, damping: 0.52, xfadeMs: 400),
                mode1Fracture: 0.58,
                mode1Mutation: 0.42,
                mode1PitchLock: 0.68,
                mode1HoldLenSec: 8.0,
                mode1TailFadeMs: 480.0,
                mode1SceneRateHz: 3.0,
                mode1SceneId: "razor_gate",
                mode1ClearRequest: false,
                mode1JoltRequest: false,
                repeatProb: 0.66,
                thresholdBias: 0.32,
                windowNorm: 0.24,
                stutterLenNorm: 0.10,
                gateSharpness: 0.70,
                motionIntensity: 0.42,
                gridDiv: "1/8",
                repeatStyleId: "stutter_a"
            )
        case 2:
            return AudioControl(
                mode: 2,
                level: 0.90,
                dryLevel: 0.58,
                wetLevel: 0.48,
                spread: 0.60,
                motionSpeed: 0.42,
                motionRadius: 0.40,
                spatialMotion: .fragment,
                reverb: ReverbTarget(presetId: "fracture", wet: 0.30, decay: 0.30, preDelay: 0.07, damping: 0.58, xfadeMs: 450),
                grainSize: 0.22,
                grainDensity: 0.62,
                scanRate: 0.58,
                scanJumpProb: 0.34,
                grainPitchSpread: 0.62,
                freezeProb: 0.06,
                freezeLenSec: 0.9
            )
        case 3:
            return AudioControl(
                mode: 3,
                level: 0.78,
                dryLevel: 0.42,
                wetLevel: 0.48,
                spread: 0.50,
                motionSpeed: 0.34,
                motionRadius: 0.30,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "plate_dark", wet: 0.08, decay: 0.26, preDelay: 0.06, damping: 0.70, xfadeMs: 500),
                exciteAmount: 0.40,
                resonance: 0.64,
                drive: 0.52,
                bitDepth: 0.50,
                downsample: 0.44,
                resonatorTuningProfileId: "res_default",
                hfClampWetPath: true
            )
        case 4:
            return AudioControl(
                mode: 4,
                level: 0.86,
                dryLevel: 0.08,
                wetLevel: 0.92,
                spread: 0.52,
                motionSpeed: 0.30,
                motionRadius: 0.30,
                spatialMotion: .clusterRotate,
                reverb: ReverbTarget(presetId: "ultrachunk_A", wet: 0.10, decay: 0.24, preDelay: 0.04, damping: 0.42, xfadeMs: 420),
                gestureRate: 0.55,
                interruptiveness: 0.45,
                callResponseBias: 0.50,
                memoryWeight: 0.65,
                similarityTarget: 0.70,
                gestureLevel: 0.82,
                bankId: "samples_A",
                categoryId: "general",
                gestureTypeId: "call_response"
            )
        case 5:
            return AudioControl(
                mode: 5,
                level: 0.80,
                dryLevel: 0.0,
                wetLevel: 0.60,
                spread: 0.60,
                motionSpeed: 0.35,
                motionRadius: 0.48,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "midiwet_A", wet: 0.08, decay: 0.24, preDelay: 0.05, damping: 0.42, xfadeMs: 420),
                bankId: "phrases_A",
                noteRate: 0.55,
                voiceCap: 0.35,
                velocityBias: 0.55,
                pitchFollow: 0.62,
                inharmonicity: 0.12,
                midiInstId: "inst_A",
                chordSetId: "cs_neutral",
                motifId: nil,
                articulationId: "legato"
            )
        case 6:
            return AudioControl(
                mode: 6,
                level: 0.82,
                dryLevel: 0.66,
                wetLevel: 0.30,
                spread: 0.52,
                motionSpeed: 0.28,
                motionRadius: 0.40,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "mididry_A", wet: 0.06, decay: 0.20, preDelay: 0.04, damping: 0.40, xfadeMs: 420),
                bankId: "phrases_A",
                noteRate: 0.45,
                voiceCap: 0.30,
                velocityBias: 0.55,
                pitchFollow: 0.60,
                inharmonicity: 0.10,
                midiInstId: "inst_A",
                chordSetId: "cs_neutral",
                motifId: nil,
                articulationId: "short"
            )
        case 7:
            return AudioControl(
                mode: 7,
                level: 0.90,
                dryLevel: 0.03,
                wetLevel: 0.98,
                spread: 0.74,
                motionSpeed: 0.58,
                motionRadius: 0.62,
                spatialMotion: .clusterRotate,
                reverb: ReverbTarget(presetId: "buckets_A", wet: 0.06, decay: 0.24, preDelay: 0.03, damping: 0.42, xfadeMs: 420),
                morphRate: 0.68,
                swapCrossfade: 0.16,
                sharpness: 0.82,
                bias: 0.78,
                mappingId: "invert_diagonal",
                varianceAmt: 0.34,
                variantSeed: 7,
                mappingFamily: "bucket_swap"
            )
        case 8:
            return AudioControl(
                mode: 8,
                level: 0.82,
                dryLevel: 0.80,
                wetLevel: 0.22,
                spread: 0.65,
                motionSpeed: 0.35,
                motionRadius: 0.65,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "space", wet: 0.24, decay: 0.45, preDelay: 0.12, damping: 0.35, xfadeMs: 650)
            )
        case 9:
            return AudioControl(
                mode: 9,
                level: 0.84,
                dryLevel: 0.92,
                wetLevel: 0.20,
                spread: 0.72,
                motionSpeed: 0.42,
                motionRadius: 0.55,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "field_diffuse", wet: 0.18, decay: 0.38, preDelay: 0.10, damping: 0.42, xfadeMs: 600),
                bandLowLevel: 0.46,
                bandMidLevel: 0.34,
                bandHighLevel: 0.30,
                bandMotionSpeed: 0.42
            )
        default:
            return AudioControl(mode: mode)
        }
    }

    private func resolveMode1SceneId(requestedSceneId: String?, repeatStyleId: String) -> String {
        let allowed: Set<String> = [
            "razor_gate", "databend", "arp_shred",
            "reverse_flock", "spectral_melt", "void_strobe",
        ]
        if let requested = requestedSceneId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !requested.isEmpty,
           allowed.contains(requested) {
            return requested
        }
        let style = repeatStyleId.lowercased()
        if style == "stutter_b" {
            return "databend"
        }
        return "razor_gate"
    }

    private func mode2Voicing(for presetId: String?) -> Mode2Voicing {
        let id = (presetId ?? "").lowercased()
        if id.contains("shimmer") {
            return Mode2Voicing(wetScale: 1.08, reverbScale: 1.05, dryBase: 0.80, maxFreezeLenSec: 2.4)
        }
        if id.contains("soft") || id.contains("intelligible") {
            return Mode2Voicing(wetScale: 0.88, reverbScale: 0.85, dryBase: 0.88, maxFreezeLenSec: 2.0)
        }
        return Mode2Voicing(wetScale: 1.0, reverbScale: 1.0, dryBase: 0.84, maxFreezeLenSec: 2.8)
    }

    private func mapSpatialMotion(id: String?, definition: SpatialPatternManifestEntry?) -> SpatialMotion {
        if let definition {
            switch definition.algo {
            case .static: return .static
            case .drift: return .drift
            case .orbit: return .orbit
            case .fragment: return .fragment
            case .orbitPulse: return .orbitPulse
            case .jumpCut: return .jumpCut
            case .clusterRotate: return .clusterRotate
            }
        }

        switch id {
        case "tight_static": return .static
        case "fragment_soft": return .fragment
        case "orbit_pulse": return .orbitPulse
        case "jump_cut": return .jumpCut
        case "cluster_rotate": return .clusterRotate
        case "orbit_slow", "orbit_mid", "orbit_var": return .orbit
        default: return .drift
        }
    }

    private func mapReverbPreset(mode: Int, picks: Picks) -> String {
        if let preset = picks.presetId, !preset.isEmpty {
            return preset
        }
        switch mode {
        case 0: return "room_clean"
        case 1: return "beat_A"
        case 2: return "fracture"
        case 3: return "plate_dark"
        case 4: return "ultrachunk_A"
        case 5: return "midiwet_A"
        case 6: return "mididry_A"
        case 7: return "buckets_A"
        case 8: return "space"
        case 9: return "field_diffuse"
        default: return "room_small"
        }
    }

    private func mapXfade(_ normalized: Double) -> Double {
        let t = min(max(normalized, 0.0), 1.0)
        return 250.0 + (750.0 * t)
    }

    private func normalize(_ value: Double, min lo: Double, max hi: Double) -> Double {
        guard hi > lo else { return 0.0 }
        return min(max((value - lo) / (hi - lo), 0.0), 1.0)
    }

    private func paramReal(
        _ key: String,
        default defaultValue: Double,
        min lo: Double,
        max hi: Double,
        from params: [String: Double]
    ) -> Double {
        min(max(params[key] ?? defaultValue, lo), hi)
    }

    private func paramReal(
        _ key: String,
        fallback: String,
        default defaultValue: Double,
        min lo: Double,
        max hi: Double,
        from params: [String: Double]
    ) -> Double {
        min(max(params[key] ?? params[fallback] ?? defaultValue, lo), hi)
    }

    private func paramReal(
        _ key: String,
        fallbacks: [String],
        default defaultValue: Double,
        min lo: Double,
        max hi: Double,
        from params: [String: Double]
    ) -> Double {
        if let primary = params[key] {
            return min(max(primary, lo), hi)
        }
        for fallback in fallbacks {
            if let value = params[fallback] {
                return min(max(value, lo), hi)
            }
        }
        return min(max(defaultValue, lo), hi)
    }

    private func param(_ key: String, default defaultValue: Double, from params: [String: Double]) -> Double {
        min(max(params[key] ?? defaultValue, 0.0), 1.0)
    }

    private func param(_ key: String, fallback: String, default defaultValue: Double, from params: [String: Double]) -> Double {
        min(max(params[key] ?? params[fallback] ?? defaultValue, 0.0), 1.0)
    }

    private func param(_ key: String, fallbacks: [String], default defaultValue: Double, from params: [String: Double]) -> Double {
        if let primary = params[key] {
            return min(max(primary, 0.0), 1.0)
        }
        for fallback in fallbacks {
            if let value = params[fallback] {
                return min(max(value, 0.0), 1.0)
            }
        }
        return min(max(defaultValue, 0.0), 1.0)
    }

    private func normalizeBands(_ control: inout AudioControl) {
        let sum = control.bandLowLevel + control.bandMidLevel + control.bandHighLevel
        guard sum > 0.0001 else {
            control.bandLowLevel = 0.34
            control.bandMidLevel = 0.33
            control.bandHighLevel = 0.33
            return
        }
        control.bandLowLevel /= sum
        control.bandMidLevel /= sum
        control.bandHighLevel /= sum
    }

    private func clampFinal(_ control: inout AudioControl) {
        control.mode = max(0, min(10, control.mode))
        // Keep show output deterministic and avoid near-silent renders if upstream emits tiny level values.
        control.level = min(max(control.level, minimumLevelFloor(for: control.mode)), 1.0)
        control.dryLevel = min(max(control.dryLevel, 0.0), 1.0)
        if control.mode == 7 {
            control.wetLevel = min(max(control.wetLevel, 0.75), 1.0)
        } else {
            control.wetLevel = min(max(control.wetLevel, 0.0), 0.60)
        }
        control.spread = min(max(control.spread, 0.0), 1.0)
        control.motionSpeed = min(max(control.motionSpeed, 0.0), 1.0)
        control.motionRadius = min(max(control.motionRadius, 0.0), 1.0)
        control.grainSize = min(max(control.grainSize, 0.0), 1.0)
        control.grainDensity = min(max(control.grainDensity, 0.0), 1.0)
        control.scanRate = min(max(control.scanRate, 0.0), 1.0)
        control.scanJumpProb = min(max(control.scanJumpProb, 0.0), 1.0)
        control.grainPitchSpread = min(max(control.grainPitchSpread, 0.0), 1.0)
        control.freezeProb = min(max(control.freezeProb, 0.0), 1.0)
        control.freezeLenSec = min(max(control.freezeLenSec, 0.2), 6.0)
        control.exciteAmount = min(max(control.exciteAmount, 0.0), 1.0)
        control.resonance = min(max(control.resonance, 0.0), 1.0)
        control.drive = min(max(control.drive, 0.0), 1.0)
        control.bitDepth = min(max(control.bitDepth, 0.0), 2.0)
        control.downsample = min(max(control.downsample, 0.0), 1.0)
        control.bandLowLevel = min(max(control.bandLowLevel, 0.0), 1.0)
        control.bandMidLevel = min(max(control.bandMidLevel, 0.0), 1.0)
        control.bandHighLevel = min(max(control.bandHighLevel, 0.0), 1.0)
        control.bandMotionSpeed = min(max(control.bandMotionSpeed, 0.0), 1.0)
        control.repeatProb = min(max(control.repeatProb, 0.0), 1.0)
        control.thresholdBias = min(max(control.thresholdBias, 0.0), 1.0)
        control.windowNorm = min(max(control.windowNorm, 0.0), 1.0)
        control.stutterLenNorm = min(max(control.stutterLenNorm, 0.0), 1.0)
        control.gateSharpness = min(max(control.gateSharpness, 0.0), 1.0)
        control.motionIntensity = min(max(control.motionIntensity, 0.0), 1.0)
        control.mode1Fracture = min(max(control.mode1Fracture, 0.0), 1.0)
        control.mode1Mutation = min(max(control.mode1Mutation, 0.0), 1.0)
        control.mode1PitchLock = min(max(control.mode1PitchLock, 0.0), 1.0)
        control.mode1HoldLenSec = min(max(control.mode1HoldLenSec, 6.0), 12.0)
        control.mode1TailFadeMs = min(max(control.mode1TailFadeMs, 150.0), 1_200.0)
        control.mode1SceneRateHz = min(max(control.mode1SceneRateHz, 0.25), 12.0)
        control.gridDiv = normalizeGridDiv(control.gridDiv)
        control.gestureRate = min(max(control.gestureRate, 0.0), 1.0)
        control.interruptiveness = min(max(control.interruptiveness, 0.0), 1.0)
        control.callResponseBias = min(max(control.callResponseBias, 0.0), 1.0)
        control.memoryWeight = min(max(control.memoryWeight, 0.0), 1.0)
        control.similarityTarget = min(max(control.similarityTarget, 0.0), 1.0)
        control.gestureLevel = min(max(control.gestureLevel, 0.0), 1.0)
        control.noteRate = min(max(control.noteRate, 0.0), 1.0)
        control.voiceCap = min(max(control.voiceCap, 0.0), 1.0)
        control.velocityBias = min(max(control.velocityBias, 0.0), 1.0)
        control.pitchFollow = min(max(control.pitchFollow, 0.0), 1.0)
        control.inharmonicity = min(max(control.inharmonicity, 0.0), 1.0)
        control.morphRate = min(max(control.morphRate, 0.0), 1.0)
        control.swapCrossfade = min(max(control.swapCrossfade, 0.0), 1.0)
        control.sharpness = min(max(control.sharpness, 0.0), 1.0)
        control.bias = min(max(control.bias, 0.0), 1.0)
        control.varianceAmt = min(max(control.varianceAmt, 0.0), 1.0)
        control.reverb.clampRails()
    }

    private func minimumLevelFloor(for mode: Int) -> Double {
        switch mode {
        case 1: return 0.86
        case 2: return 0.82
        case 3: return 0.74
        case 4: return 0.86
        case 5: return 0.84
        case 6: return 0.84
        case 7: return 0.88
        case 8: return 0.76
        case 9: return 0.80
        default: return 0.76
        }
    }

    private func normalizeGridDiv(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1/16": return "1/16"
        default: return "1/8"
        }
    }
}

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
            let voicing = mode1Voicing(for: resolved.picks.presetId)
            let repeatProb = param("repeat_prob", default: control.repeatProb, from: out.params)
            control.repeatProb = min(1.0, max(0.0, 0.10 + 0.86 * repeatProb))
            let loopLenS = paramReal("loop_len_s", fallback: "window_norm", default: 1.2, min: 0.08, max: 4.0, from: out.params)
            control.windowNorm = min(1.0, max(0.0, normalize(loopLenS, min: 0.08, max: 4.0)))
            let stutterMs = paramReal("stutter_len_ms", fallbacks: ["stutter_len_norm", "stutter_len"], default: 160.0, min: 30.0, max: 450.0, from: out.params)
            control.stutterLenNorm = min(1.0, max(0.0, 0.04 + 0.92 * normalize(stutterMs, min: 30.0, max: 450.0)))
            let jitterMs = paramReal("jitter_ms", fallback: "gate_sharpness", default: 18.0, min: 0.0, max: 120.0, from: out.params)
            control.gateSharpness = min(1.0, max(0.0, 0.15 + 0.82 * normalize(jitterMs, min: 0.0, max: 120.0)))
            let feedback = paramReal("feedback", fallback: "threshold_bias", default: 0.18, min: 0.0, max: 0.65, from: out.params)
            control.thresholdBias = min(1.0, max(0.0, 0.06 + 0.74 * normalize(feedback, min: 0.0, max: 0.65)))
            control.motionIntensity = param("motion_intensity", fallback: "motion_speed", default: control.motionIntensity, from: out.params)
            control.motionSpeed = param("motion_speed", fallback: "motion_intensity", default: control.motionSpeed, from: out.params)
            control.spread = param("spread", default: control.spread, from: out.params)
            control.wetLevel = min(0.62, (0.18 + 0.34 * control.repeatProb + 0.16 * control.thresholdBias) * voicing.wetScale)
            control.dryLevel = max(0.25, min(0.96, voicing.dryBase - (control.wetLevel * voicing.dryDuck)))
            control.gridDiv = normalizeGridDiv(resolved.picks.gridDiv ?? control.gridDiv)
            control.repeatStyleId = resolved.picks.repeatStyleId ?? control.repeatStyleId
            control.motionSpeed = max(control.motionSpeed, control.motionIntensity * voicing.motionFloor)
            control.reverb.wet = min(0.24, 0.08 + 0.12 * control.repeatProb + 0.08 * control.thresholdBias)
            control.reverb.damping = min(1.0, max(0.0, 0.42 + 0.34 * (1.0 - control.thresholdBias)))

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
            control.wetLevel = min(0.64, (0.20 + 0.32 * control.grainDensity + 0.10 * pitchSpreadNorm) * voicing.wetScale)
            control.dryLevel = max(0.20, min(0.94, voicing.dryBase - (control.wetLevel * 0.58)))
            control.reverb.wet = min(0.32, (0.08 + 0.16 * control.grainDensity + 0.06 * pitchSpreadNorm) * voicing.reverbScale)
            control.reverb.damping = min(1.0, max(0.0, 0.35 + 0.40 * (1.0 - control.grainDensity)))

        case 3:
            let drive = paramReal("drive", default: 0.22, min: 0.0, max: 0.85, from: out.params)
            control.drive = normalize(drive, min: 0.0, max: 0.85)
            let bitDepthBits = paramReal("bit_depth_bits", fallback: "bit_depth", default: 18.0, min: 8.0, max: 24.0, from: out.params)
            control.bitDepth = (bitDepthBits - 8.0) / 8.0
            control.downsample = param("downsample_amt", fallback: "downsample", default: control.downsample, from: out.params)
            control.resonance = param("res_shift", fallback: "resonance", default: control.resonance, from: out.params)
            let toneDb = paramReal("tone_db", fallback: "brightness", default: -1.0, min: -9.0, max: 6.0, from: out.params)
            control.exciteAmount = min(1.0, max(0.0, 0.35 + (toneDb / 18.0) + (0.45 * control.resonance)))
            control.wetLevel = min(0.32, 0.10 + 0.20 * control.drive + 0.08 * control.resonance)
            control.dryLevel = max(0.50, 1.0 - (control.wetLevel * 0.90))
            control.motionSpeed = param("motion_speed", default: control.motionSpeed, from: out.params)
            control.spread = param("spread", default: control.spread, from: out.params)
            control.resonatorTuningProfileId = resolved.picks.presetId ?? "res_default"
            control.reverb.wet = min(0.22, 0.06 + 0.18 * control.wetLevel)
            control.hfClampWetPath = true

        case 4:
            let density = param("density", fallback: "interruptiveness", default: control.interruptiveness, from: out.params)
            let gestureRateHz = paramReal("gesture_rate_hz", fallback: "gesture_rate", default: 1.2, min: 0.1, max: 6.0, from: out.params)
            control.gestureRate = normalize(gestureRateHz, min: 0.1, max: 6.0)
            control.interruptiveness = density
            control.callResponseBias = min(1.0, max(0.0, 0.85 - (0.60 * density)))
            control.memoryWeight = param("stability", fallback: "memory_weight", default: control.memoryWeight, from: out.params)
            control.similarityTarget = min(1.0, max(0.0, 0.25 + 0.65 * control.memoryWeight))
            control.dryLevel = param("dry_level", default: control.dryLevel, from: out.params)
            control.gestureLevel = param("sample_mix", fallbacks: ["gesture_level", "sample_level", "wet"], default: control.gestureLevel, from: out.params)
            control.wetLevel = min(0.40, 0.08 + 0.34 * control.gestureLevel)
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
            control.wetLevel = max(0.86, param("mix", fallback: "wet", default: control.wetLevel, from: out.params))
            control.dryLevel = min(0.14, max(0.0, 0.24 - (control.wetLevel * 0.14)))
            let swapRate = paramReal("swap_rate_hz", fallback: "morph_rate", default: 1.8, min: 0.1, max: 6.0, from: out.params)
            control.morphRate = normalize(swapRate, min: 0.1, max: 6.0)
            let crossfadeMs = paramReal("crossfade_ms", fallback: "crossfade", default: 180.0, min: 20.0, max: 600.0, from: out.params)
            control.swapCrossfade = normalize(crossfadeMs, min: 20.0, max: 600.0)
            control.sharpness = param("bucket_sharpness", fallback: "sharpness", default: control.sharpness, from: out.params)
            control.bias = param("mapping_entropy", fallback: "bias", default: control.bias, from: out.params)
            control.mappingId = resolved.picks.mappingId ?? control.mappingId
            control.varianceAmt = max(0.0, min(1.0, resolved.picks.varianceAmt ?? control.varianceAmt))
            control.variantSeed = resolved.picks.variantSeed ?? control.variantSeed
            control.mappingFamily = resolved.picks.mappingFamily ?? control.mappingFamily
            control.motionSpeed = max(control.motionSpeed, 0.28 + 0.52 * control.morphRate)
            control.spread = max(control.spread, 0.62)
            control.motionRadius = max(control.motionRadius, 0.46)
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

    private struct Mode1Voicing {
        let wetScale: Double
        let dryBase: Double
        let dryDuck: Double
        let motionFloor: Double
    }

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
                level: 0.82,
                dryLevel: 0.80,
                wetLevel: 0.36,
                spread: 0.50,
                motionSpeed: 0.30,
                motionRadius: 0.40,
                spatialMotion: .orbitPulse,
                reverb: ReverbTarget(presetId: "beat_A", wet: 0.12, decay: 0.28, preDelay: 0.05, damping: 0.56, xfadeMs: 400),
                repeatProb: 0.58,
                thresholdBias: 0.18,
                windowNorm: 0.26,
                stutterLenNorm: 0.12,
                gateSharpness: 0.55,
                motionIntensity: 0.38,
                gridDiv: "1/8",
                repeatStyleId: "stutter_a"
            )
        case 2:
            return AudioControl(
                mode: 2,
                level: 0.80,
                dryLevel: 0.76,
                wetLevel: 0.36,
                spread: 0.60,
                motionSpeed: 0.42,
                motionRadius: 0.40,
                spatialMotion: .fragment,
                reverb: ReverbTarget(presetId: "fracture", wet: 0.24, decay: 0.30, preDelay: 0.07, damping: 0.58, xfadeMs: 450),
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
                dryLevel: 0.70,
                wetLevel: 0.22,
                spread: 0.45,
                motionSpeed: 0.30,
                motionRadius: 0.30,
                spatialMotion: .orbit,
                reverb: ReverbTarget(presetId: "plate_dark", wet: 0.14, decay: 0.30, preDelay: 0.08, damping: 0.65, xfadeMs: 500),
                exciteAmount: 0.45,
                resonance: 0.50,
                drive: 0.15,
                bitDepth: 0.92,
                downsample: 0.02,
                resonatorTuningProfileId: "res_default",
                hfClampWetPath: true
            )
        case 4:
            return AudioControl(
                mode: 4,
                level: 0.82,
                dryLevel: 0.72,
                wetLevel: 0.22,
                spread: 0.40,
                motionSpeed: 0.25,
                motionRadius: 0.30,
                spatialMotion: .clusterRotate,
                reverb: ReverbTarget(presetId: "ultrachunk_A", wet: 0.16, decay: 0.26, preDelay: 0.06, damping: 0.45, xfadeMs: 450),
                gestureRate: 0.45,
                interruptiveness: 0.30,
                callResponseBias: 0.55,
                memoryWeight: 0.65,
                similarityTarget: 0.70,
                gestureLevel: 0.35,
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
                level: 0.84,
                dryLevel: 0.08,
                wetLevel: 0.94,
                spread: 0.68,
                motionSpeed: 0.48,
                motionRadius: 0.55,
                spatialMotion: .clusterRotate,
                reverb: ReverbTarget(presetId: "buckets_A", wet: 0.06, decay: 0.24, preDelay: 0.03, damping: 0.42, xfadeMs: 420),
                morphRate: 0.55,
                swapCrossfade: 0.22,
                sharpness: 0.74,
                bias: 0.72,
                mappingId: "swap_pairs",
                varianceAmt: 0.28,
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

    private func mode1Voicing(for presetId: String?) -> Mode1Voicing {
        let id = (presetId ?? "").lowercased()
        if id.contains("tight") {
            return Mode1Voicing(wetScale: 0.88, dryBase: 0.84, dryDuck: 0.74, motionFloor: 0.78)
        }
        if id.contains("fill") || id.contains("jump") {
            return Mode1Voicing(wetScale: 1.10, dryBase: 0.90, dryDuck: 0.92, motionFloor: 0.90)
        }
        return Mode1Voicing(wetScale: 1.0, dryBase: 0.87, dryDuck: 0.86, motionFloor: 0.84)
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
        control.level = min(max(control.level, 0.0), 1.0)
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

    private func normalizeGridDiv(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1/16": return "1/16"
        default: return "1/8"
        }
    }
}

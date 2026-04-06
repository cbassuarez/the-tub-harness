import SwiftUI
import Combine
import AppKit

struct StageColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue).opacity(alpha)
    }
}

enum StageAccentRole: Equatable {
    case signal
    case active
    case warning
    case alert
    case dim
}

enum StageWordmarkGlitchStyle: String, Equatable {
    case quietWatch
    case relayMesh
    case faultLattice
    case memoryDrift
    case alarmSplay
}

enum StageFlashGeometryStyle: String, Equatable {
    case bands
    case gateColumns
    case radialBurst
    case diagonalStrike
    case blockTear
    case verticalClamp
}

enum StageFieldTopology: String, Equatable {
    case gridLock = "grid_lock"
    case relayMesh = "relay_mesh"
    case faultLattice = "fault_lattice"
    case memoryDrift = "memory_drift"
    case alarmSplay = "alarm_splay"
    case quietWatch = "quiet_watch"
}

enum StageModuleArchetype: String, Equatable {
    case controlToken = "control_token"
    case decisionBurst = "decision_burst"
    case deltaEcho = "delta_echo"
    case audioDebris = "audio_debris"
    case memoryGhost = "memory_ghost"
    case linkSignal = "link_signal"
}

enum StageIndustrialPalette {
    static let graphite = StageColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)
    static let slate = StageColor(red: 0.11, green: 0.14, blue: 0.17, alpha: 1.0)
    static let signal = StageColor(red: 0.88, green: 0.91, blue: 0.93, alpha: 1.0)
    static let active = StageColor(red: 0.58, green: 0.93, blue: 0.43, alpha: 1.0)
    static let amber = StageColor(red: 0.95, green: 0.72, blue: 0.24, alpha: 1.0)
    static let alert = StageColor(red: 0.86, green: 0.22, blue: 0.18, alpha: 1.0)
    static let acid = StageColor(red: 0.76, green: 0.96, blue: 0.33, alpha: 1.0)
    static let dimSignal = StageColor(red: 0.44, green: 0.49, blue: 0.52, alpha: 1.0)

    static func accent(for role: StageAccentRole) -> StageColor {
        switch role {
        case .signal:
            return signal
        case .active:
            return active
        case .warning:
            return amber
        case .alert:
            return alert
        case .dim:
            return dimSignal
        }
    }
}

struct StageSceneProfile: Equatable {
    let id: String
    let topology: StageFieldTopology
    let backgroundDensity: Double
    let tokenDrift: Double
    let tokenScatter: Double
    let jitter: Double
    let flashFloor: Double
    let wordmarkNoise: Double

    static func forId(_ id: String) -> StageSceneProfile {
        switch id {
        case "grid_lock":
            return StageSceneProfile(id: id, topology: .gridLock, backgroundDensity: 0.22, tokenDrift: 0.10, tokenScatter: 0.16, jitter: 0.08, flashFloor: 0.12, wordmarkNoise: 0.08)
        case "relay_mesh":
            return StageSceneProfile(id: id, topology: .relayMesh, backgroundDensity: 0.30, tokenDrift: 0.18, tokenScatter: 0.24, jitter: 0.10, flashFloor: 0.18, wordmarkNoise: 0.16)
        case "fault_lattice":
            return StageSceneProfile(id: id, topology: .faultLattice, backgroundDensity: 0.38, tokenDrift: 0.24, tokenScatter: 0.34, jitter: 0.18, flashFloor: 0.28, wordmarkNoise: 0.28)
        case "memory_drift":
            return StageSceneProfile(id: id, topology: .memoryDrift, backgroundDensity: 0.26, tokenDrift: 0.32, tokenScatter: 0.22, jitter: 0.12, flashFloor: 0.16, wordmarkNoise: 0.20)
        case "alarm_splay":
            return StageSceneProfile(id: id, topology: .alarmSplay, backgroundDensity: 0.44, tokenDrift: 0.38, tokenScatter: 0.46, jitter: 0.24, flashFloor: 0.36, wordmarkNoise: 0.38)
        default:
            return StageSceneProfile(id: id, topology: .quietWatch, backgroundDensity: 0.14, tokenDrift: 0.08, tokenScatter: 0.10, jitter: 0.04, flashFloor: 0.08, wordmarkNoise: 0.06)
        }
    }
}

struct ModeVisualProfile: Equatable {
    let mode: Int
    let anchors: [CGPoint]
    let topology: StageFieldTopology
    let fractureVector: CGSize
    let wordmarkStyle: StageWordmarkGlitchStyle
    let flashStyle: StageFlashGeometryStyle
    let debrisBias: Double

    static func forMode(_ mode: Int) -> ModeVisualProfile {
        switch mode {
        case 0:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.50, y: 0.44), CGPoint(x: 0.30, y: 0.52), CGPoint(x: 0.70, y: 0.52)], topology: .quietWatch, fractureVector: CGSize(width: 0.06, height: 0.01), wordmarkStyle: .quietWatch, flashStyle: .bands, debrisBias: 0.12)
        case 1:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.20, y: 0.50), CGPoint(x: 0.80, y: 0.50), CGPoint(x: 0.50, y: 0.48)], topology: .relayMesh, fractureVector: CGSize(width: 0.22, height: 0.00), wordmarkStyle: .relayMesh, flashStyle: .gateColumns, debrisBias: 0.20)
        case 2:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.72, y: 0.24), CGPoint(x: 0.56, y: 0.40), CGPoint(x: 0.42, y: 0.58)], topology: .memoryDrift, fractureVector: CGSize(width: 0.14, height: -0.18), wordmarkStyle: .memoryDrift, flashStyle: .radialBurst, debrisBias: 0.34)
        case 3:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.50, y: 0.72), CGPoint(x: 0.34, y: 0.60), CGPoint(x: 0.66, y: 0.60)], topology: .faultLattice, fractureVector: CGSize(width: 0.00, height: 0.20), wordmarkStyle: .faultLattice, flashStyle: .verticalClamp, debrisBias: 0.28)
        case 4:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.24, y: 0.28), CGPoint(x: 0.50, y: 0.52), CGPoint(x: 0.78, y: 0.76)], topology: .faultLattice, fractureVector: CGSize(width: 0.24, height: 0.24), wordmarkStyle: .faultLattice, flashStyle: .diagonalStrike, debrisBias: 0.48)
        case 5:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.28, y: 0.20), CGPoint(x: 0.54, y: 0.24), CGPoint(x: 0.68, y: 0.70)], topology: .relayMesh, fractureVector: CGSize(width: 0.12, height: -0.08), wordmarkStyle: .relayMesh, flashStyle: .bands, debrisBias: 0.18)
        case 6:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.70, y: 0.22), CGPoint(x: 0.68, y: 0.50), CGPoint(x: 0.50, y: 0.52)], topology: .gridLock, fractureVector: CGSize(width: 0.08, height: 0.00), wordmarkStyle: .quietWatch, flashStyle: .verticalClamp, debrisBias: 0.10)
        case 7:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.16, y: 0.52), CGPoint(x: 0.50, y: 0.52), CGPoint(x: 0.84, y: 0.52)], topology: .memoryDrift, fractureVector: CGSize(width: 0.26, height: 0.02), wordmarkStyle: .memoryDrift, flashStyle: .blockTear, debrisBias: 0.24)
        case 8:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.18, y: 0.18), CGPoint(x: 0.82, y: 0.22), CGPoint(x: 0.50, y: 0.50)], topology: .quietWatch, fractureVector: CGSize(width: 0.00, height: -0.06), wordmarkStyle: .quietWatch, flashStyle: .radialBurst, debrisBias: 0.08)
        case 9:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.24, y: 0.72), CGPoint(x: 0.42, y: 0.60), CGPoint(x: 0.76, y: 0.36)], topology: .alarmSplay, fractureVector: CGSize(width: 0.22, height: -0.18), wordmarkStyle: .alarmSplay, flashStyle: .bands, debrisBias: 0.38)
        default:
            return ModeVisualProfile(mode: mode, anchors: [CGPoint(x: 0.30, y: 0.22), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.72, y: 0.74)], topology: .alarmSplay, fractureVector: CGSize(width: 0.18, height: 0.18), wordmarkStyle: .alarmSplay, flashStyle: .blockTear, debrisBias: 0.42)
        }
    }
}

struct StageWordmarkState: Equatable {
    let topText: String
    let bottomText: String
    let glitchStyle: StageWordmarkGlitchStyle
    let integrity: Double
}

struct StageParamState: Identifiable, Equatable {
    let id: String
    let token: String
    let valueToken: String
    let normalizedValue: Double
    let rawNormalizedValue: Double?
    let changedByHarness: Bool
}

struct StagePickState: Identifiable, Equatable {
    let id: String
    let token: String
    let resolvedToken: String
    let rawToken: String?
    let changedByHarness: Bool
}

enum StageChangeKind: String, Equatable {
    case param
    case pick
    case visual
}

struct StageChangeEvent: Identifiable, Equatable {
    let id: String
    let kind: StageChangeKind
    let token: String
    let resolvedToken: String
    let rawToken: String?
    let changedByHarness: Bool
    let startedAt: Date
}

struct StageThoughtSprite: Identifiable, Equatable {
    let id: String
    let mode: Int
    let archetype: StageModuleArchetype
    let token: String
    let detail: String?
    let accentRole: StageAccentRole
    let secondaryRole: StageAccentRole
    let origin: CGPoint
    let drift: CGSize
    let rotationDegrees: Double
    let createdAt: Date
    let delay: TimeInterval
    let fadeInDuration: TimeInterval
    let holdDuration: TimeInterval
    let fadeOutDuration: TimeInterval
    let blurRadius: Double
    let scale: Double

    func isAlive(at now: Date) -> Bool {
        age(at: now) <= totalDuration
    }

    func age(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(createdAt))
    }

    var totalDuration: TimeInterval {
        delay + fadeInDuration + holdDuration + fadeOutDuration
    }
}

struct VideoStageSnapshot: Equatable {
    let mode: Int
    let isRunning: Bool
    let isWaiting: Bool
    let waitingReason: String?
    let latencyMs: Int?
    let updatedAt: Date?
    let wordmark: StageWordmarkState
    let sceneProfile: StageSceneProfile
    let visualProfile: ModeVisualProfile
    let params: [StageParamState]
    let picks: [StagePickState]
    let changes: [StageChangeEvent]
    let sprites: [StageThoughtSprite]
    let hasAdjustments: Bool
    let joltHeld: Bool
    let joltBeganAt: Date?
    let joltSeed: UInt64
    let stageAudio: StageAudioSnapshot
    let visual: VisualOut
    let thoughtChangedAt: Date?
    let thoughtLogComposedAt: Date?
    fileprivate let monitorSnapshot: MLMonitorSnapshot

    static func standby(
        for mode: Int,
        joltHeld: Bool = false,
        joltBeganAt: Date? = nil,
        joltSeed: UInt64 = 0,
        stageAudio: StageAudioSnapshot = .standby
    ) -> VideoStageSnapshot {
        let monitor = MLMonitorSnapshot.waiting(for: mode, reason: nil)
        let profile = ModeVisualProfile.forMode(mode)
        let visual = VisualOut.defaultForMode(mode)
        return VideoStageSnapshot(
            mode: mode,
            isRunning: false,
            isWaiting: false,
            waitingReason: nil,
            latencyMs: nil,
            updatedAt: nil,
            wordmark: StageWordmarkState(topText: "THE", bottomText: "TUB", glitchStyle: profile.wordmarkStyle, integrity: visual.wordmarkIntegrity),
            sceneProfile: StageSceneProfile.forId(visual.sceneId),
            visualProfile: profile,
            params: [],
            picks: [],
            changes: [],
            sprites: [],
            hasAdjustments: false,
            joltHeld: joltHeld,
            joltBeganAt: joltBeganAt,
            joltSeed: joltSeed,
            stageAudio: stageAudio,
            visual: visual,
            thoughtChangedAt: nil,
            thoughtLogComposedAt: nil,
            monitorSnapshot: monitor
        )
    }
}

enum VideoStageMapper {
    private static let changeWindow: TimeInterval = 2.5
    private static let paramChangeThreshold: Double = 0.03
    private static let maxSpriteCount = 40

    static func buildSnapshot(
        mode: Int,
        context: ModelMonitorContext?,
        isRunning: Bool,
        isJoltHeld: Bool,
        previous: VideoStageSnapshot?,
        modeEngine: ModeEngine,
        stageAudio: StageAudioSnapshot,
        now: Date = Date()
    ) -> VideoStageSnapshot {
        let normalizedMode = max(0, min(10, mode))
        let profile = ModeVisualProfile.forMode(normalizedMode)
        let rawVisual = context?.resolvedPacket.visual ?? VisualOut.defaultForMode(normalizedMode)
        let visual = enrichThought(visual: rawVisual, mode: normalizedMode, audio: stageAudio, isJoltHeld: isJoltHeld, previous: previous, now: now)
        let sceneProfile = StageSceneProfile.forId(visual.sceneId)
        let wordmark = StageWordmarkState(
            topText: "THE",
            bottomText: "TUB",
            glitchStyle: profile.wordmarkStyle,
            integrity: visual.wordmarkIntegrity
        )
        let nextJoltSeed = resolveJoltSeed(isJoltHeld: isJoltHeld, previous: previous, now: now, mode: normalizedMode)
        let joltBeganAt = resolveJoltBeganAt(isJoltHeld: isJoltHeld, previous: previous, now: now)

        guard isRunning else {
            return .standby(
                for: normalizedMode,
                joltHeld: isJoltHeld,
                joltBeganAt: joltBeganAt,
                joltSeed: nextJoltSeed,
                stageAudio: stageAudio
            )
        }

        let previousMonitor = previous?.monitorSnapshot
        let monitorSnapshot = MLMonitorMapper.buildSnapshot(
            currentMode: normalizedMode,
            context: context,
            modeEngine: modeEngine,
            previous: previousMonitor
        )

        let resolvedPicks = context?.resolvedPacket.picks ?? Picks()
        let rawPicks = context?.rawPacket?.picks
        let params = monitorSnapshot.resolvedKnobs.map { knob in
            let resolvedValue = context?.resolvedPacket.params[knob.canonicalKey] ?? 0
            let bounds = ModeContract.bounds(for: normalizedMode, param: knob.canonicalKey) ?? (0.0, 1.0)
            return StageParamState(
                id: knob.id,
                token: stageToken(for: knob.id),
                valueToken: stageValueToken(key: knob.canonicalKey, value: resolvedValue, bounds: bounds),
                normalizedValue: knob.normalizedValue,
                rawNormalizedValue: knob.rawNormalizedValue,
                changedByHarness: knob.changedByHarness
            )
        }
        let picks = monitorSnapshot.picks.map { pick in
            let resolvedToken = pickValue(for: pick.pickKey, picks: resolvedPicks) ?? "not_set"
            return StagePickState(
                id: pick.id,
                token: stageToken(for: pick.pickKey),
                resolvedToken: resolvedToken,
                rawToken: rawPicks.flatMap { pickValue(for: pick.pickKey, picks: $0) },
                changedByHarness: pick.changedByHarness
            )
        }

        let preservedChanges: [StageChangeEvent]
        if previous?.mode == normalizedMode {
            preservedChanges = (previous?.changes ?? []).filter { now.timeIntervalSince($0.startedAt) <= changeWindow }
        } else {
            preservedChanges = []
        }

        let newChanges = previous?.mode == normalizedMode
            ? buildNewChanges(previous: previous, params: params, picks: picks, visual: visual, now: now)
            : seedVisualChanges(visual: visual, previous: previous, now: now)
        let changes = Array((preservedChanges + newChanges).suffix(8))
        let sprites = monitorSnapshot.isWaiting
            ? []
            : buildThoughtSprites(
                previous: previous,
                mode: normalizedMode,
                params: params,
                picks: picks,
                changes: newChanges,
                profile: profile,
                sceneProfile: sceneProfile,
                visual: visual,
                stageAudio: stageAudio,
                now: now
            )

        return VideoStageSnapshot(
            mode: normalizedMode,
            isRunning: true,
            isWaiting: monitorSnapshot.isWaiting,
            waitingReason: monitorSnapshot.waitingReason,
            latencyMs: monitorSnapshot.latencyMs,
            updatedAt: monitorSnapshot.updatedAt,
            wordmark: wordmark,
            sceneProfile: sceneProfile,
            visualProfile: profile,
            params: monitorSnapshot.isWaiting ? [] : params,
            picks: monitorSnapshot.isWaiting ? [] : picks,
            changes: monitorSnapshot.isWaiting ? [] : changes,
            sprites: sprites,
            hasAdjustments: monitorSnapshot.hasAdjustments || (context?.contractViolations.contains(where: { $0.hasPrefix("visual_") }) ?? false),
            joltHeld: isJoltHeld,
            joltBeganAt: joltBeganAt,
            joltSeed: nextJoltSeed,
            stageAudio: stageAudio,
            visual: visual,
            thoughtChangedAt: (visual.thought != (previous?.visual.thought ?? "")) ? now : previous?.thoughtChangedAt,
            thoughtLogComposedAt: (visual.thoughtLog != (previous?.visual.thoughtLog ?? [])) ? now : previous?.thoughtLogComposedAt,
            monitorSnapshot: monitorSnapshot
        )
    }

    /// Minimum seconds a thought must hold before it can change.
    private static let thoughtHoldSeconds: TimeInterval = 3.5

    /// Minimum seconds between local thought log recompositions.
    private static let localThoughtLogInterval: TimeInterval = 8.0

    private static func enrichThought(visual: VisualOut, mode: Int, audio: StageAudioSnapshot, isJoltHeld: Bool, previous: VideoStageSnapshot?, now: Date) -> VisualOut {
        // If the model server provided a non-idle thought, trust it — but still respect hold.
        let candidateThought: String
        if visual.thought != "idle" {
            candidateThought = visual.thought
        } else {
            // Derive from local audio.
            let energy = audio.rms
            if energy < 0.02 {
                candidateThought = "idle"
            } else if audio.overloadPulse > 0.4 {
                candidateThought = "overload_detected"
            } else if audio.transientFlux > 0.5 {
                candidateThought = "responding_to_transient"
            } else if energy > 0.45 && audio.transientFlux > 0.25 {
                candidateThought = "building_density"
            } else if audio.highBand > 0.5 {
                candidateThought = "tracking_highs"
            } else if audio.lowBand > 0.5 && audio.highBand < 0.25 {
                candidateThought = "tracking_bass"
            } else if audio.midBand > 0.45 {
                candidateThought = "tracking_mids"
            } else if audio.brightness > 0.55 {
                candidateThought = "following_brightness"
            } else if visual.disruption > 0.5 {
                candidateThought = "pushing_disruption"
            } else if visual.cohesion > 0.65 && energy > 0.1 {
                candidateThought = "holding_pattern"
            } else if visual.cohesion < 0.3 && energy > 0.15 {
                candidateThought = "releasing_tension"
            } else if isJoltHeld {
                candidateThought = "sampling_texture"
            } else if mode == 10 {
                candidateThought = "shifting_scene"
            } else if mode == 9 {
                candidateThought = "particle_bloom"
            } else if mode == 8 {
                candidateThought = "routing_signal"
            } else if energy > 0.08 {
                candidateThought = "listening"
            } else {
                candidateThought = "idle"
            }
        }

        // Hold: keep previous thought if it hasn't been shown long enough.
        if let prev = previous,
           let changedAt = prev.thoughtChangedAt,
           prev.visual.thought != "idle",
           now.timeIntervalSince(changedAt) < thoughtHoldSeconds,
           candidateThought != prev.visual.thought {
            // Keep the previous thought and its log — not enough time has passed.
            return withThought(visual, prev.visual.thought, thoughtLog: prev.visual.thoughtLog)
        }

        // Overload always breaks through hold immediately.
        if candidateThought == "overload_detected", let prev = previous, prev.visual.thought != "overload_detected" {
            return withThought(visual, candidateThought, thoughtLog: prev.visual.thoughtLog)
        }

        // Generate local thought log if the server didn't provide one.
        let thoughtLog: [String]
        if !visual.thoughtLog.isEmpty {
            thoughtLog = visual.thoughtLog
        } else if let prev = previous, !prev.visual.thoughtLog.isEmpty,
                  let composedAt = prev.thoughtLogComposedAt,
                  now.timeIntervalSince(composedAt) < localThoughtLogInterval {
            // Keep previous log — composed recently enough.
            thoughtLog = prev.visual.thoughtLog
        } else {
            thoughtLog = composeLocalThoughtLog(thought: candidateThought, audio: audio, visual: visual, mode: mode, isJoltHeld: isJoltHeld)
        }

        return withThought(visual, candidateThought, thoughtLog: thoughtLog)
    }

    // MARK: - Local Thought Log Composition

    /// Generates verbose, human-like inner monologue from local audio features.
    /// Used when the ML server doesn't provide thought_log lines.
    private static func composeLocalThoughtLog(thought: String, audio: StageAudioSnapshot, visual: VisualOut, mode: Int, isJoltHeld: Bool) -> [String] {
        var lines: [String] = []
        let energy = audio.rms

        // 1. What I'm hearing (spectral description)
        lines.append(describeHearing(audio: audio))

        // 2. What just happened / what's notable
        if let delta = describeDelta(audio: audio, isJoltHeld: isJoltHeld) {
            lines.append(delta)
        }

        // 3. What I'm doing about it (response)
        if let response = describeResponse(thought: thought, visual: visual, energy: energy) {
            lines.append(response)
        }

        return Array(lines.prefix(4))
    }

    private static func describeHearing(audio: StageAudioSnapshot) -> String {
        let energy = audio.rms

        if energy < 0.02 {
            return ["Quiet. Barely anything coming in right now.",
                    "Almost nothing. Room tone, maybe some breath.",
                    "Very still. I'm just listening to the ambient floor.",
                    "Dead air, essentially. Waiting for something to start."].randomElement()!
        }
        if energy < 0.10 {
            return ["Something faint — there's signal but it's low.",
                    "Soft input. I can make something out but it's gentle.",
                    "Low-level activity, hovering just above the noise floor.",
                    "Quiet but present. There's a shape to it, just subtle."].randomElement()!
        }

        let bassHeavy = audio.lowBand > 0.45 && audio.highBand < 0.25
        let midHeavy = audio.midBand > 0.40 && audio.lowBand < 0.45 && audio.highBand < 0.40
        let bright = audio.highBand > 0.45 || audio.brightness > 0.55
        let broadband = energy > 0.40 && audio.lowBand > 0.3 && audio.midBand > 0.3 && audio.highBand > 0.3
        let noisy = audio.transientFlux > 0.4 && energy > 0.2

        if noisy {
            return ["Noisy signal. There's content in there but it's rough and textured.",
                    "High noise content — the signal is grainy and dense. Hard to pull apart.",
                    "Lots of inharmonic energy. It's chaotic but there's movement in it."].randomElement()!
        }
        if broadband {
            return ["Full spectrum — lows, mids, highs all present. It's dense and stacked.",
                    "Everything's cooking. Wide, full signal across the board.",
                    "Broadband energy, all three bands active and competing for space.",
                    "Thick and full. The whole frequency range is alive right now."].randomElement()!
        }
        if bassHeavy {
            return ["Heavy low end. The bass is doing most of the work here, warm and deep.",
                    "Bottom-heavy. I can feel the low frequencies dominating everything else.",
                    "Thick bass presence. The mids and highs are staying out of the way.",
                    "Low-end focused — deep, resonant. Not a lot happening above the mids.",
                    "The sub content is leading. Dark and warm, like a pulse underneath."].randomElement()!
        }
        if bright {
            return ["Bright. The high end is really forward right now, cutting through.",
                    "Lots of treble content — sparkly, detailed, airy. The top end is leading.",
                    "The highs are very present. Crisp and open, lots of detail up top.",
                    "Spectral balance is riding high. Almost glassy in the upper harmonics.",
                    "Bright and open. There's a shimmer in the high frequencies leading this."].randomElement()!
        }
        if midHeavy {
            return ["Mid-range is where the action is. Warm, present, textured.",
                    "The middle of the spectrum is carrying this. Could be voice or keys or strings.",
                    "Harmonically rich in the mids — lots of overtone content sitting right there.",
                    "Mid-focused. The body of the sound lives right in the center of the spectrum."].randomElement()!
        }

        // Generic moderate
        return ["There's signal here, moderate energy. A mix of content, nothing dominant.",
                "Hearing input at a comfortable level. Balanced, no one band taking over.",
                "Moderate activity. The signal has shape but isn't pushing hard in any direction.",
                "Something's going on. Energy is there but it's measured, not aggressive."].randomElement()!
    }

    private static func describeDelta(audio: StageAudioSnapshot, isJoltHeld: Bool) -> String? {
        if isJoltHeld {
            return ["Jolt is active. Sampling the texture, freezing this moment.",
                    "Jolt firing — capturing what's happening right now.",
                    "Jolt hit. Taking a snapshot of the current state."].randomElement()!
        }
        if audio.overloadPulse > 0.4 {
            return ["That's running hot. Input overload territory — backing off to protect the signal.",
                    "Overload. The input is clipping, I'm pulling back.",
                    "Too much. The signal is distorting at the input stage."].randomElement()!
        }
        if audio.transientFlux > 0.55 {
            return ["Sharp transient just came through. Percussive hit or a hard pluck.",
                    "Transient spike — fast attack, probably rhythmic. Adjusting to it.",
                    "Something impulsive just cut through the texture. Sharp onset."].randomElement()!
        }
        return nil
    }

    private static func describeResponse(thought: String, visual: VisualOut, energy: Double) -> String? {
        switch thought {
        case "building_density":
            return ["Thickening the visual field. This energy deserves more weight in the scene.",
                    "Building it up — the input is pushing and I'm matching it.",
                    "Density is climbing. The field is getting heavier to meet the signal."].randomElement()!
        case "tracking_bass":
            return ["Locked onto the low-frequency content. Letting the bass drive the movement.",
                    "Following the bottom end. The lows are steering everything right now.",
                    "Bass is in charge here. I'm riding it."].randomElement()!
        case "tracking_mids":
            return ["Following the midrange structure. Warm, resonant — it shapes the cohesion.",
                    "The mids are carrying this. Letting harmonic content set the tone.",
                    "Midrange is the anchor. Building the visual field around it."].randomElement()!
        case "tracking_highs":
            return ["Tracking high-frequency detail. Pulling the field toward sharper textures.",
                    "The highs are leading. Letting the brightness shape the field.",
                    "Upper harmonics are dominant. Adjusting to match the sparkle."].randomElement()!
        case "following_brightness":
            return ["Responding to spectral brightness. The tonal color is shifting.",
                    "Brightness is driving the palette. Everything tilts toward the light.",
                    "The spectral balance is bright and I'm following it."].randomElement()!
        case "pushing_disruption":
            return ["Noise content is high. Letting disruption rise to match the chaos.",
                    "The signal is rough — the visuals should be too. Pushing disruption.",
                    "Chaos in, chaos out. Disruption is climbing."].randomElement()!
        case "holding_pattern":
            return ["Stable input, steady pattern. Holding where I am.",
                    "Nothing asking me to change. Holding the field steady.",
                    "Cruising. The input is consistent and so is my response."].randomElement()!
        case "releasing_tension":
            return ["Something feels unstable. Releasing tension, letting things loosen.",
                    "The cohesion is low. Letting the field breathe and drift.",
                    "Loosening up. The structure wants to come apart a little."].randomElement()!
        case "responding_to_transient":
            return ["That transient demanded a response. Absorbing the impact.",
                    "Hit registered. Adjusting the field to that impulse.",
                    "Sharp onset just came through. Reacting."].randomElement()!
        case "overload_detected":
            return ["Overload — engaging protection. Pulling back to safe levels.",
                    "Too hot. Clamping down, protecting the output.",
                    "Overload detected. Everything comes down now."].randomElement()!
        case "cooling_down":
            return ["Cooling down from that intensity. Letting the system settle.",
                    "Recovery mode. The peak passed, easing back to baseline.",
                    "Coming off that spike. Bringing the parameters back to center."].randomElement()!
        case "sampling_texture":
            return ["Jolt is active — sampling the texture, amplifying this moment.",
                    "Capturing the current state. Jolt is freezing a slice of this.",
                    "Jolt fired. Locking onto what's here right now."].randomElement()!
        case "shifting_scene":
            return ["The character changed enough for a scene shift. Transitioning.",
                    "Scene change. The input evolved and the visual context should too.",
                    "New scene. The input asked for a different setting."].randomElement()!
        case "routing_signal":
            return ["Routing through spatial processing. The input has architecture I'm tracing.",
                    "Spatial routing active. Mapping the signal's structure into space.",
                    "Tracing the signal path through the spatial field."].randomElement()!
        case "particle_bloom":
            return ["Particle field expanding — energy radiating outward from the core.",
                    "Bloom. The particles are spreading as the energy pushes out.",
                    "Particle expansion. The field is opening up."].randomElement()!
        case "stabilizing":
            return ["Stabilizing. Smoothing the response, finding equilibrium.",
                    "Settling into a groove. Parameters are converging.",
                    "Finding balance. The output is stabilizing around the input."].randomElement()!
        case "favoring_structure":
            return ["Favoring structural coherence. The signal has order to build on.",
                    "Structure is here. Leaning into the coherence.",
                    "There's a pattern in the input. Following its shape."].randomElement()!
        case "restoring_integrity":
            return ["Restoring signal integrity. The field drifted — bringing it back.",
                    "Correcting. The output wandered and I'm pulling it back to center.",
                    "Drift correction. Realigning with the input."].randomElement()!
        case "listening":
            return ["Just listening. Nothing demanding a strong response yet.",
                    "Passive. There's input but I'm waiting for it to tell me something.",
                    "Listening. The signal is there but it hasn't asked me to move."].randomElement()!
        default:
            return nil
        }
    }

    private static func withThought(_ visual: VisualOut, _ thought: String, thoughtLog: [String]? = nil) -> VisualOut {
        let newLog = thoughtLog ?? visual.thoughtLog
        guard thought != visual.thought || newLog != visual.thoughtLog else { return visual }
        return VisualOut(
            sceneId: visual.sceneId,
            density: visual.density,
            cohesion: visual.cohesion,
            disruption: visual.disruption,
            tokenSalience: visual.tokenSalience,
            wordmarkIntegrity: visual.wordmarkIntegrity,
            decayMs: visual.decayMs,
            flashBias: visual.flashBias,
            anchorWeights: visual.anchorWeights,
            thought: thought,
            thoughtLog: newLog
        )
    }

    private static func buildNewChanges(
        previous: VideoStageSnapshot?,
        params: [StageParamState],
        picks: [StagePickState],
        visual: VisualOut,
        now: Date
    ) -> [StageChangeEvent] {
        guard let previous else { return [] }

        var changes: [StageChangeEvent] = []
        let previousParams = Dictionary(uniqueKeysWithValues: previous.params.map { ($0.id, $0) })
        for param in params {
            guard let prior = previousParams[param.id] else { continue }
            let valueChanged = abs(param.normalizedValue - prior.normalizedValue) >= paramChangeThreshold || param.valueToken != prior.valueToken
            let rawChanged = param.rawNormalizedValue != prior.rawNormalizedValue
            guard valueChanged || rawChanged else { continue }
            changes.append(
                StageChangeEvent(
                    id: "param-\(param.id)-\(now.timeIntervalSince1970)",
                    kind: .param,
                    token: param.token,
                    resolvedToken: param.valueToken,
                    rawToken: nil,
                    changedByHarness: param.changedByHarness,
                    startedAt: now
                )
            )
        }

        let previousPicks = Dictionary(uniqueKeysWithValues: previous.picks.map { ($0.id, $0) })
        for pick in picks {
            guard let prior = previousPicks[pick.id] else { continue }
            guard prior.resolvedToken != pick.resolvedToken || prior.rawToken != pick.rawToken else { continue }
            changes.append(
                StageChangeEvent(
                    id: "pick-\(pick.id)-\(now.timeIntervalSince1970)",
                    kind: .pick,
                    token: pick.token,
                    resolvedToken: pick.resolvedToken,
                    rawToken: pick.rawToken,
                    changedByHarness: pick.changedByHarness,
                    startedAt: now
                )
            )
        }

        if previous.visual.sceneId != visual.sceneId {
            changes.append(
                StageChangeEvent(
                    id: "visual-scene-\(now.timeIntervalSince1970)",
                    kind: .visual,
                    token: "scene_id",
                    resolvedToken: visual.sceneId,
                    rawToken: previous.visual.sceneId,
                    changedByHarness: false,
                    startedAt: now
                )
            )
        }

        return changes
    }

    private static func seedVisualChanges(visual: VisualOut, previous: VideoStageSnapshot?, now: Date) -> [StageChangeEvent] {
        guard previous == nil else { return [] }
        return [
            StageChangeEvent(
                id: "visual-seed-\(now.timeIntervalSince1970)",
                kind: .visual,
                token: "scene_id",
                resolvedToken: visual.sceneId,
                rawToken: nil,
                changedByHarness: false,
                startedAt: now
            )
        ]
    }

    private static func buildThoughtSprites(
        previous: VideoStageSnapshot?,
        mode: Int,
        params: [StageParamState],
        picks: [StagePickState],
        changes: [StageChangeEvent],
        profile: ModeVisualProfile,
        sceneProfile: StageSceneProfile,
        visual: VisualOut,
        stageAudio: StageAudioSnapshot,
        now: Date
    ) -> [StageThoughtSprite] {
        var sprites = (previous?.sprites ?? []).filter { $0.mode == mode && $0.isAlive(at: now) }
        let shouldSeed = previous?.mode != mode || previous?.isRunning != true || previous?.isWaiting == true

        if shouldSeed {
            for (index, pick) in picks.prefix(5).enumerated() {
                sprites.append(makeControlSprite(token: "\(pick.token)=\(pick.resolvedToken)", detail: pick.rawToken.map { "ml:\($0)" }, archetype: .controlToken, accent: pick.changedByHarness ? .warning : .active, mode: mode, profile: profile, sceneProfile: sceneProfile, visual: visual, now: now, seedHint: "seed-pick-\(index)"))
            }
            for (index, param) in params.prefix(6).enumerated() {
                sprites.append(makeControlSprite(token: "\(param.token)=\(param.valueToken)", detail: nil, archetype: .controlToken, accent: param.changedByHarness ? .warning : .signal, mode: mode, profile: profile, sceneProfile: sceneProfile, visual: visual, now: now, seedHint: "seed-param-\(index)"))
            }
        }

        for change in changes {
            let archetype: StageModuleArchetype = change.kind == .visual ? .decisionBurst : (change.changedByHarness ? .deltaEcho : .decisionBurst)
            let accent: StageAccentRole = change.kind == .visual ? .active : (change.changedByHarness ? .warning : .signal)
            sprites.append(makeChangeSprite(change: change, archetype: archetype, accent: accent, mode: mode, profile: profile, sceneProfile: sceneProfile, visual: visual, now: now))
        }

        sprites.append(contentsOf: makeAudioDebrisSprites(mode: mode, profile: profile, sceneProfile: sceneProfile, visual: visual, stageAudio: stageAudio, now: now))
        sprites.append(contentsOf: makeMemoryGhostSprites(previous: previous, mode: mode, profile: profile, sceneProfile: sceneProfile, visual: visual, now: now))

        return Array(sprites.suffix(maxSpriteCount))
    }

    private static func makeControlSprite(
        token: String,
        detail: String?,
        archetype: StageModuleArchetype,
        accent: StageAccentRole,
        mode: Int,
        profile: ModeVisualProfile,
        sceneProfile: StageSceneProfile,
        visual: VisualOut,
        now: Date,
        seedHint: String
    ) -> StageThoughtSprite {
        let seed = stableSeed("control|\(mode)|\(seedHint)|\(token)|\(Int(now.timeIntervalSince1970 * 1000))")
        let prng = StagePRNG(seed: seed)
        let placement = spritePlacement(profile: profile, visual: visual, prng: prng, spread: 0.54 + sceneProfile.tokenScatter * 0.18)
        return StageThoughtSprite(
            id: "\(archetype.rawValue)-\(seed)",
            mode: mode,
            archetype: archetype,
            token: token.uppercased(),
            detail: detail?.uppercased(),
            accentRole: accent,
            secondaryRole: accent == .warning ? .signal : .dim,
            origin: placement.origin,
            drift: placement.drift,
            rotationDegrees: (prng.value(at: 6) - 0.5) * 14,
            createdAt: now,
            delay: prng.value(at: 7) * 0.14,
            fadeInDuration: 0.08 + prng.value(at: 8) * 0.14,
            holdDuration: 0.44 + Double(visual.tokenSalience) * 0.90,
            fadeOutDuration: Double(visual.decayMs) / 1_000.0,
            blurRadius: 2.0 + prng.value(at: 11) * 3.6,
            scale: 0.92 + prng.value(at: 12) * 0.22
        )
    }

    private static func makeChangeSprite(
        change: StageChangeEvent,
        archetype: StageModuleArchetype,
        accent: StageAccentRole,
        mode: Int,
        profile: ModeVisualProfile,
        sceneProfile: StageSceneProfile,
        visual: VisualOut,
        now: Date
    ) -> StageThoughtSprite {
        let detail = change.rawToken.map { "ml:\($0)" }
        return makeControlSprite(
            token: "\(change.token)=\(change.resolvedToken)",
            detail: detail,
            archetype: archetype,
            accent: accent,
            mode: mode,
            profile: profile,
            sceneProfile: sceneProfile,
            visual: visual,
            now: now,
            seedHint: change.id
        )
    }

    private static func makeAudioDebrisSprites(
        mode: Int,
        profile: ModeVisualProfile,
        sceneProfile: StageSceneProfile,
        visual: VisualOut,
        stageAudio: StageAudioSnapshot,
        now: Date
    ) -> [StageThoughtSprite] {
        let activity = max(stageAudio.transientFlux, stageAudio.rms, stageAudio.highBand, stageAudio.overloadPulse)
        guard activity > 0.08 else { return [] }
        let count = min(4, 1 + Int((activity + stageAudio.brightness + visual.disruption) * 2.6))
        let channelEnergy = stageAudio.channelEnergy
        return (0..<count).map { index in
            let seed = stableSeed("audio-debris|\(mode)|\(index)|\(Int(now.timeIntervalSince1970 * 100))")
            let prng = StagePRNG(seed: seed)
            let energyIndex = channelEnergy.isEmpty ? 0 : min(index, channelEnergy.count - 1)
            let locusBias = channelEnergy.isEmpty ? 0.0 : channelEnergy[energyIndex]
            let placement = spritePlacement(profile: profile, visual: visual, prng: prng, spread: 0.72)
            return StageThoughtSprite(
                id: "audio-debris-\(seed)",
                mode: mode,
                archetype: .audioDebris,
                token: audioDebrisToken(stageAudio: stageAudio, index: index),
                detail: locusBias > 0.01 ? String(format: "ch%02d %.2f", energyIndex + 1, locusBias).uppercased() : nil,
                accentRole: stageAudio.overloadPulse > 0.4 ? .alert : .active,
                secondaryRole: .dim,
                origin: placement.origin,
                drift: CGSize(width: placement.drift.width * (1.2 + activity), height: placement.drift.height * (1.4 + sceneProfile.tokenDrift)),
                rotationDegrees: (prng.value(at: 4) - 0.5) * 36,
                createdAt: now,
                delay: 0,
                fadeInDuration: 0.05,
                holdDuration: 0.16 + activity * 0.20,
                fadeOutDuration: 0.36 + visual.disruption * 0.40,
                blurRadius: 4.0 + activity * 8.0,
                scale: 0.86 + activity * 0.40
            )
        }
    }

    private static func makeMemoryGhostSprites(
        previous: VideoStageSnapshot?,
        mode: Int,
        profile: ModeVisualProfile,
        sceneProfile: StageSceneProfile,
        visual: VisualOut,
        now: Date
    ) -> [StageThoughtSprite] {
        guard let previous else { return [] }
        let recent = previous.changes.filter { now.timeIntervalSince($0.startedAt) < 0.9 }
        guard !recent.isEmpty else { return [] }
        return recent.prefix(2).enumerated().map { index, change in
            makeControlSprite(
                token: "\(change.token)=\(change.resolvedToken)",
                detail: change.rawToken.map { "ml:\($0)" },
                archetype: .memoryGhost,
                accent: .dim,
                mode: mode,
                profile: profile,
                sceneProfile: sceneProfile,
                visual: visual,
                now: now,
                seedHint: "memory-\(index)-\(change.id)"
            )
        }
    }

    private static func audioDebrisToken(stageAudio: StageAudioSnapshot, index: Int) -> String {
        let tokens = [
            String(format: "rms %.2f", stageAudio.rms),
            String(format: "flux %.2f", stageAudio.transientFlux),
            String(format: "bright %.2f", stageAudio.brightness),
            String(format: "zc %.2f", stageAudio.zeroCrossDensity),
            String(format: "peak %.2f", stageAudio.peak),
            String(format: "clip %.2f", stageAudio.overloadPulse),
        ]
        return tokens[index % tokens.count].uppercased()
    }

    private static func spritePlacement(profile: ModeVisualProfile, visual: VisualOut, prng: StagePRNG, spread: Double) -> (origin: CGPoint, drift: CGSize) {
        let anchors = profile.anchors.isEmpty ? [CGPoint(x: 0.5, y: 0.5)] : profile.anchors
        let weights = visual.anchorWeights.count == anchors.count ? visual.anchorWeights : [0.34, 0.33, 0.33]
        let anchor = weightedAnchor(anchors: anchors, weights: weights, prng: prng)
        let x = clamp(anchor.x + (prng.value(at: 3) - 0.5) * spread, min: 0.06, max: 0.94)
        let y = clamp(anchor.y + (prng.value(at: 4) - 0.5) * spread, min: 0.08, max: 0.92)
        let dx = ((prng.value(at: 5) - 0.5) * (0.08 + profile.fractureVector.width))
        let dy = ((prng.value(at: 6) - 0.5) * (0.10 + profile.fractureVector.height + 0.10))
        return (CGPoint(x: x, y: y), CGSize(width: dx, height: dy))
    }

    private static func weightedAnchor(anchors: [CGPoint], weights: [Double], prng: StagePRNG) -> CGPoint {
        let t = prng.value(at: 0)
        var accum = 0.0
        for (index, anchor) in anchors.enumerated() {
            let weight = index < weights.count ? max(0.0, weights[index]) : 0.0
            accum += weight
            if t <= accum {
                return anchor
            }
        }
        return anchors.last ?? CGPoint(x: 0.5, y: 0.5)
    }

    private static func stageToken(for key: String) -> String {
        key.uppercased()
    }

    private static func stageValueToken(key: String, value: Double, bounds: ModeContract.Bounds) -> String {
        switch key {
        case _ where key.hasSuffix("_hz"):
            return String(format: "%.2fHZ", value)
        case _ where key.hasSuffix("_ms"):
            return String(format: "%.0fMS", value)
        case _ where key.hasSuffix("_s"):
            return String(format: "%.2fS", value)
        case _ where key.hasSuffix("_db"):
            return String(format: "%+.1fDB", value)
        case _ where key.hasSuffix("_cents"):
            return String(format: "%.0fCT", value)
        case _ where key.hasSuffix("_bits"):
            return String(format: "%.0fBIT", value)
        case "voice_cap", "particle_voice_cap", "variant_seed":
            return String(format: "%.0f", value)
        default:
            if bounds.0 >= 0.0, bounds.1 <= 1.0 {
                return String(format: "%.2f", value)
            }
            return String(format: "%.2f", value)
        }
    }

    private static func pickValue(for key: String, picks: Picks) -> String? {
        switch key {
        case "preset_id": return picks.presetId
        case "bank_id": return picks.bankId
        case "sample_id": return picks.sampleId
        case "midi_inst_id": return picks.midiInstId
        case "chord_set_id": return picks.chordSetId
        case "motif_id": return picks.motifId
        case "articulation_id": return picks.articulationId
        case "spatial_pattern_id": return picks.spatialPatternId
        case "scene_id": return picks.sceneId
        case "repeat_style_id": return picks.repeatStyleId
        case "grid_div": return picks.gridDiv
        case "category_id": return picks.categoryId
        case "gesture_type_id": return picks.gestureTypeId
        case "mapping_id": return picks.mappingId
        case "mapping_family": return picks.mappingFamily
        case "variance_amt": return picks.varianceAmt.map { String(format: "%.2f", $0) }
        case "variant_seed": return picks.variantSeed.map(String.init)
        default: return nil
        }
    }

    private static func resolveJoltBeganAt(isJoltHeld: Bool, previous: VideoStageSnapshot?, now: Date) -> Date? {
        guard isJoltHeld else { return nil }
        if previous?.joltHeld == true, let prior = previous?.joltBeganAt {
            return prior
        }
        return now
    }

    private static func resolveJoltSeed(isJoltHeld: Bool, previous: VideoStageSnapshot?, now: Date, mode: Int) -> UInt64 {
        if isJoltHeld, previous?.joltHeld == true {
            return previous?.joltSeed ?? seed(from: now, mode: mode)
        }
        if isJoltHeld {
            return seed(from: now, mode: mode)
        }
        return previous?.joltSeed ?? 0
    }

    private static func seed(from now: Date, mode: Int) -> UInt64 {
        let millis = UInt64(max(0, Int64(now.timeIntervalSince1970 * 1000)))
        return millis ^ UInt64((mode + 1) * 0x9E37)
    }

    private static func stableSeed(_ text: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private static func clamp(_ value: Double, min lo: Double = 0, max hi: Double = 1) -> Double {
        Swift.max(lo, Swift.min(hi, value))
    }
}

@MainActor
final class VideoStageStore: ObservableObject {
    @Published private(set) var snapshot: VideoStageSnapshot = .standby(for: 0)

    private var currentMode: Int = 0
    private var context: ModelMonitorContext?
    private var isRunning: Bool = false
    private var isJoltHeld: Bool = false
    private var stageAudio: StageAudioSnapshot = .standby
    private var boundClientID: ObjectIdentifier?
    private var boundAnalyzerID: ObjectIdentifier?
    private var cancellables: Set<AnyCancellable> = []
    private var analyzerCancellables: Set<AnyCancellable> = []
    private var speechCancellable: AnyCancellable?
    private let modeEngine = ModeEngine()
    private var latestSpeechTranscription: String?
    private var latestSpeechTimestamp: Date?
    private var audienceInfluence: AudienceInfluenceTelemetry?
    private var softLinkEvents: [SoftLinkEvent] = []
    private var softLinkListeningSprite: StageThoughtSprite?

    func bind(client: TubMLClient) {
        let objectID = ObjectIdentifier(client)
        guard objectID != boundClientID else { return }
        boundClientID = objectID
        cancellables.removeAll()
        context = client.lastMonitorContext
        isRunning = client.isRunning
        isJoltHeld = client.isJoltHeld

        client.$lastMonitorContext
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.context = $0
                self?.rebuildSnapshot()
            }
            .store(in: &cancellables)

        client.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.isRunning = $0
                self?.rebuildSnapshot()
            }
            .store(in: &cancellables)

        client.$isJoltHeld
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.isJoltHeld = $0
                self?.rebuildSnapshot()
            }
            .store(in: &cancellables)

        rebuildSnapshot()
    }

    func bind(analyzer: AudioInputAnalyzer) {
        let objectID = ObjectIdentifier(analyzer)
        guard objectID != boundAnalyzerID else { return }
        boundAnalyzerID = objectID
        analyzerCancellables.removeAll()

        analyzer.$inputStatus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status != .running {
                    self.stageAudio = .standby
                    self.rebuildSnapshot()
                }
            }
            .store(in: &analyzerCancellables)
    }

    func bind(speechTranscriber: SpeechTranscriber) {
        speechCancellable = speechTranscriber.$latestTranscription
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.latestSpeechTranscription = text
                self?.latestSpeechTimestamp = text?.isEmpty == false ? Date() : nil
                self?.rebuildSnapshot()
            }
    }

    func setMode(_ mode: Int) {
        currentMode = max(0, min(10, mode))
        rebuildSnapshot()
    }

    func ingestStageAudioSnapshot(_ snapshot: StageAudioSnapshot) {
        guard snapshot.materiallyDiffers(from: stageAudio) else { return }
        stageAudio = snapshot
        rebuildSnapshot()
    }

    func ingestAudienceInfluenceTelemetry(_ telemetry: AudienceInfluenceTelemetry?) {
        guard audienceInfluence != telemetry else { return }
        audienceInfluence = telemetry
        rebuildSnapshot()
    }

    func ingestSoftLinkEvents(_ events: [SoftLinkEvent]) {
        softLinkEvents.append(contentsOf: events)
        rebuildSnapshot()
    }

    func testingRebuild(
        context: ModelMonitorContext?,
        mode: Int,
        isRunning: Bool,
        isJoltHeld: Bool,
        audioFeatures: Features,
        stageAudio: StageAudioSnapshot? = nil,
        now: Date
    ) {
        currentMode = max(0, min(10, mode))
        self.context = context
        self.isRunning = isRunning
        self.isJoltHeld = isJoltHeld
        self.stageAudio = stageAudio ?? .standby
        snapshot = VideoStageMapper.buildSnapshot(
            mode: currentMode,
            context: context,
            isRunning: isRunning,
            isJoltHeld: isJoltHeld,
            previous: snapshot,
            modeEngine: modeEngine,
            stageAudio: self.stageAudio,
            now: now
        )
    }

    private func rebuildSnapshot() {
        var built = VideoStageMapper.buildSnapshot(
            mode: currentMode,
            context: context,
            isRunning: isRunning,
            isJoltHeld: isJoltHeld,
            previous: snapshot,
            modeEngine: modeEngine,
            stageAudio: stageAudio,
            now: Date()
        )

        // Merge local speech transcription into thought log.
        if let speech = latestSpeechTranscription,
           !speech.isEmpty,
           let speechTimestamp = latestSpeechTimestamp,
           Date().timeIntervalSince(speechTimestamp) <= 8 {
            let sanitizedSpeech = StageTextModeration.sanitizeSpeechLine(speech)
            let speechLine = "VOICE: \(sanitizedSpeech)"
            var mergedLog = built.visual.thoughtLog.filter { !$0.hasPrefix("VOICE: ") }
            // Insert the most recent speech line at the top, cap at 5 lines.
            mergedLog.insert(speechLine, at: 0)
            if mergedLog.count > 5 { mergedLog = Array(mergedLog.prefix(5)) }
            let mergedVisual = VisualOut(
                sceneId: built.visual.sceneId,
                density: built.visual.density,
                cohesion: built.visual.cohesion,
                disruption: built.visual.disruption,
                tokenSalience: built.visual.tokenSalience,
                wordmarkIntegrity: built.visual.wordmarkIntegrity,
                decayMs: built.visual.decayMs,
                flashBias: built.visual.flashBias,
                anchorWeights: built.visual.anchorWeights,
                thought: built.visual.thought,
                thoughtLog: mergedLog
            )
            built = VideoStageSnapshot(
                mode: built.mode,
                isRunning: built.isRunning,
                isWaiting: built.isWaiting,
                waitingReason: built.waitingReason,
                latencyMs: built.latencyMs,
                updatedAt: built.updatedAt,
                wordmark: built.wordmark,
                sceneProfile: built.sceneProfile,
                visualProfile: built.visualProfile,
                params: built.params,
                picks: built.picks,
                changes: built.changes,
                sprites: built.sprites,
                hasAdjustments: built.hasAdjustments,
                joltHeld: built.joltHeld,
                joltBeganAt: built.joltBeganAt,
                joltSeed: built.joltSeed,
                stageAudio: built.stageAudio,
                visual: mergedVisual,
                thoughtChangedAt: built.thoughtChangedAt,
                thoughtLogComposedAt: built.thoughtLogComposedAt,
                monitorSnapshot: built.monitorSnapshot
            )
        }

        if let influence = audienceInfluence {
            let age = Date().timeIntervalSince(influence.timestamp)
            if age <= 8 {
                let audienceLine = influence.stageLine
                var mergedLog = built.visual.thoughtLog.filter { !$0.hasPrefix("AUDIENCE ") }
                mergedLog.insert(audienceLine, at: 0)
                if mergedLog.count > 5 { mergedLog = Array(mergedLog.prefix(5)) }

                let mergedVisual = VisualOut(
                    sceneId: built.visual.sceneId,
                    density: built.visual.density,
                    cohesion: built.visual.cohesion,
                    disruption: built.visual.disruption,
                    tokenSalience: built.visual.tokenSalience,
                    wordmarkIntegrity: built.visual.wordmarkIntegrity,
                    decayMs: built.visual.decayMs,
                    flashBias: built.visual.flashBias,
                    anchorWeights: built.visual.anchorWeights,
                    thought: built.visual.thought,
                    thoughtLog: mergedLog
                )
                built = VideoStageSnapshot(
                    mode: built.mode,
                    isRunning: built.isRunning,
                    isWaiting: built.isWaiting,
                    waitingReason: built.waitingReason,
                    latencyMs: built.latencyMs,
                    updatedAt: built.updatedAt,
                    wordmark: built.wordmark,
                    sceneProfile: built.sceneProfile,
                    visualProfile: built.visualProfile,
                    params: built.params,
                    picks: built.picks,
                    changes: built.changes,
                    sprites: built.sprites,
                    hasAdjustments: built.hasAdjustments,
                    joltHeld: built.joltHeld,
                    joltBeganAt: built.joltBeganAt,
                    joltSeed: built.joltSeed,
                    stageAudio: built.stageAudio,
                    visual: mergedVisual,
                    thoughtChangedAt: built.thoughtChangedAt,
                    thoughtLogComposedAt: built.thoughtLogComposedAt,
                    monitorSnapshot: built.monitorSnapshot
                )
            }
        }

        let sanitizedVisual = StageTextModeration.sanitizeVisual(built.visual)
        if sanitizedVisual != built.visual {
            built = VideoStageSnapshot(
                mode: built.mode,
                isRunning: built.isRunning,
                isWaiting: built.isWaiting,
                waitingReason: built.waitingReason,
                latencyMs: built.latencyMs,
                updatedAt: built.updatedAt,
                wordmark: built.wordmark,
                sceneProfile: built.sceneProfile,
                visualProfile: built.visualProfile,
                params: built.params,
                picks: built.picks,
                changes: built.changes,
                sprites: built.sprites,
                hasAdjustments: built.hasAdjustments,
                joltHeld: built.joltHeld,
                joltBeganAt: built.joltBeganAt,
                joltSeed: built.joltSeed,
                stageAudio: built.stageAudio,
                visual: sanitizedVisual,
                thoughtChangedAt: built.thoughtChangedAt,
                thoughtLogComposedAt: built.thoughtLogComposedAt,
                monitorSnapshot: built.monitorSnapshot
            )
        }

        // Inject soft-link sprites (pairing mode, channel linked/unlinked).
        let softLinkSprites = buildSoftLinkSprites(mode: built.mode, now: Date())
        if !softLinkSprites.isEmpty {
            built = VideoStageSnapshot(
                mode: built.mode,
                isRunning: built.isRunning,
                isWaiting: built.isWaiting,
                waitingReason: built.waitingReason,
                latencyMs: built.latencyMs,
                updatedAt: built.updatedAt,
                wordmark: built.wordmark,
                sceneProfile: built.sceneProfile,
                visualProfile: built.visualProfile,
                params: built.params,
                picks: built.picks,
                changes: built.changes,
                sprites: built.sprites + softLinkSprites,
                hasAdjustments: built.hasAdjustments,
                joltHeld: built.joltHeld,
                joltBeganAt: built.joltBeganAt,
                joltSeed: built.joltSeed,
                stageAudio: built.stageAudio,
                visual: built.visual,
                thoughtChangedAt: built.thoughtChangedAt,
                thoughtLogComposedAt: built.thoughtLogComposedAt,
                monitorSnapshot: built.monitorSnapshot
            )
        }

        snapshot = built
    }

    private func buildSoftLinkSprites(mode: Int, now: Date) -> [StageThoughtSprite] {
        var sprites: [StageThoughtSprite] = []

        for event in softLinkEvents {
            let token: String
            let accent: StageAccentRole
            let holdDuration: TimeInterval

            switch event.action {
            case .pairingStarted:
                token = "PAIRING MODE"
                accent = .signal
                holdDuration = 12.0
                let sprite = StageThoughtSprite(
                    id: "soft-link-listening",
                    mode: mode,
                    archetype: .linkSignal,
                    token: token,
                    detail: "awaiting channel signal",
                    accentRole: accent,
                    secondaryRole: .dim,
                    origin: CGPoint(x: 0.5, y: 0.18),
                    drift: .zero,
                    rotationDegrees: 0,
                    createdAt: now,
                    delay: 0,
                    fadeInDuration: 0.2,
                    holdDuration: holdDuration,
                    fadeOutDuration: 0.5,
                    blurRadius: 0,
                    scale: 1.2
                )
                softLinkListeningSprite = sprite
                sprites.append(sprite)
                continue

            case .pairingCancelled, .pairingTimedOut:
                softLinkListeningSprite = nil
                token = event.action == .pairingCancelled ? "PAIRING CANCELLED" : "PAIRING TIMEOUT"
                accent = .dim
                holdDuration = 1.5

            case .channelLinked:
                token = "CH\(event.channelIndex + 1) LINKED"
                accent = .active
                holdDuration = 2.5

            case .channelUnlinked:
                token = "CH\(event.channelIndex + 1) UNLINKED"
                accent = .warning
                holdDuration = 2.0
            }

            sprites.append(StageThoughtSprite(
                id: "soft-link-\(event.id)",
                mode: mode,
                archetype: .linkSignal,
                token: token,
                detail: nil,
                accentRole: accent,
                secondaryRole: .dim,
                origin: CGPoint(x: 0.5, y: 0.24),
                drift: CGSize(width: 0, height: -0.02),
                rotationDegrees: 0,
                createdAt: now,
                delay: 0,
                fadeInDuration: 0.15,
                holdDuration: holdDuration,
                fadeOutDuration: 0.8,
                blurRadius: 0,
                scale: 1.1
            ))
        }
        softLinkEvents.removeAll()

        // Keep the persistent listening sprite alive while in pairing mode.
        if let listening = softLinkListeningSprite, listening.isAlive(at: now), sprites.isEmpty {
            sprites.append(listening)
        } else if let listening = softLinkListeningSprite, !listening.isAlive(at: now) {
            softLinkListeningSprite = nil
        }

        return sprites
    }
}
struct StageDisplayReference: Codable, Equatable {
    var displayID: UInt32?
    var localizedName: String
    var frameSignature: String
}

struct VideoOutputPreferences: Codable, Equatable {
    var isPreviewEnabled: Bool
    var selectedDisplay: StageDisplayReference?

    static let `default` = VideoOutputPreferences(isPreviewEnabled: false, selectedDisplay: nil)
}

struct StageDisplayInfo: Identifiable, Equatable {
    let id: String
    let reference: StageDisplayReference
    let title: String
    let isMain: Bool
    let frame: CGRect
    let visibleFrame: CGRect

    init(screen: NSScreen) {
        let reference = StageDisplayReference(
            displayID: screen.displayID,
            localizedName: screen.localizedName,
            frameSignature: screen.frame.stageFrameSignature
        )
        self.reference = reference
        self.id = reference.persistedKey
        self.title = screen.localizedName + (screen == NSScreen.main ? " • Main" : "")
        self.isMain = screen == NSScreen.main
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
    }

    func matches(_ target: StageDisplayReference) -> Bool {
        if let lhs = reference.displayID, let rhs = target.displayID, lhs == rhs {
            return true
        }
        return reference.localizedName == target.localizedName && reference.frameSignature == target.frameSignature
    }
}

extension StageDisplayReference {
    var persistedKey: String {
        if let displayID {
            return "display_\(displayID)"
        }
        return "display_\(localizedName)_\(frameSignature)"
    }
}

private extension CGRect {
    var stageFrameSignature: String {
        "\(Int(origin.x))x\(Int(origin.y))_\(Int(width))x\(Int(height))"
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { $0.uint32Value }
    }
}

enum VideoOutputStatus: Equatable {
    case hidden
    case previewing(String)
    case presenting(String)
    case fallback(String)
    case missingDisplay(String)

    var label: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .previewing:
            return "Preview"
        case .presenting:
            return "Presenting"
        case .fallback:
            return "Fallback"
        case .missingDisplay:
            return "Missing Display"
        }
    }

    var detail: String {
        switch self {
        case .hidden:
            return "No stage window"
        case .previewing(let name), .presenting(let name), .fallback(let name), .missingDisplay(let name):
            return name
        }
    }
}

@MainActor
final class VideoOutputController: ObservableObject {
    @Published private(set) var displays: [StageDisplayInfo] = []
    @Published private(set) var isPreviewEnabled: Bool = false
    @Published private(set) var isPresenting: Bool = false
    @Published private(set) var status: VideoOutputStatus = .hidden
    @Published private(set) var warningText: String?
    @Published private(set) var selectedDisplayTitle: String = "Main Display"
    @Published private(set) var selectedDisplayID: String?

    private let appName = "TheTubHarness"
    private let persistenceFilename = "video_output.json"
    private var preferences: VideoOutputPreferences = .default
    private weak var store: VideoStageStore?
    private var webcamPool: USGSWebcamPool?
    private var videoClipPool: JoltVideoClipPool?
    private var previewWindow: StagePreviewWindow?
    private var presentationWindow: StagePresentationWindow?
    private var screenObserver: NSObjectProtocol?

    init() {
        loadPreferences()
        installScreenObserver()
        refreshDisplays()
        isPreviewEnabled = preferences.isPreviewEnabled
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func bind(store: VideoStageStore) {
        self.store = store
        refreshDisplays()
        if preferences.isPreviewEnabled {
            presentPreviewWindow(reveal: false)
        }
    }

    func bind(webcamPool: USGSWebcamPool) {
        self.webcamPool = webcamPool
    }

    func bind(videoClipPool: JoltVideoClipPool) {
        self.videoClipPool = videoClipPool
    }

    func setPreviewEnabled(_ enabled: Bool) {
        preferences.isPreviewEnabled = enabled
        isPreviewEnabled = enabled
        persistPreferences()
        if enabled {
            presentPreviewWindow(reveal: true)
        } else {
            closePreviewWindow()
        }
        updatePresentationStatus()
    }

    func revealPreviewWindow() {
        if !preferences.isPreviewEnabled {
            setPreviewEnabled(true)
            return
        }
        presentPreviewWindow(reveal: true)
    }

    func setPresentationEnabled(_ enabled: Bool) {
        isPresenting = enabled
        if enabled {
            presentPresentationWindow(reveal: true)
        } else {
            closePresentationWindow()
        }
        updatePresentationStatus()
    }

    func selectDisplay(_ displayID: String) {
        guard let match = displays.first(where: { $0.id == displayID }) else { return }
        preferences.selectedDisplay = match.reference
        persistPreferences()
        refreshDisplays()
        if preferences.isPreviewEnabled {
            presentPreviewWindow(reveal: true)
        }
        if isPresenting {
            presentPresentationWindow(reveal: true)
        }
    }

    func refreshDisplays() {
        displays = NSScreen.screens.map(StageDisplayInfo.init)
        let resolved = resolvedPreferredDisplay()
        selectedDisplayTitle = resolved?.title ?? displays.first?.title ?? "Main Display"
        selectedDisplayID = resolved?.id
        updatePresentationStatus()
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDisplays()
                if self.preferences.isPreviewEnabled {
                    self.presentPreviewWindow(reveal: false)
                }
                if self.isPresenting {
                    self.presentPresentationWindow(reveal: false)
                }
            }
        }
    }

    private func resolvedPreferredDisplay() -> StageDisplayInfo? {
        if let target = preferences.selectedDisplay {
            return displays.first(where: { $0.matches(target) })
        }
        return displays.first(where: { $0.isMain }) ?? displays.first
    }

    private func fallbackDisplay() -> StageDisplayInfo? {
        displays.first(where: { $0.isMain }) ?? displays.first
    }

    private func presentPreviewWindow(reveal: Bool) {
        guard let store else { return }
        guard let resolved = resolveDisplayTarget() else {
            status = .missingDisplay(preferences.selectedDisplay?.localizedName ?? "No display")
            warningText = "No usable display is available for the preview window."
            return
        }

        let window = previewWindow ?? StagePreviewWindow()
        if previewWindow == nil {
            window.title = "The Tub Stage Preview"
            window.contentView = NSHostingView(rootView: StageOutputView(store: store, webcamPool: webcamPool, videoClipPool: videoClipPool))
            window.onClosed = { [weak self] in
                guard let self else { return }
                self.preferences.isPreviewEnabled = false
                self.isPreviewEnabled = false
                self.previewWindow = nil
                self.persistPreferences()
                self.updatePresentationStatus()
            }
            previewWindow = window
        }

        window.setFrame(centeredPreviewFrame(in: resolved.screen.visibleFrame), display: true)
        if reveal {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }

        switch resolved.kind {
        case .preferred:
            warningText = nil
        case .fallback:
            warningText = "Saved stage display is unavailable. Preview is showing on \(resolved.screen.title)."
        }
    }

    private func presentPresentationWindow(reveal: Bool) {
        guard let store else { return }
        guard let resolved = resolveDisplayTarget() else {
            status = .missingDisplay(preferences.selectedDisplay?.localizedName ?? "No display")
            warningText = "No usable display is available for stage presentation."
            isPresenting = false
            return
        }

        let window = presentationWindow ?? StagePresentationWindow()
        if presentationWindow == nil {
            window.contentView = NSHostingView(rootView: StageOutputView(store: store, webcamPool: webcamPool, videoClipPool: videoClipPool))
            presentationWindow = window
        }

        window.setFrame(resolved.screen.frame, display: true)
        window.setFrameOrigin(resolved.screen.frame.origin)
        window.orderFrontRegardless()
        if reveal {
            NSApp.activate(ignoringOtherApps: true)
        }

        switch resolved.kind {
        case .preferred:
            if !preferences.isPreviewEnabled {
                warningText = nil
            }
        case .fallback:
            warningText = "Saved stage display is unavailable. Presentation is showing on \(resolved.screen.title)."
        }
    }

    private func updatePresentationStatus() {
        if isPresenting {
            if let resolved = resolveDisplayTarget() {
                switch resolved.kind {
                case .preferred:
                    status = .presenting(resolved.screen.title)
                    if !preferences.isPreviewEnabled {
                        warningText = nil
                    }
                case .fallback:
                    status = .fallback(resolved.screen.title)
                    warningText = "Saved stage display is unavailable. Presentation is showing on \(resolved.screen.title)."
                }
            } else {
                status = .missingDisplay(preferences.selectedDisplay?.localizedName ?? "No display")
                warningText = "No usable display is available for stage presentation."
            }
            return
        }

        if preferences.isPreviewEnabled {
            if let resolved = resolveDisplayTarget() {
                switch resolved.kind {
                case .preferred:
                    status = .previewing(resolved.screen.title)
                    warningText = nil
                case .fallback:
                    status = .fallback(resolved.screen.title)
                    warningText = "Saved stage display is unavailable. Preview is showing on \(resolved.screen.title)."
                }
            } else {
                status = .missingDisplay(preferences.selectedDisplay?.localizedName ?? "No display")
                warningText = "No usable display is available for the preview window."
            }
            return
        }

        warningText = nil
        status = .hidden
    }

    private func closePreviewWindow() {
        previewWindow?.orderOut(nil)
        previewWindow?.close()
        previewWindow = nil
        if !isPresenting {
            warningText = nil
        }
    }

    private func closePresentationWindow() {
        presentationWindow?.orderOut(nil)
        presentationWindow?.close()
        presentationWindow = nil
    }

    private enum ResolvedDisplayKind {
        case preferred
        case fallback
    }

    private struct ResolvedDisplayTarget {
        let screen: StageDisplayInfo
        let kind: ResolvedDisplayKind
    }

    private func resolveDisplayTarget() -> ResolvedDisplayTarget? {
        if let target = preferences.selectedDisplay,
           let preferred = displays.first(where: { $0.matches(target) }) {
            return ResolvedDisplayTarget(screen: preferred, kind: .preferred)
        }
        if preferences.selectedDisplay != nil, let fallback = fallbackDisplay() {
            return ResolvedDisplayTarget(screen: fallback, kind: .fallback)
        }
        if let preferred = resolvedPreferredDisplay() {
            return ResolvedDisplayTarget(screen: preferred, kind: .preferred)
        }
        return nil
    }

    private func centeredPreviewFrame(in visibleFrame: CGRect) -> CGRect {
        let width = min(max(visibleFrame.width * 0.72, 960), 1680)
        let height = min(max(visibleFrame.height * 0.68, 620), 980)
        let x = visibleFrame.midX - (width / 2)
        let y = visibleFrame.midY - (height / 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func loadPreferences() {
        guard let url = preferencesURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VideoOutputPreferences.self, from: data) else {
            preferences = .default
            return
        }
        preferences = decoded
    }

    private func persistPreferences() {
        guard let url = preferencesURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(preferences)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort persistence only.
        }
    }

    private func preferencesURL() -> URL? {
        guard let base = try? SessionPaths.appSupportBaseDirectory(appName: appName) else { return nil }
        return base.appendingPathComponent(persistenceFilename)
    }
}

private final class StagePreviewWindow: NSWindow {
    var onClosed: (() -> Void)?

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        titleVisibility = .visible
        titlebarAppearsTransparent = true
        hasShadow = true
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override func close() {
        super.close()
        onClosed?()
    }
}

private final class StagePresentationWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .normal
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct StagePRNG {
    let seed: UInt64

    func value(at index: Int) -> Double {
        var x = seed &+ UInt64(index &* 0x9E37)
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        let scrambled = x &* 2685821657736338717
        return Double(scrambled % 10_000) / 10_000.0
    }
}

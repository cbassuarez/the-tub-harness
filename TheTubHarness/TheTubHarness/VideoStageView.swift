import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import AVFoundation

private enum JoltMedia {
    case none
    case webcamImage(CGImage)
    case video
}

struct StageOutputView: View {
    @ObservedObject var store: VideoStageStore
    var webcamPool: USGSWebcamPool?
    var videoClipPool: JoltVideoClipPool?

    @State private var flashReleaseAt: Date?
    @State private var activeJoltPlayer: AVPlayer?

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { timeline in
                let snapshot = store.snapshot
                let now = timeline.date
                let flashOpacity = currentFlashOpacity(snapshot: snapshot, now: now)
                let flashPattern = StageFlashPattern(snapshot: snapshot, now: now)

                let joltMedia: JoltMedia = {
                    guard flashOpacity > 0.001,
                          [4, 5, 6, 7].contains(snapshot.mode) else { return .none }
                    if activeJoltPlayer != nil,
                       let pool = videoClipPool,
                       pool.shouldUseVideo(seed: snapshot.joltSeed) {
                        return .video
                    }
                    if let img = webcamPool?.imageForSeed(snapshot.joltSeed) {
                        return .webcamImage(img)
                    }
                    return .none
                }()

                let showNormalFlash: Bool = {
                    if case .none = joltMedia { return flashOpacity > 0.001 }
                    return false
                }()

                ZStack {
                    // Normal stage + effects
                    ZStack {
                        StageBackdropCanvas(snapshot: snapshot, now: now, flashPattern: flashPattern, flashOpacity: flashOpacity)
                            .ignoresSafeArea()

                        if snapshot.isRunning {
                            StageTerminalLogLayer(snapshot: snapshot, now: now, canvasSize: proxy.size)
                            StageWordmarkField(snapshot: snapshot, now: now, canvasSize: proxy.size, flashOpacity: flashOpacity)
                        } else {
                            StageStandbyField(snapshot: snapshot)
                            // Show SoftLink sprites even when session isn't running.
                            if !snapshot.sprites.isEmpty {
                                StageTerminalLogLayer(snapshot: snapshot, now: now, canvasSize: proxy.size)
                            }
                        }

                        if showNormalFlash {
                            StageFlashOverlay(snapshot: snapshot, pattern: flashPattern, opacity: flashOpacity)
                                .allowsHitTesting(false)
                        }

                        // Prominent SoftLink lower-third overlay
                        if case .inactive = store.softLinkPhase {} else {
                            SoftLinkPairingOverlay(phase: store.softLinkPhase, now: now, canvasSize: proxy.size)
                        }
                    }
                    .modifier(StageJoltDistortion(
                        joltHeld: snapshot.joltHeld,
                        flashOpacity: flashOpacity,
                        joltSeed: snapshot.joltSeed,
                        now: now
                    ))
                    .modifier(StageFilmGrade(
                        canvasSize: proxy.size,
                        time: now.timeIntervalSinceReferenceDate,
                        audio: snapshot.stageAudio
                    ))

                    // Jolt media: raw image or video, outside all post-processing
                    switch joltMedia {
                    case .webcamImage(let cgImage):
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(flashOpacity)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .allowsHitTesting(false)
                    case .video:
                        if let player = activeJoltPlayer {
                            JoltVideoPlayerView(player: player)
                                .opacity(flashOpacity)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .allowsHitTesting(false)
                        }
                    case .none:
                        EmptyView()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(StageIndustrialPalette.graphite.color)
            }
        }
        .background(StageIndustrialPalette.graphite.color)
        .preferredColorScheme(.dark)
        .onChange(of: store.snapshot.joltHeld) { _, isHeld in
            if isHeld {
                flashReleaseAt = nil
                let mode = store.snapshot.mode
                let seed = store.snapshot.joltSeed
                let poolExists = videoClipPool != nil
                let hasClips = videoClipPool?.hasClips ?? false
                let shouldVideo = videoClipPool?.shouldUseVideo(seed: seed) ?? false
                print("[JoltDebug] jolt START mode=\(mode) seed=\(seed) poolExists=\(poolExists) hasClips=\(hasClips) shouldVideo=\(shouldVideo)")
                // Start video if this jolt should use video
                if [4, 5, 6, 7].contains(mode),
                   let pool = videoClipPool,
                   pool.shouldUseVideo(seed: seed),
                   let player = pool.playerForSeed(seed) {
                    activeJoltPlayer = player
                    player.play()
                    print("[JoltDebug] video player ACTIVE")
                }
            } else {
                flashReleaseAt = Date()
                // Keep playing during 300ms fade, then stop
                if let player = activeJoltPlayer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak player] in
                        player?.pause()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        activeJoltPlayer = nil
                        videoClipPool?.deactivate()
                    }
                }
            }
        }
    }

    private func currentFlashOpacity(snapshot: VideoStageSnapshot, now: Date) -> Double {
        if snapshot.joltHeld {
            return 1.0
        }
        guard let flashReleaseAt else { return 0 }
        let elapsed = now.timeIntervalSince(flashReleaseAt)
        guard elapsed >= 0, elapsed < 0.30 else { return 0 }
        let linear = 1.0 - (elapsed / 0.30)
        return linear * linear // ease-out curve
    }
}

private struct StageStandbyField: View {
    let snapshot: VideoStageSnapshot

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(snapshot.wordmark.topText)
                Text(snapshot.wordmark.bottomText)
            }
            .font(IBMPlexMonoFont.font(.bold, size: 96))
            .foregroundStyle(StageIndustrialPalette.signal.color.opacity(0.10))
            .tracking(10)
            .blur(radius: 0.8)

            Text("quiet_watch")
                .font(IBMPlexMonoFont.font(.medium, size: 13))
                .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.34))
                .tracking(2.4)
        }
    }
}

private struct StageBackdropCanvas: View {
    let snapshot: VideoStageSnapshot
    let now: Date
    let flashPattern: StageFlashPattern
    let flashOpacity: Double

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(StageIndustrialPalette.graphite.color))

            let field = StageRenderField(snapshot: snapshot, now: now)
            drawScanlines(context: &context, size: size, density: field.scanDensity)
            drawGrid(context: &context, size: size, density: field.gridDensity)
            drawTopology(context: &context, size: size, field: field)
            drawVoxelStructures(context: &context, size: size, field: field, snapshot: snapshot, now: now)
            drawJunctionBoxes(context: &context, size: size, field: field)
            drawNoise(context: &context, size: size, field: field)

            if flashOpacity > 0.001 {
                context.opacity = flashOpacity * 0.6
                context.fill(Path(rect), with: .color(flashPattern.joltColor))
            }
        }
    }

    private func drawScanlines(context: inout GraphicsContext, size: CGSize, density: CGFloat) {
        var scanlines = Path()
        let spacing = max(3, 7 - density * 3)
        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            scanlines.move(to: CGPoint(x: 0, y: y))
            scanlines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(scanlines, with: .color(StageIndustrialPalette.signal.color.opacity(0.016)), lineWidth: 0.5)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, density: CGFloat) {
        var grid = Path()
        let spacing = max(54, 104 - density * 30)
        stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(StageIndustrialPalette.slate.color.opacity(0.10)), lineWidth: 1)
    }

    private func drawTopology(context: inout GraphicsContext, size: CGSize, field: StageRenderField) {
        switch snapshot.sceneProfile.topology {
        case .gridLock:
            var path = Path()
            let centerY = size.height * 0.48
            path.move(to: CGPoint(x: size.width * 0.08, y: centerY))
            path.addLine(to: CGPoint(x: size.width * 0.92, y: centerY))
            context.stroke(path, with: .color(StageIndustrialPalette.dimSignal.color.opacity(0.26)), lineWidth: 2.4)
        case .relayMesh:
            var path = Path()
            for (index, anchor) in field.anchors.enumerated() where index > 0 {
                path.move(to: field.anchors[0])
                path.addLine(to: anchor)
            }
            context.stroke(path, with: .color(StageIndustrialPalette.active.color.opacity(0.18 + field.activity * 0.18)), lineWidth: 1.6)
        case .faultLattice:
            var path = Path()
            for anchor in field.anchors {
                path.move(to: CGPoint(x: anchor.x - 120, y: anchor.y))
                path.addLine(to: CGPoint(x: anchor.x + 120, y: anchor.y))
                path.move(to: CGPoint(x: anchor.x, y: anchor.y - 90))
                path.addLine(to: CGPoint(x: anchor.x, y: anchor.y + 90))
            }
            context.stroke(path, with: .color(StageIndustrialPalette.amber.color.opacity(0.14 + field.disruption * 0.18)), lineWidth: 2)
        case .memoryDrift:
            var path = Path()
            let t = now.timeIntervalSinceReferenceDate
            for anchor in field.anchors {
                path.move(to: anchor)
                path.addCurve(
                    to: CGPoint(x: anchor.x + sin(t * 0.7) * 120, y: anchor.y + cos(t * 0.5) * 70),
                    control1: CGPoint(x: anchor.x + 60, y: anchor.y - 90),
                    control2: CGPoint(x: anchor.x - 80, y: anchor.y + 120)
                )
            }
            context.stroke(path, with: .color(StageIndustrialPalette.signal.color.opacity(0.10 + field.activity * 0.10)), lineWidth: 1.4)
        case .alarmSplay:
            var path = Path()
            for anchor in field.anchors {
                path.move(to: CGPoint(x: 0, y: anchor.y))
                path.addLine(to: anchor)
                path.addLine(to: CGPoint(x: size.width, y: anchor.y + 24))
            }
            context.stroke(path, with: .color(StageIndustrialPalette.alert.color.opacity(0.10 + field.overload * 0.22)), lineWidth: 2.8)
        case .quietWatch:
            let radius = min(size.width, size.height) * 0.26
            let rect = CGRect(x: size.width * 0.5 - radius, y: size.height * 0.5 - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(StageIndustrialPalette.slate.color.opacity(0.18)), lineWidth: 1.6)
        }
    }

    private func drawJunctionBoxes(context: inout GraphicsContext, size: CGSize, field: StageRenderField) {
        let labels = Self.junctionLabels(mode: snapshot.mode)
        let audio = snapshot.stageAudio
        let t = now.timeIntervalSinceReferenceDate

        // Distribute params across the 3 anchors so each junction owns a slice.
        let paramSlices = Self.paramSlicesForAnchors(params: snapshot.params)
        // Track recent changes per anchor.
        let changeAge = Self.recentChangeAgePerAnchor(changes: snapshot.changes, params: snapshot.params, now: now)

        // Per-anchor audio metric: low → anchor 0, mid → anchor 1, high → anchor 2
        let bandMetrics: [Double] = [audio.lowBand, audio.midBand, audio.highBand]

        for (index, anchor) in field.anchors.enumerated() {
            let weight = field.anchorWeights.count > index ? field.anchorWeights[index] : 0.33
            let band = index < bandMetrics.count ? bandMetrics[index] : audio.rms
            let myParams = index < paramSlices.count ? paramSlices[index] : []

            // Aggregate param intensity for this junction: mean of normalized values.
            let paramIntensity: Double = myParams.isEmpty ? 0.3
                : myParams.reduce(0.0) { $0 + $1.normalizedValue } / Double(myParams.count)

            // Change flash: decays from 1.0 over ~1.5 seconds when a param in this junction changed.
            let changeFlash: Double = {
                guard let age = changeAge[index] else { return 0 }
                return max(0, 1.0 - age / 1.5)
            }()

            let ax = anchor.x * size.width
            let ay = anchor.y * size.height
            let boxW: CGFloat = 68 + weight * 22
            let boxH: CGFloat = 16 + CGFloat(max(1, myParams.count)) * 14 + 12
            let boxRect = CGRect(x: ax - boxW * 0.5, y: ay - boxH * 0.5, width: boxW, height: boxH)
            let boxPath = Path(roundedRect: boxRect, cornerRadius: 3)

            // Interior fill: base slate, brightens with band energy + change flash.
            let fillBright = 0.14 + band * 0.16 + changeFlash * 0.20 + paramIntensity * 0.06
            context.fill(boxPath, with: .color(StageIndustrialPalette.slate.color.opacity(fillBright)))

            // Change flash overlay — hot white pulse on recent change.
            if changeFlash > 0.05 {
                let flashColor = StageIndustrialPalette.active.color.opacity(changeFlash * 0.22)
                context.fill(boxPath, with: .color(flashColor))
            }

            // Border: dims when quiet, brightens with band + activity. Amber on change.
            let borderBase = changeFlash > 0.1 ? StageIndustrialPalette.amber : (index == 0 ? StageIndustrialPalette.active : StageIndustrialPalette.signal)
            let borderOpacity = 0.22 + weight * 0.18 + band * 0.28 + changeFlash * 0.25
            context.stroke(boxPath, with: .color(borderBase.color.opacity(borderOpacity)), lineWidth: 1.5 + band * 1.0 + changeFlash * 1.5)

            // LED strip: one LED per param in this junction's slice.
            let ledX = ax - boxW * 0.5 + 7
            let headerY = ay - boxH * 0.5 + 10

            // Junction header label
            let label = index < labels.count ? labels[index] : "AUX\(index)"
            let headerColor = borderBase.color.opacity(0.50 + band * 0.30 + changeFlash * 0.20)
            let labelResolved = context.resolve(
                Text(label)
                    .font(IBMPlexMonoFont.font(.bold, size: 8))
                    .foregroundStyle(headerColor)
            )
            context.draw(labelResolved, at: CGPoint(x: ledX, y: headerY), anchor: .leading)

            // Per-param rows: LED indicator + name + fill bar.
            for (pIdx, param) in myParams.enumerated() {
                let rowY = headerY + 13 + CGFloat(pIdx) * 14
                let val = param.normalizedValue
                let isChanged = param.changedByHarness

                // Per-param modulation: blend band energy with the param's own value.
                let modulation = val * 0.6 + band * 0.3 + audio.rms * 0.1

                // LED dot
                let ledRadius: CGFloat = 2.5
                let ledRect = CGRect(x: ledX - ledRadius, y: rowY - ledRadius, width: ledRadius * 2, height: ledRadius * 2)
                let ledPulse = 0.5 * (1.0 + sin(t * (2.0 + Double(index) * 0.7 + Double(pIdx) * 0.4)))
                let ledColor: Color
                if isChanged {
                    ledColor = StageIndustrialPalette.amber.color.opacity(0.60 + ledPulse * 0.40)
                } else if modulation > 0.6 {
                    ledColor = StageIndustrialPalette.active.color.opacity(0.40 + modulation * 0.55)
                } else {
                    ledColor = StageIndustrialPalette.dimSignal.color.opacity(0.18 + modulation * 0.40)
                }
                context.fill(Path(ellipseIn: ledRect), with: .color(ledColor))

                // Param name (abbreviated)
                let shortName = Self.abbreviateParam(param.token)
                let nameResolved = context.resolve(
                    Text(shortName)
                        .font(IBMPlexMonoFont.font(.regular, size: 7))
                        .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.40 + modulation * 0.35))
                )
                context.draw(nameResolved, at: CGPoint(x: ledX + 7, y: rowY), anchor: .leading)

                // Fill bar: shows normalized value, modulates width with band energy.
                let barX = ledX + 34
                let barW: CGFloat = boxW - 46
                let barH: CGFloat = 3.0
                let barRect = CGRect(x: barX, y: rowY - barH * 0.5, width: barW, height: barH)
                context.fill(Path(roundedRect: barRect, cornerRadius: 1), with: .color(StageIndustrialPalette.graphite.color.opacity(0.30)))

                // Active fill: width = param value, brightness modulates with audio.
                let fillW = barW * CGFloat(min(1.0, val + band * 0.08))
                if fillW > 0.5 {
                    let fillRect = CGRect(x: barX, y: rowY - barH * 0.5, width: fillW, height: barH)
                    let barColor = isChanged ? StageIndustrialPalette.amber : StageIndustrialPalette.active
                    context.fill(Path(roundedRect: fillRect, cornerRadius: 1), with: .color(barColor.color.opacity(0.35 + modulation * 0.50)))
                }
            }

            // Weight readout below box
            let weightText = String(format: "%02d", Int(weight * 100))
            let weightResolved = context.resolve(
                Text(weightText)
                    .font(IBMPlexMonoFont.font(.regular, size: 7))
                    .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.30 + band * 0.20))
            )
            context.draw(weightResolved, at: CGPoint(x: ax, y: ay + boxH * 0.5 + 3), anchor: .top)
        }
    }

    /// Distribute params evenly across 3 anchors.
    private static func paramSlicesForAnchors(params: [StageParamState]) -> [[StageParamState]] {
        guard !params.isEmpty else { return [[], [], []] }
        let n = params.count
        let chunkSize = max(1, (n + 2) / 3)
        return [
            Array(params.prefix(chunkSize)),
            Array(params.dropFirst(chunkSize).prefix(chunkSize)),
            Array(params.dropFirst(chunkSize * 2)),
        ]
    }

    /// Find the most recent change age for each anchor's param slice.
    private static func recentChangeAgePerAnchor(changes: [StageChangeEvent], params: [StageParamState], now: Date) -> [Int: Double] {
        let slices = paramSlicesForAnchors(params: params)
        var result: [Int: Double] = [:]
        for (anchorIdx, slice) in slices.enumerated() {
            let tokens = Set(slice.map(\.token))
            var bestAge: Double?
            for change in changes where change.kind == .param && tokens.contains(change.token) {
                let age = now.timeIntervalSince(change.startedAt)
                if bestAge == nil || age < bestAge! {
                    bestAge = age
                }
            }
            if let age = bestAge {
                result[anchorIdx] = age
            }
        }
        return result
    }

    /// Shorten param token for tight junction display.
    private static func abbreviateParam(_ token: String) -> String {
        let t = token.uppercased()
        if t.count <= 5 { return t }
        // Common abbreviations
        let map: [String: String] = [
            "LEVEL": "LVL", "DENSITY": "DENS", "BRIGHTNESS": "BRT",
            "AGGRESSION": "AGG", "STABILITY": "STAB", "WET": "WET",
            "FEEDBACK": "FDBK", "ATTACK": "ATK", "RELEASE": "REL",
            "PREDELAY": "PDLY", "PRE_DELAY": "PDLY", "CROSSFADE": "XFADE",
            "RATE": "RATE", "PITCH": "PTCH", "GRAIN_SIZE": "GRSZ",
            "NOTE_RATE": "NRAT", "VOICE_CAP": "VCAP", "DRIVE": "DRV",
            "RESONANCE": "RES", "MIX": "MIX",
        ]
        if let short = map[t] { return short }
        return String(t.prefix(4))
    }

    private static func junctionLabels(mode: Int) -> [String] {
        switch mode {
        case 0:  return ["DRY/WET", "PRE-DLY", "DECAY"]
        case 1:  return ["FRACTURE", "HOLD", "PITCH"]
        case 2:  return ["GRAIN", "SCAN", "FREEZE"]
        case 3:  return ["DRIVE", "CRUSH", "TONE"]
        case 4:  return ["SAMPLE", "GESTURE", "MIX"]
        case 5:  return ["NOTE", "VOICE", "PITCH"]
        case 6:  return ["NOTE", "VOICE", "DRY"]
        case 7:  return ["SWAP", "XFADE", "MAP"]
        case 8:  return ["RAND", "DECAY", "COLOR"]
        case 9:  return ["PARTICLE", "VOICE", "BRIGHT"]
        case 10: return ["SCENE", "CHAOS", "BLEND"]
        default: return ["IN", "PROC", "OUT"]
        }
    }

    private func drawNoise(context: inout GraphicsContext, size: CGSize, field: StageRenderField) {
        let bucket = Int(now.timeIntervalSinceReferenceDate * 6.0)
        let prng = StagePRNG(seed: UInt64(abs(bucket)) ^ snapshot.joltSeed ^ UInt64(snapshot.mode * 4099))
        let count = 18 + Int(field.activity * 22) + Int(field.brightness * 14)
        for index in 0..<count {
            let x = size.width * prng.value(at: index)
            let y = size.height * prng.value(at: index + 50)
            let length = 18 + CGFloat(prng.value(at: index + 80) * (40 + field.disruption * 70))
            let angle = (prng.value(at: index + 100) - 0.5) * Double.pi * (0.3 + field.disruption * 0.6)
            let dx = cos(angle) * length
            let dy = sin(angle) * length
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx, y: y + dy))
            let color = field.hasAdjustments && index % 6 == 0
                ? StageIndustrialPalette.amber.color.opacity(0.12)
                : StageIndustrialPalette.dimSignal.color.opacity(0.10 + field.brightness * 0.06)
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

private struct StageTerminalLogLayer: View {
    let snapshot: VideoStageSnapshot
    let now: Date
    let canvasSize: CGSize

    private static let lineHeight: CGFloat = 15
    private static let insetFrac: CGFloat = 0.04

    var body: some View {
        let audio = snapshot.stageAudio
        let t = now.timeIntervalSinceReferenceDate
        let cursorVisible = Int(floor(t * 2.5)) % 2 == 0
        let glowIntensity = max(audio.rms, audio.transientFlux * 0.8)

        ZStack {
            // LEFT: Event log — sprite stream (ML decisions, audio debris, changes)
            eventLog(cursorVisible: cursorVisible, glowIntensity: glowIntensity)

            // RIGHT: Live ML state readout — picks, params, audio meters
            liveStatePanel(audio: audio, glowIntensity: glowIntensity, t: t)

            // BOTTOM-CENTER: Scene-dominant thought text
            thoughtSceneLayer(glowIntensity: glowIntensity)
        }
    }

    // MARK: - Left panel: event log

    private func eventLog(cursorVisible: Bool, glowIntensity: Double) -> some View {
        let maxLines = Int(canvasSize.height * 0.50 / Self.lineHeight)
        let lines = snapshot.sprites.compactMap { sprite -> TerminalLogLine? in
            guard let state = TerminalLogLineState(sprite: sprite, now: now) else { return nil }
            return TerminalLogLine(sprite: sprite, state: state)
        }
        .prefix(maxLines)

        return VStack(alignment: .leading, spacing: 1) {
            // Header
            Text("── M\(snapshot.mode) \(Self.modeTag(snapshot.mode)) ──")
                .font(IBMPlexMonoFont.font(.bold, size: 10))
                .foregroundStyle(StageIndustrialPalette.active.color.opacity(0.50 + glowIntensity * 0.30))
                .shadow(color: StageIndustrialPalette.active.color.opacity(glowIntensity * 0.40), radius: 6, x: 0, y: 0)

            ForEach(Array(lines.enumerated()), id: \.element.sprite.id) { index, line in
                terminalLine(line: line, cursorVisible: cursorVisible && index == lines.count - 1, glowIntensity: glowIntensity)
            }
        }
        .frame(maxWidth: canvasSize.width * 0.46, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, canvasSize.width * Self.insetFrac)
        .padding(.top, canvasSize.height * Self.insetFrac)
    }

    private func terminalLine(line: TerminalLogLine, cursorVisible: Bool, glowIntensity: Double) -> some View {
        let sprite = line.sprite
        let state = line.state
        let tag = Self.archetypeTag(sprite.archetype)
        let timestamp = Self.formatTimestamp(sprite.createdAt)
        let fullText = "[\(timestamp)] \(tag) \(sprite.token)"
        let revealCount = state.revealedCharacters(totalLength: fullText.count)
        let revealed = String(fullText.prefix(revealCount))
        let cursor = (revealCount < fullText.count && cursorVisible) ? "▌" : ""
        let accentColor = StageIndustrialPalette.accent(for: sprite.accentRole).color
        let audioGlow = sprite.archetype == .audioDebris ? glowIntensity * 0.5 : glowIntensity * 0.15

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("[\(timestamp)] ")
                    .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(state.opacity * 0.6))
                Text(String(revealed.dropFirst(min(revealed.count, timestamp.count + 3))))
                    .foregroundStyle(accentColor.opacity(state.opacity * 0.82))
                Text(cursor)
                    .foregroundStyle(accentColor.opacity(state.opacity * 0.9))
            }
            .font(IBMPlexMonoFont.font(.regular, size: 11))
            .shadow(color: accentColor.opacity(state.opacity * (0.20 + audioGlow)), radius: 4 + audioGlow * 8, x: 0, y: 0)

            if let detail = sprite.detail, !detail.isEmpty, revealCount >= fullText.count {
                Text("  └─ \(detail)")
                    .font(IBMPlexMonoFont.font(.regular, size: 10))
                    .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(state.opacity * 0.50))
            }
        }
        .frame(height: Self.lineHeight + (sprite.detail != nil ? 13 : 0), alignment: .topLeading)
        .opacity(state.opacity)
    }

    // MARK: - Right panel: live ML state

    private func liveStatePanel(audio: StageAudioSnapshot, glowIntensity: Double, t: Double) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Scene + latency header
            HStack(spacing: 6) {
                if let latency = snapshot.latencyMs {
                    Text("\(latency)ms")
                        .foregroundStyle(latency > 80
                            ? StageIndustrialPalette.amber.color.opacity(0.7)
                            : StageIndustrialPalette.dimSignal.color.opacity(0.5))
                }
                Text(snapshot.visual.sceneId.uppercased())
                    .foregroundStyle(StageIndustrialPalette.active.color.opacity(0.55 + glowIntensity * 0.25))
            }
            .font(IBMPlexMonoFont.font(.bold, size: 10))
            .shadow(color: StageIndustrialPalette.active.color.opacity(glowIntensity * 0.30), radius: 4, x: 0, y: 0)

            // Picks
            ForEach(snapshot.picks) { pick in
                HStack(spacing: 4) {
                    Text(pick.token)
                        .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.50))
                    Text(pick.resolvedToken)
                        .foregroundStyle(pick.changedByHarness
                            ? StageIndustrialPalette.amber.color.opacity(0.75)
                            : StageIndustrialPalette.signal.color.opacity(0.70))
                }
                .font(IBMPlexMonoFont.font(.medium, size: 10))
            }

            // Params with inline bar
            ForEach(snapshot.params) { param in
                HStack(spacing: 4) {
                    Text(param.token)
                        .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.44))
                        .frame(width: 80, alignment: .trailing)
                    // Inline bar
                    paramBar(value: param.normalizedValue, changed: param.changedByHarness, glowIntensity: glowIntensity)
                    Text(param.valueToken)
                        .foregroundStyle(param.changedByHarness
                            ? StageIndustrialPalette.amber.color.opacity(0.70)
                            : StageIndustrialPalette.signal.color.opacity(0.60))
                }
                .font(IBMPlexMonoFont.font(.regular, size: 9))
            }

            Spacer().frame(height: 6)

            // Audio meters
            audioMeterRow(label: "RMS", value: audio.rms, color: StageIndustrialPalette.active, glowIntensity: glowIntensity)
            audioMeterRow(label: "FLUX", value: audio.transientFlux, color: StageIndustrialPalette.active, glowIntensity: glowIntensity)
            audioMeterRow(label: "LO", value: audio.lowBand, color: StageIndustrialPalette.signal, glowIntensity: glowIntensity)
            audioMeterRow(label: "MID", value: audio.midBand, color: StageIndustrialPalette.signal, glowIntensity: glowIntensity)
            audioMeterRow(label: "HI", value: audio.highBand, color: StageIndustrialPalette.signal, glowIntensity: glowIntensity)
            audioMeterRow(label: "PEAK", value: audio.peak, color: audio.overloadPulse > 0.4 ? StageIndustrialPalette.alert : StageIndustrialPalette.amber, glowIntensity: glowIntensity)

            Spacer().frame(height: 8)

            // State tag (thought token) — small, inline with telemetry
            thoughtStateTag(thought: snapshot.visual.thought, glowIntensity: glowIntensity)
        }
        .frame(maxWidth: canvasSize.width * 0.42, maxHeight: .infinity, alignment: .topTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, canvasSize.width * Self.insetFrac)
        .padding(.top, canvasSize.height * Self.insetFrac)
    }

    private func paramBar(value: Double, changed: Bool, glowIntensity: Double) -> some View {
        let barWidth: CGFloat = 40
        let fillWidth = CGFloat(min(1, max(0, value))) * barWidth
        let barColor = changed ? StageIndustrialPalette.amber : StageIndustrialPalette.active
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(StageIndustrialPalette.slate.color.opacity(0.30))
                .frame(width: barWidth, height: 4)
            Rectangle()
                .fill(barColor.color.opacity(0.50 + glowIntensity * 0.30))
                .frame(width: fillWidth, height: 4)
                .shadow(color: barColor.color.opacity(glowIntensity * 0.40), radius: 3, x: 0, y: 0)
        }
    }

    private func audioMeterRow(label: String, value: Double, color: StageColor, glowIntensity: Double) -> some View {
        let barWidth: CGFloat = 50
        let fillWidth = CGFloat(min(1, max(0, value))) * barWidth
        return HStack(spacing: 4) {
            Text(label)
                .font(IBMPlexMonoFont.font(.medium, size: 9))
                .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(0.50))
                .frame(width: 32, alignment: .trailing)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(StageIndustrialPalette.slate.color.opacity(0.25))
                    .frame(width: barWidth, height: 3)
                Rectangle()
                    .fill(color.color.opacity(0.45 + value * 0.40))
                    .frame(width: fillWidth, height: 3)
                    .shadow(color: color.color.opacity(value * 0.50), radius: 4 + value * 6, x: 0, y: 0)
            }
            Text(String(format: "%.2f", value))
                .font(IBMPlexMonoFont.font(.regular, size: 9))
                .foregroundStyle(StageIndustrialPalette.signal.color.opacity(0.40 + value * 0.40))
        }
    }

    // MARK: - Thought state tag (small, right panel inline)

    private func thoughtStateTag(thought: String, glowIntensity: Double) -> some View {
        let isActive = thought != "idle"
        return HStack(spacing: 4) {
            Circle()
                .fill((isActive ? StageIndustrialPalette.active : StageIndustrialPalette.dimSignal).color.opacity(isActive ? 0.35 : 0.12))
                .frame(width: 4, height: 4)
            Text(thought.replacingOccurrences(of: "_", with: " ").uppercased())
                .font(IBMPlexMonoFont.font(.medium, size: 7))
                .foregroundStyle(StageIndustrialPalette.dimSignal.color.opacity(isActive ? 0.40 : 0.20))
        }
    }

    // MARK: - Thought scene layer (large, right-aligned, scene-dominant)

    private func thoughtSceneLayer(glowIntensity: Double) -> some View {
        let lines = snapshot.visual.thoughtLog
        let baseOpacity = lines.isEmpty ? 0.0 : 0.55 + glowIntensity * 0.20

        return VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { idx, line in
                let fade = 1.0 - Double(idx) * 0.18
                Text(line)
                    .font(IBMPlexMonoFont.font(.regular, size: 16))
                    .foregroundStyle(StageIndustrialPalette.signal.color.opacity(baseOpacity * fade))
                    .shadow(color: StageIndustrialPalette.signal.color.opacity(glowIntensity * 0.25 * fade), radius: 8, x: 0, y: 0)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: canvasSize.width * 0.46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, canvasSize.width * Self.insetFrac)
        .padding(.bottom, canvasSize.height * 0.06)
        .animation(.easeInOut(duration: 1.5), value: lines)
    }

    // MARK: - Helpers

    private static func archetypeTag(_ archetype: StageModuleArchetype) -> String {
        switch archetype {
        case .controlToken: return "CTL"
        case .decisionBurst: return "DEC"
        case .deltaEcho: return "DLT"
        case .audioDebris: return "AUD"
        case .memoryGhost: return "MEM"
        case .linkSignal: return "LNK"
        }
    }

    private static func modeTag(_ mode: Int) -> String {
        switch mode {
        case 0: return "REVERB"
        case 1: return "STUTTER"
        case 2: return "GRAIN"
        case 3: return "CRUSH"
        case 4: return "SAMPLER"
        case 5: return "MIDI/WET"
        case 6: return "MIDI/DRY"
        case 7: return "BUCKETS"
        case 8: return "SPACE"
        case 9: return "PARTICLE"
        case 10: return "SCENES"
        default: return "MODE\(mode)"
        }
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let ti = date.timeIntervalSinceReferenceDate
        let totalSeconds = Int(ti) % 86400
        let hours = (totalSeconds / 3600) % 24
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60
        let centiseconds = Int((ti - floor(ti)) * 100) % 100
        return String(format: "%02d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds)
    }
}

private struct TerminalLogLine {
    let sprite: StageThoughtSprite
    let state: TerminalLogLineState
}

private struct TerminalLogLineState {
    let opacity: Double
    let activeAge: Double
    let fadeInDuration: Double

    init?(sprite: StageThoughtSprite, now: Date) {
        let age = sprite.age(at: now)
        guard age <= sprite.totalDuration else { return nil }
        let activeAge = max(0, age - sprite.delay)
        guard activeAge >= 0 else { return nil }

        let fadeIn = max(0.001, sprite.fadeInDuration)
        let hold = max(0, sprite.holdDuration)
        let fadeOut = max(0.001, sprite.fadeOutDuration)

        let opacity: Double
        if activeAge < fadeIn {
            opacity = activeAge / fadeIn
        } else if activeAge < fadeIn + hold {
            opacity = 1.0
        } else if activeAge < fadeIn + hold + fadeOut {
            opacity = 1.0 - ((activeAge - fadeIn - hold) / fadeOut)
        } else {
            opacity = 0
        }
        guard opacity > 0.05 else { return nil }

        self.opacity = opacity
        self.activeAge = activeAge
        self.fadeInDuration = fadeIn
    }

    func revealedCharacters(totalLength: Int) -> Int {
        guard totalLength > 0, fadeInDuration > 0.001 else { return totalLength }
        let progress = min(1.0, activeAge / fadeInDuration)
        return max(1, Int(ceil(Double(totalLength) * progress)))
    }
}

private struct StageWordmarkField: View {
    let snapshot: VideoStageSnapshot
    let now: Date
    let canvasSize: CGSize
    let flashOpacity: Double

    var body: some View {
        let field = StageRenderField(snapshot: snapshot, now: now)
        let fontSize = min(canvasSize.width * 0.24, canvasSize.height * 0.30)
        let tracking = fontSize * 0.08
        let frameSize = CGSize(width: fontSize * 3.2, height: fontSize * 2.2)
        let isJolt = snapshot.joltHeld || flashOpacity > 0.05
        let charSeed = snapshot.joltSeed ^ UInt64(Int(now.timeIntervalSinceReferenceDate * 8.0)) ^ UInt64(snapshot.mode * 7919)
        let charPrng = StagePRNG(seed: charSeed == 0 ? 0xC0DE : charSeed)
        let transforms = StageCharacterComputer.computeTransforms(
            field: field, audio: snapshot.stageAudio, mode: snapshot.mode,
            now: now, fontSize: fontSize, tracking: tracking, prng: charPrng,
            joltIntensity: isJolt ? max(0.5, flashOpacity * 1.8) : 0
        )

        let joltColorPrng = StagePRNG(seed: snapshot.joltSeed == 0 ? 0xDEAD : snapshot.joltSeed)
        let joltColor = Color(hue: joltColorPrng.value(at: 0), saturation: 0.55 + joltColorPrng.value(at: 1) * 0.45, brightness: 0.80 + joltColorPrng.value(at: 2) * 0.20)

        ZStack {
            StageSignalTraceCanvas(snapshot: snapshot, now: now, field: field, frameSize: frameSize)
                .frame(width: frameSize.width * 1.5, height: frameSize.height * 1.5)

            if isJolt {
                let t = now.timeIntervalSinceReferenceDate
                let smearStep = floor(t * 8)
                let smearPrng = StagePRNG(seed: snapshot.joltSeed ^ UInt64(smearStep))
                let smearDx = (smearPrng.value(at: 0) - 0.5) * 50 * flashOpacity
                let smearDy = (smearPrng.value(at: 1) - 0.5) * 30 * flashOpacity
                let aberration = flashOpacity * 8

                ZStack {
                    ForEach(transforms) { ct in
                        Text(ct.character)
                            .font(IBMPlexMonoFont.font(.bold, size: fontSize))
                            .foregroundStyle(joltColor.opacity(ct.opacity * 0.40 * flashOpacity))
                            .scaleEffect(ct.scale)
                            .rotationEffect(.degrees(ct.rotation))
                            .offset(x: ct.restX + ct.offsetX + CGFloat(smearDx),
                                    y: ct.restY + ct.offsetY + CGFloat(smearDy))
                    }
                    ForEach(transforms) { ct in
                        Text(ct.character)
                            .font(IBMPlexMonoFont.font(.bold, size: fontSize))
                            .foregroundStyle(joltColor.opacity(ct.opacity * 0.25 * flashOpacity))
                            .scaleEffect(ct.scale)
                            .rotationEffect(.degrees(ct.rotation))
                            .offset(x: ct.restX + ct.offsetX - CGFloat(smearDx * 0.6),
                                    y: ct.restY + ct.offsetY - CGFloat(smearDy * 0.8))
                    }
                    ForEach(transforms) { ct in
                        Text(ct.character)
                            .font(IBMPlexMonoFont.font(.bold, size: fontSize))
                            .foregroundStyle(Color.red.opacity(ct.opacity * 0.18 * flashOpacity))
                            .scaleEffect(ct.scale)
                            .rotationEffect(.degrees(ct.rotation))
                            .offset(x: ct.restX + ct.offsetX + CGFloat(aberration),
                                    y: ct.restY + ct.offsetY)
                    }
                    ForEach(transforms) { ct in
                        Text(ct.character)
                            .font(IBMPlexMonoFont.font(.bold, size: fontSize))
                            .foregroundStyle(Color.cyan.opacity(ct.opacity * 0.18 * flashOpacity))
                            .scaleEffect(ct.scale)
                            .rotationEffect(.degrees(ct.rotation))
                            .offset(x: ct.restX + ct.offsetX - CGFloat(aberration),
                                    y: ct.restY + ct.offsetY)
                    }
                }
                .frame(width: frameSize.width, height: frameSize.height)
                .drawingGroup(opaque: false)
                .blendMode(.screen)
            }

            // Main wordmark: static, monochrome, breathing with RMS.
            wordmarkDecomposed(
                fontSize: fontSize, frameSize: frameSize, transforms: transforms,
                baseColor: StageIndustrialPalette.signal.color,
                baseOpacity: isJolt ? max(0.50, 0.82 - flashOpacity * 0.3) : 1.0
            )
            // No glow in normal state — subtle dim halo only.
            .shadow(color: (isJolt ? joltColor : StageIndustrialPalette.dimSignal.color).opacity(isJolt ? 0.5 + flashOpacity * 0.3 : 0.06), radius: isJolt ? 30 : 6, x: 0, y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wordmarkCore(fontSize: CGFloat) -> some View {
        VStack(spacing: fontSize * 0.04) {
            Text(snapshot.wordmark.topText)
            Text(snapshot.wordmark.bottomText)
        }
        .font(IBMPlexMonoFont.font(.bold, size: fontSize))
        .tracking(fontSize * 0.08)
        .multilineTextAlignment(.center)
    }

    private func wordmarkDecomposed(
        fontSize: CGFloat,
        frameSize: CGSize,
        transforms: [StageCharacterTransform],
        baseColor: Color,
        baseOpacity: Double
    ) -> some View {
        ZStack {
            ForEach(transforms) { ct in
                Text(ct.character)
                    .font(IBMPlexMonoFont.font(.bold, size: fontSize))
                    .foregroundStyle(baseColor.opacity(ct.opacity * baseOpacity))
                    .scaleEffect(ct.scale)
                    .rotationEffect(.degrees(ct.rotation))
                    .blur(radius: ct.blur)
                    .hueRotation(.degrees(ct.hue))
                    .offset(x: ct.restX + ct.offsetX, y: ct.restY + ct.offsetY)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .drawingGroup(opaque: false)
    }

    private func wordmarkOffsets(style: StageWordmarkGlitchStyle, field: StageRenderField, now: Date) -> [CGSize] {
        let t = now.timeIntervalSinceReferenceDate
        let amp = 4 + field.destruction * 24 + field.activity * 16
        switch style {
        case .quietWatch:
            return [CGSize(width: sin(t * 0.6) * amp * 0.06, height: cos(t * 0.5) * amp * 0.04)]
        case .relayMesh:
            return [CGSize(width: -amp * 0.18, height: 0), CGSize(width: amp * 0.18, height: 0)]
        case .faultLattice:
            return [CGSize(width: sin(t * 2.8) * amp * 0.16, height: cos(t * 2.2) * amp * 0.18), CGSize(width: cos(t * 3.0) * -amp * 0.14, height: sin(t * 2.4) * amp * 0.20)]
        case .memoryDrift:
            return [CGSize(width: sin(t * 1.8) * amp * 0.18, height: cos(t * 1.2) * amp * 0.14), CGSize(width: cos(t * 1.4) * -amp * 0.12, height: sin(t * 1.6) * amp * 0.16)]
        case .alarmSplay:
            return [CGSize(width: sin(t * 4.2) * amp * 0.10, height: 0), CGSize(width: 0, height: cos(t * 4.8) * amp * 0.10)]
        }
    }

    private func makeFragments(frameSize: CGSize, field: StageRenderField) -> [StageWordmarkFragment] {
        let count = 8 + Int(field.destruction * 18) + Int(field.splat * 12)
        let seed = snapshot.joltSeed ^ UInt64(Int(now.timeIntervalSinceReferenceDate * 8.0)) ^ UInt64(snapshot.mode * 4099)
        let prng = StagePRNG(seed: seed == 0 ? 0xBADC0DE : seed)
        return (0..<count).map { index in
            let w = 0.10 + prng.value(at: index + 20) * 0.26
            let h = 0.05 + prng.value(at: index + 40) * 0.13
            let x = min(max(prng.value(at: index + 60) * (1.0 - w), 0.02), 0.98 - w)
            let y = min(max(prng.value(at: index + 80) * (1.0 - h), 0.04), 0.96 - h)
            let dx = (prng.value(at: index + 100) - 0.5) * (frameSize.width * (0.05 + field.destruction * 0.18))
            let dy = (prng.value(at: index + 120) - 0.5) * (frameSize.height * (0.05 + field.splat * 0.18))
            let blur = 1.0 + prng.value(at: index + 140) * (5.0 + field.splat * 12.0)
            let opacity = 0.08 + prng.value(at: index + 160) * (0.20 + field.destruction * 0.30)
            let color: Color = {
                if field.hasAdjustments && index % 5 == 0 {
                    return StageIndustrialPalette.amber.color
                }
                if index % 4 == 0 {
                    return StageIndustrialPalette.active.color
                }
                return StageIndustrialPalette.signal.color
            }()
            return StageWordmarkFragment(
                id: "fragment-\(index)-\(seed)",
                mask: CGRect(x: x, y: y, width: w, height: h),
                offset: CGSize(width: dx, height: dy),
                blur: blur,
                opacity: opacity,
                color: color
            )
        }
    }
}

private struct StageWordmarkFragment: Identifiable {
    let id: String
    let mask: CGRect
    let offset: CGSize
    let blur: Double
    let opacity: Double
    let color: Color
}

private struct StageCharacterTransform: Identifiable, Equatable {
    let id: Int
    let character: String
    let restX: CGFloat
    let restY: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let rotation: Double
    let scale: Double
    let opacity: Double
    let blur: Double
    let hue: Double
}

private enum CharacterPhaseStyle {
    case uniform
    case cascade
    case scatter
    case alternate
    case orbital
}

private struct StageCharacterPersonality {
    let positionMetric: KeyPath<StageAudioSnapshot, Double>
    let positionScale: Double
    let rotationMetric: KeyPath<StageAudioSnapshot, Double>
    let rotationScale: Double
    let scaleMetric: KeyPath<StageAudioSnapshot, Double>
    let scaleAmplitude: Double
    let blurMetric: KeyPath<StageAudioSnapshot, Double>
    let blurMax: Double
    let hueMetric: KeyPath<StageAudioSnapshot, Double>
    let hueMax: Double
    let phaseStyle: CharacterPhaseStyle
    let gravityBias: CGFloat
    let quantize: Double
    let timeScale: Double
}

private enum StageCharacterComputer {
    static let characters: [(character: String, row: Int, col: Int)] = [
        ("T", 0, 0), ("H", 0, 1), ("E", 0, 2),
        ("T", 1, 0), ("U", 1, 1), ("B", 1, 2),
    ]

    static func restPositions(fontSize: CGFloat, tracking: CGFloat) -> [(CGFloat, CGFloat)] {
        let charAdvance = fontSize * 0.6
        let gap = tracking
        let rowWidth = charAdvance * 3 + gap * 2
        let lineHeight = fontSize * 1.16
        let rowSpacing = fontSize * 0.04
        let topY = -(lineHeight * 0.5 + rowSpacing * 0.5)
        let bottomY = lineHeight * 0.5 + rowSpacing * 0.5

        return characters.map { entry in
            let x = CGFloat(entry.col) * (charAdvance + gap) - rowWidth * 0.5 + charAdvance * 0.5
            let y = entry.row == 0 ? topY : bottomY
            return (x, y)
        }
    }

    static func personality(for mode: Int) -> StageCharacterPersonality {
        switch mode {
        case 0:
            return StageCharacterPersonality(
                positionMetric: \.lowBand, positionScale: 14,
                rotationMetric: \.rms, rotationScale: 6,
                scaleMetric: \.lowBand, scaleAmplitude: 0.06,
                blurMetric: \.rms, blurMax: 1.2,
                hueMetric: \.brightness, hueMax: 8,
                phaseStyle: .uniform, gravityBias: 0, quantize: 0, timeScale: 0.6)
        case 1:
            return StageCharacterPersonality(
                positionMetric: \.transientFlux, positionScale: 22,
                rotationMetric: \.transientFlux, rotationScale: 12,
                scaleMetric: \.peak, scaleAmplitude: 0.12,
                blurMetric: \.transientFlux, blurMax: 0.6,
                hueMetric: \.midBand, hueMax: 5,
                phaseStyle: .alternate, gravityBias: 0, quantize: 0.7, timeScale: 2.8)
        case 2:
            return StageCharacterPersonality(
                positionMetric: \.rms, positionScale: 30,
                rotationMetric: \.brightness, rotationScale: 14,
                scaleMetric: \.highBand, scaleAmplitude: 0.10,
                blurMetric: \.rms, blurMax: 2.0,
                hueMetric: \.highBand, hueMax: 12,
                phaseStyle: .scatter, gravityBias: 0, quantize: 0, timeScale: 1.4)
        case 3:
            return StageCharacterPersonality(
                positionMetric: \.midBand, positionScale: 18,
                rotationMetric: \.zeroCrossDensity, rotationScale: 8,
                scaleMetric: \.highBand, scaleAmplitude: 0.08,
                blurMetric: \.brightness, blurMax: 0.4,
                hueMetric: \.zeroCrossDensity, hueMax: 6,
                phaseStyle: .uniform, gravityBias: 0, quantize: 1.0, timeScale: 3.2)
        case 4:
            return StageCharacterPersonality(
                positionMetric: \.transientFlux, positionScale: 26,
                rotationMetric: \.rms, rotationScale: 10,
                scaleMetric: \.peak, scaleAmplitude: 0.14,
                blurMetric: \.transientFlux, blurMax: 1.0,
                hueMetric: \.midBand, hueMax: 10,
                phaseStyle: .scatter, gravityBias: 0, quantize: 0.3, timeScale: 1.8)
        case 5:
            return StageCharacterPersonality(
                positionMetric: \.lowBand, positionScale: 20,
                rotationMetric: \.rms, rotationScale: 8,
                scaleMetric: \.midBand, scaleAmplitude: 0.10,
                blurMetric: \.lowBand, blurMax: 1.8,
                hueMetric: \.rms, hueMax: 6,
                phaseStyle: .cascade, gravityBias: 1.0, quantize: 0, timeScale: 0.9)
        case 6:
            return StageCharacterPersonality(
                positionMetric: \.brightness, positionScale: 16,
                rotationMetric: \.highBand, rotationScale: 6,
                scaleMetric: \.brightness, scaleAmplitude: 0.08,
                blurMetric: \.brightness, blurMax: 1.4,
                hueMetric: \.brightness, hueMax: 20,
                phaseStyle: .cascade, gravityBias: -1.0, quantize: 0, timeScale: 0.7)
        case 7:
            return StageCharacterPersonality(
                positionMetric: \.transientFlux, positionScale: 24,
                rotationMetric: \.midBand, rotationScale: 10,
                scaleMetric: \.rms, scaleAmplitude: 0.10,
                blurMetric: \.transientFlux, blurMax: 1.2,
                hueMetric: \.transientFlux, hueMax: 8,
                phaseStyle: .cascade, gravityBias: 0, quantize: 0, timeScale: 2.0)
        case 8:
            return StageCharacterPersonality(
                positionMetric: \.rms, positionScale: 22,
                rotationMetric: \.brightness, rotationScale: 12,
                scaleMetric: \.lowBand, scaleAmplitude: 0.08,
                blurMetric: \.rms, blurMax: 3.5,
                hueMetric: \.brightness, hueMax: 14,
                phaseStyle: .scatter, gravityBias: 0, quantize: 0, timeScale: 1.0)
        case 9:
            return StageCharacterPersonality(
                positionMetric: \.rms, positionScale: 28,
                rotationMetric: \.lowBand, rotationScale: 16,
                scaleMetric: \.midBand, scaleAmplitude: 0.10,
                blurMetric: \.midBand, blurMax: 1.0,
                hueMetric: \.lowBand, hueMax: 10,
                phaseStyle: .orbital, gravityBias: 0, quantize: 0, timeScale: 1.6)
        default:
            return StageCharacterPersonality(
                positionMetric: \.transientFlux, positionScale: 6,
                rotationMetric: \.transientFlux, rotationScale: 2,
                scaleMetric: \.peak, scaleAmplitude: 0.14,
                blurMetric: \.rms, blurMax: 0.3,
                hueMetric: \.midBand, hueMax: 4,
                phaseStyle: .uniform, gravityBias: 0, quantize: 0, timeScale: 2.4)
        }
    }

    static func computeTransforms(
        field: StageRenderField,
        audio: StageAudioSnapshot,
        mode: Int,
        now: Date,
        fontSize: CGFloat,
        tracking: CGFloat,
        prng: StagePRNG,
        joltIntensity: Double = 0
    ) -> [StageCharacterTransform] {
        let rest = restPositions(fontSize: fontSize, tracking: tracking)
        let t = now.timeIntervalSinceReferenceDate
        let jolt = min(1.0, joltIntensity)

        // Monochrome weight breathing: uniform brightness pulse from RMS.
        let breathe = min(1.0, audio.rms * 0.6 + audio.peak * 0.25)

        // Character dropout: on high disruption, individual characters go dark
        // like burned-out bulbs on industrial signage.
        // Dropout pattern changes every ~600ms so it flickers, not spins.
        let dropoutStep = UInt64(floor(t * 1.7))
        let dropoutPrng = StagePRNG(seed: dropoutStep ^ prng.seed ^ 0xB01B)

        return (0..<6).map { i in
            // No position offset — characters are grid-locked.
            var dx: CGFloat = 0
            var dy: CGFloat = 0

            // Jolt is the only exception: violent stepped corruption.
            if jolt > 0 {
                let step = floor(t * 8)
                let stepPrng = StagePRNG(seed: UInt64(step) ^ prng.seed &+ UInt64(i * 997))
                dx = CGFloat((stepPrng.value(at: 0) - 0.5) * jolt * 50)
                dy = CGFloat((stepPrng.value(at: 1) - 0.5) * jolt * 35)
            }

            // Jolt rotation: stepped corruption only during jolt.
            let joltRotStep = jolt > 0 ? floor(t * 6) : 0
            let joltRotPrng = StagePRNG(seed: UInt64(joltRotStep) ^ prng.seed &+ UInt64(i * 1013))
            let rotation = jolt * (joltRotPrng.value(at: 0) - 0.5) * 24

            let joltScaleBoost = jolt * (prng.value(at: i + 800) - 0.4) * 0.18
            let scale = max(0.6, 1.0 + joltScaleBoost)

            // Opacity: base brightness + RMS breathing.
            // Dropout: each character has a disruption threshold — when
            // disruption exceeds it, that character dims to near-zero.
            let charDropoutThreshold = 0.35 + dropoutPrng.value(at: i + 10) * 0.55
            let isDroppedOut = field.disruption > charDropoutThreshold && jolt == 0
            let dropoutDim = isDroppedOut ? max(0.04, 0.15 - field.disruption * 0.12) : 1.0

            let baseOpacity = 0.55 + breathe * 0.40
            let opacity = max(0.04, baseOpacity * dropoutDim)

            // No blur, no hue shift in normal state.
            let blur = jolt > 0 ? jolt * 1.5 : 0.0
            let hue = 0.0

            return StageCharacterTransform(
                id: i,
                character: characters[i].character,
                restX: rest[i].0,
                restY: rest[i].1,
                offsetX: dx,
                offsetY: dy,
                rotation: rotation,
                scale: scale,
                opacity: opacity,
                blur: blur,
                hue: hue
            )
        }
    }
}

private struct StageSignalTraceCanvas: View {
    let snapshot: VideoStageSnapshot
    let now: Date
    let field: StageRenderField
    let frameSize: CGSize

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let audio = snapshot.stageAudio
            let anchors = field.anchors.isEmpty
                ? [CGPoint(x: size.width * 0.3, y: size.height * 0.4),
                   CGPoint(x: size.width * 0.7, y: size.height * 0.4),
                   CGPoint(x: size.width * 0.5, y: size.height * 0.6)]
                : field.anchors.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

            let seed = snapshot.joltSeed ^ UInt64(snapshot.mode * 3571)
            let prng = StagePRNG(seed: seed == 0 ? 0xCAB1E : seed)
            let t = now.timeIntervalSinceReferenceDate

            // Per-cable audio metric: each cable reacts to a different band
            let cableMetrics: [Double] = [
                field.primaryChannelBias,
                audio.lowBand,
                audio.midBand,
                audio.highBand,
                audio.transientFlux,
            ]

            let connections: [(CGPoint, CGPoint)] = [
                (anchors.count > 0 ? anchors[0] : center, center),
                (anchors.count > 1 ? anchors[1] : center, center),
                (anchors.count > 2 ? anchors[2] : center, center),
                (anchors.count > 1 ? anchors[0] : center, anchors.count > 1 ? anchors[1] : center),
                (anchors.count > 2 ? anchors[1] : center, anchors.count > 2 ? anchors[2] : center),
            ]

            for (cableIdx, connection) in connections.enumerated() {
                let from = connection.0
                let to = connection.1
                let metric = cableIdx < cableMetrics.count ? cableMetrics[cableIdx] : field.activity
                let goHorizontalFirst = prng.value(at: cableIdx + 50) > 0.5
                let corner = goHorizontalFirst
                    ? CGPoint(x: to.x, y: from.y)
                    : CGPoint(x: from.x, y: to.y)

                // Cable width and opacity pulse with this cable's audio metric
                let cableWidth = 1.2 + metric * 1.6 + field.activity * 0.4
                let baseOpacity = 0.14 + metric * 0.22 + field.activity * 0.10

                // Draw cable path
                var cablePath = Path()
                cablePath.move(to: from)
                cablePath.addLine(to: corner)
                cablePath.addLine(to: to)

                let cableColor: Color
                if cableIdx == 0 {
                    cableColor = StageIndustrialPalette.active.color.opacity(baseOpacity)
                } else if metric > 0.5 {
                    cableColor = StageIndustrialPalette.amber.color.opacity(baseOpacity)
                } else {
                    cableColor = StageIndustrialPalette.dimSignal.color.opacity(baseOpacity)
                }
                context.stroke(cablePath, with: .color(cableColor), lineWidth: cableWidth)

                // Corner node — brightens with metric
                let cornerR: CGFloat = 2 + metric * 1.5
                let cornerRect = CGRect(x: corner.x - cornerR, y: corner.y - cornerR, width: cornerR * 2, height: cornerR * 2)
                context.fill(Path(ellipseIn: cornerRect), with: .color(cableColor.opacity(0.5 + metric * 0.3)))

                // Signal flow indicators — count and speed scale with audio
                let indicatorCount = 2 + (metric > 0.3 ? 1 : 0) + (field.splat > 0.5 ? 1 : 0)
                let speed = 0.2 + metric * 1.2 + field.activity * 0.5
                let seg1Len = hypot(corner.x - from.x, corner.y - from.y)
                let seg2Len = hypot(to.x - corner.x, to.y - corner.y)
                let totalLen = max(1, seg1Len + seg2Len)

                for si in 0..<indicatorCount {
                    let phase = Double(si) / Double(indicatorCount)
                    let raw = (t * speed + phase + prng.value(at: cableIdx * 10 + si + 100) * 0.5)
                    let frac = raw - floor(raw)
                    let dist = frac * totalLen

                    let pos: CGPoint
                    let isHorizontal: Bool
                    if dist < seg1Len {
                        let f = dist / max(1, seg1Len)
                        pos = CGPoint(x: from.x + (corner.x - from.x) * f, y: from.y + (corner.y - from.y) * f)
                        isHorizontal = goHorizontalFirst
                    } else {
                        let f = (dist - seg1Len) / max(1, seg2Len)
                        pos = CGPoint(x: corner.x + (to.x - corner.x) * f, y: corner.y + (to.y - corner.y) * f)
                        isHorizontal = !goHorizontalFirst
                    }

                    // Oriented indicator — horizontal or vertical depending on cable segment
                    let iw: CGFloat = isHorizontal ? (5 + metric * 3) : 2
                    let ih: CGFloat = isHorizontal ? 2 : (5 + metric * 3)
                    let indicatorRect = CGRect(x: pos.x - iw * 0.5, y: pos.y - ih * 0.5, width: iw, height: ih)
                    let indicatorOpacity = 0.40 + metric * 0.45 + field.activity * 0.15
                    let indicatorColor = cableIdx == 0
                        ? StageIndustrialPalette.active.color.opacity(indicatorOpacity)
                        : StageIndustrialPalette.signal.color.opacity(indicatorOpacity)
                    context.fill(Path(indicatorRect), with: .color(indicatorColor))
                }
            }

            // Junction endpoints
            let junctions = anchors + [center]
            for (ji, junction) in junctions.enumerated() {
                let jMetric = ji < cableMetrics.count ? cableMetrics[ji] : field.activity
                let jSize: CGFloat = 4 + jMetric * 2
                let jRect = CGRect(x: junction.x - jSize * 0.5, y: junction.y - jSize * 0.5, width: jSize, height: jSize)
                let jColor = ji == junctions.count - 1
                    ? StageIndustrialPalette.signal.color.opacity(0.20 + field.activity * 0.20)
                    : StageIndustrialPalette.dimSignal.color.opacity(0.18 + jMetric * 0.22)
                context.fill(Path(jRect), with: .color(jColor))
                context.stroke(Path(jRect), with: .color(jColor.opacity(0.6)), lineWidth: 1)
            }
        }
    }
}

struct StageRenderField {
    let activity: Double
    let disruption: Double
    let destruction: Double
    let splat: Double
    let brightness: Double
    let overload: Double
    let primaryChannelBias: Double
    let anchors: [CGPoint]
    let anchorWeights: [Double]
    let gridDensity: CGFloat
    let scanDensity: CGFloat
    let hasAdjustments: Bool

    init(snapshot: VideoStageSnapshot, now: Date) {
        let visual = snapshot.visual
        let audio = snapshot.stageAudio
        let activity = max(audio.rms, audio.transientFlux * 0.9, 1.0 - audio.silenceConfidence)
        let disruption = min(1.0, max(visual.disruption, audio.transientFlux * 0.72 + audio.overloadPulse * 0.30))
        let destruction = min(1.0, max((1.0 - visual.wordmarkIntegrity), disruption * 0.68 + audio.brightness * 0.14))
        let splat = min(1.0, max(audio.transientFlux * 0.72, audio.highBand * 0.50, disruption * 0.30))
        self.activity = activity
        self.disruption = disruption
        self.destruction = destruction
        self.splat = splat
        self.brightness = max(audio.brightness, audio.highBand)
        self.overload = max(audio.overloadPulse, snapshot.joltHeld ? visual.flashBias : 0)
        self.primaryChannelBias = audio.channelEnergy.first ?? 0
        self.anchorWeights = snapshot.visual.anchorWeights.count == snapshot.visualProfile.anchors.count ? snapshot.visual.anchorWeights : [0.34, 0.33, 0.33]
        self.anchors = snapshot.visualProfile.anchors.map { CGPoint(x: $0.x, y: $0.y) }
        self.gridDensity = CGFloat(0.4 + visual.density * 0.6)
        self.scanDensity = CGFloat(0.3 + activity * 0.7)
        self.hasAdjustments = snapshot.hasAdjustments
    }
}

private struct StageFlashOverlay: View {
    let snapshot: VideoStageSnapshot
    let pattern: StageFlashPattern
    let opacity: Double

    var body: some View {
        let tearPrng = StagePRNG(seed: UInt64(pattern.phaseHash) ^ snapshot.joltSeed)

        GeometryReader { proxy in
            ZStack {
                pattern.joltColor.opacity(opacity * 0.92)

                ForEach(0..<4, id: \.self) { sliceIdx in
                    let sliceY = tearPrng.value(at: sliceIdx + 20) * proxy.size.height
                    let sliceH = 4 + tearPrng.value(at: sliceIdx + 30) * 24
                    let sliceShift = (tearPrng.value(at: sliceIdx + 40) - 0.5) * proxy.size.width * 0.35 * opacity
                    let sliceBright = tearPrng.value(at: sliceIdx + 50) > 0.5
                    Rectangle()
                        .fill(sliceBright
                              ? Color.white.opacity(0.12 + opacity * 0.10)
                              : pattern.joltColor.opacity(0.30 + opacity * 0.20))
                        .frame(width: proxy.size.width * 1.1, height: sliceH)
                        .offset(x: sliceShift, y: sliceY - proxy.size.height * 0.5)
                }

                VStack(spacing: min(proxy.size.height * 0.02, 14)) {
                    Text(snapshot.wordmark.topText)
                    Text(snapshot.wordmark.bottomText)
                }
                .font(IBMPlexMonoFont.font(.bold, size: min(proxy.size.width * 0.20, proxy.size.height * 0.28)))
                .foregroundStyle(Color.white.opacity(0.20 + opacity * 0.16))
                .tracking(10)
                .offset(x: CGFloat(pattern.phaseHash % 17) - 8,
                         y: CGFloat((pattern.phaseHash / 17) % 13) - 6)
            }
        }
    }
}


private struct StageFlashPattern {
    let primary: StageColor
    let secondary: StageColor
    let tertiary: StageColor
    let joltColor: Color
    let points: [CGPoint]
    let phaseHash: Int

    init(snapshot: VideoStageSnapshot, now: Date) {
        let elapsed = max(0, now.timeIntervalSince(snapshot.joltBeganAt ?? now))
        let stepMs = Int(90 + snapshot.visual.flashBias * 50)
        let phase = Int(floor((elapsed * 1000) / Double(stepMs)))
        let seed = snapshot.joltSeed &+ UInt64(phase) &* 0x9E3779B97F4A7C15
        let base = StagePRNG(seed: seed)

        let colorPrng = StagePRNG(seed: snapshot.joltSeed == 0 ? 0xDEAD : snapshot.joltSeed)
        let hue = colorPrng.value(at: 0)
        let sat = 0.55 + colorPrng.value(at: 1) * 0.45
        let bri = 0.80 + colorPrng.value(at: 2) * 0.20
        joltColor = Color(hue: hue, saturation: sat, brightness: bri)

        primary = snapshot.visual.flashBias > 0.66 ? StageIndustrialPalette.alert : StageIndustrialPalette.amber
        secondary = snapshot.stageAudio.overloadPulse > 0.42 ? StageIndustrialPalette.alert : StageIndustrialPalette.active
        tertiary = StageIndustrialPalette.signal
        phaseHash = Int(seed & 0x7FFF)

        var generated: [CGPoint] = []
        let anchors = snapshot.visualProfile.anchors.isEmpty ? [CGPoint(x: 0.5, y: 0.5)] : snapshot.visualProfile.anchors
        for idx in 0..<min(4, anchors.count + 1) {
            let anchor = anchors[idx % anchors.count]
            let jitterX = (base.value(at: idx + 3) - 0.5) * (0.10 + snapshot.visual.flashBias * 0.12)
            let jitterY = (base.value(at: idx + 9) - 0.5) * (0.10 + snapshot.visual.flashBias * 0.12)
            generated.append(CGPoint(x: min(max(anchor.x + jitterX, 0.08), 0.92), y: min(max(anchor.y + jitterY, 0.08), 0.92)))
        }
        points = generated
    }
}

private struct StageJoltDistortion: ViewModifier {
    let joltHeld: Bool
    let flashOpacity: Double
    let joltSeed: UInt64
    let now: Date

    func body(content: Content) -> some View {
        let active = joltHeld || flashOpacity > 0.05
        let t = now.timeIntervalSinceReferenceDate
        let intensity = active ? flashOpacity : 0
        let prng = StagePRNG(seed: joltSeed == 0 ? 0xF00D : joltSeed)

        let shakeX = active ? sin(t * 14 + prng.value(at: 10) * 4) * 6 * intensity : 0
        let shakeY = active ? cos(t * 18 + prng.value(at: 11) * 4) * 4 * intensity : 0

        content
            .offset(x: shakeX, y: shakeY)
    }
}

// MARK: - Film Grade Post-Process

/// Applies filmic post-processing to the entire stage: grain, vignette, color
/// grade, chromatic aberration, and subtle bloom. Uses Metal shaders via
/// SwiftUI's ShaderLibrary for GPU-accelerated per-pixel effects.
struct StageFilmGrade: ViewModifier {
    let canvasSize: CGSize
    let time: Double
    let audio: StageAudioSnapshot

    func body(content: Content) -> some View {
        let t = Float(time)
        let w = Float(canvasSize.width)
        let h = Float(canvasSize.height)
        let activity = max(audio.rms, audio.transientFlux * 0.8)
        let grain = Float(0.030 + activity * 0.018)

        content
            .layerEffect(
                ShaderLibrary.chromaticAberration(
                    .float2(w, h),
                    .float(Float(1.8)),           // base strength
                    .float(Float(audio.rms)),
                    .float(Float(audio.transientFlux)),
                    .float(Float(audio.lowBand)),
                    .float(t)
                ),
                maxSampleOffset: CGSize(width: 10, height: 10),
                isEnabled: true
            )
            .layerEffect(
                ShaderLibrary.softBloom(
                    .float2(w, h), .float(0.15), .float(0.22)
                ),
                maxSampleOffset: CGSize(width: 4, height: 4),
                isEnabled: true
            )
            .colorEffect(
                ShaderLibrary.filmGrade(
                    .float2(w, h), .float(t), .float(grain),
                    .float(0.72), .float(0.42)
                ),
                isEnabled: true
            )
    }
}

struct CommandKeyHoldMonitor: NSViewRepresentable {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let onHeldChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(key: key.lowercased(), modifiers: modifiers, onHeldChanged: onHeldChanged)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHeldChanged = onHeldChanged
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let key: String
        private let modifiers: NSEvent.ModifierFlags
        var onHeldChanged: (Bool) -> Void
        private var keyDownMonitor: Any?
        private var keyUpMonitor: Any?
        private var flagsMonitor: Any?
        private var isHeld: Bool = false

        init(key: String, modifiers: NSEvent.ModifierFlags, onHeldChanged: @escaping (Bool) -> Void) {
            self.key = key
            self.modifiers = modifiers
            self.onHeldChanged = onHeldChanged
        }

        func install() {
            uninstall()
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleKeyUp(event) ?? event
            }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event) ?? event
            }
        }

        func uninstall() {
            if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
            if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            keyDownMonitor = nil
            keyUpMonitor = nil
            flagsMonitor = nil
            if isHeld {
                isHeld = false
                onHeldChanged(false)
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard matches(event: event) else { return event }
            if !isHeld {
                isHeld = true
                onHeldChanged(true)
            }
            return nil
        }

        private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
            guard matchesKey(event: event) else { return event }
            if isHeld {
                isHeld = false
                onHeldChanged(false)
                return nil
            }
            return event
        }

        private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
            if isHeld && !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(modifiers) {
                isHeld = false
                onHeldChanged(false)
            }
            return event
        }

        private func matches(event: NSEvent) -> Bool {
            matchesKey(event: event) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(modifiers)
        }

        private func matchesKey(event: NSEvent) -> Bool {
            event.charactersIgnoringModifiers?.lowercased() == key
        }
    }
}

// MARK: - SoftLink Lower-Third Overlay

private struct SoftLinkPairingOverlay: View {
    let phase: SoftLinkVisualPhase
    let now: Date
    let canvasSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            lowerThird
                .padding(.horizontal, canvasSize.width * 0.04)
                .padding(.bottom, canvasSize.height * 0.06)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var lowerThird: some View {
        switch phase {
        case .inactive:
            EmptyView()

        case .listening(let since, let timeoutAt):
            listeningBanner(since: since, timeoutAt: timeoutAt)

        case .linked(let channel, _):
            linkedBanner(channel: channel)

        case .failed(let reason, _):
            failedBanner(reason: reason)
        }
    }

    private func listeningBanner(since: Date, timeoutAt: Date) -> some View {
        let elapsed = now.timeIntervalSince(since)
        let remaining = max(0, timeoutAt.timeIntervalSince(now))
        let total = timeoutAt.timeIntervalSince(since)
        let progress = min(1.0, elapsed / total)
        let blinkOn = Int(now.timeIntervalSinceReferenceDate * 2.5) % 2 == 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(StageIndustrialPalette.active.color)
                    .frame(width: 8, height: 8)
                    .opacity(blinkOn ? 1.0 : 0.2)

                Text("SOFTLINK PAIRING")
                    .font(IBMPlexMonoFont.font(.bold, size: 14))
                    .foregroundStyle(StageIndustrialPalette.active.color)
                    .opacity(blinkOn ? 1.0 : 0.6)

                Spacer()

                Text(String(format: "%.0fs", remaining))
                    .font(IBMPlexMonoFont.font(.medium, size: 12))
                    .foregroundStyle(remaining < 4 ? StageIndustrialPalette.amber.color : StageIndustrialPalette.signal.color)
                    .monospacedDigit()
            }

            Text("awaiting channel signal — plug in now")
                .font(IBMPlexMonoFont.font(.regular, size: 10))
                .foregroundStyle(StageIndustrialPalette.dimSignal.color)

            GeometryReader { barProxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StageIndustrialPalette.slate.color)
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StageIndustrialPalette.active.color.opacity(0.8))
                        .frame(width: barProxy.size.width * progress, height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(StageIndustrialPalette.graphite.color.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(StageIndustrialPalette.active.color.opacity(blinkOn ? 0.5 : 0.15), lineWidth: 1)
                )
        )
        .shadow(color: StageIndustrialPalette.active.color.opacity(0.15), radius: 12)
    }

    private func linkedBanner(channel: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(StageIndustrialPalette.active.color)

            Text("CH\(channel) LINKED")
                .font(IBMPlexMonoFont.font(.bold, size: 14))
                .foregroundStyle(StageIndustrialPalette.active.color)

            Text("— signal confirmed")
                .font(IBMPlexMonoFont.font(.regular, size: 11))
                .foregroundStyle(StageIndustrialPalette.dimSignal.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(StageIndustrialPalette.graphite.color.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(StageIndustrialPalette.active.color.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private func failedBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(StageIndustrialPalette.amber.color)

            Text("SOFTLINK \(reason)")
                .font(IBMPlexMonoFont.font(.bold, size: 14))
                .foregroundStyle(StageIndustrialPalette.amber.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(StageIndustrialPalette.graphite.color.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(StageIndustrialPalette.amber.color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

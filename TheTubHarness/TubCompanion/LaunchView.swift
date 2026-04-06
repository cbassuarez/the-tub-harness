//
//  LaunchView.swift
//  TubCompanion
//
//  Onboarding flow: <15 seconds to field.
//  Cable first, NFC, permissions, harness connection.
//

import SwiftUI

enum ConnectionGatePresentation {
    case fullScreen
    case overlay
}

struct TubLaunchScreenView: View {
    let isPlaySurfaceReady: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var playReadyAt: Date?
    @State private var tracerX: CGFloat = -280
    @State private var sessionToken = TubLaunchScreenView.makeSessionToken()
    @State private var pulseSeed: Double = 0

    private let transcriptLines: [String] = [
        "MOUNTING AUDIENCE COMMAND SHELL",
        "SYNCING STAGE MIRROR BUS",
        "VERIFYING LIVE SESSION CRYPTOGRAPHY",
        "LAUNCHING_SURFACES.PLAY",
        "LAUNCHING_SURFACES.STEER",
        "LAUNCHING_SURFACES.LEARN",
        "LAUNCHING_SURFACES.SETTINGS",
        "LOCKING SIGNAL RAILS",
        "ARMING PERCEPTION LOOP"
    ]

    private let spinnerFrames = ["-", "\\", "|", "/"]
    private let bootSegments = 36
    private let bootDuration: TimeInterval = 3.3
    private let quickFinishDuration: TimeInterval = 0.44
    private static let transcriptStepDurations: [TimeInterval] = [
        0.16, 0.31, 0.49, 0.11, 0.1, 0.09, 0.09, 0.27, 0.38
    ]
    private static let transcriptStepTimeline: [TimeInterval] = {
        var timeline: [TimeInterval] = []
        timeline.reserveCapacity(transcriptStepDurations.count)
        var sum: TimeInterval = 0
        for step in transcriptStepDurations {
            sum += max(0.04, step)
            timeline.append(sum)
        }
        return timeline
    }()
    private static let transcriptTotalDuration: TimeInterval = transcriptStepTimeline.last ?? 1
    private let transcriptRowHeight: CGFloat = 15

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let baseProgress = TubLaunchScreenView.physicalLoadingCurve(min(1, elapsed / bootDuration))
            let progress = resolvedProgress(baseProgress: baseProgress, now: timeline.date)
            let revealCount = revealCount(for: progress)
            let cursorOn = (Int((elapsed * 2).rounded(.down)) % 2) == 0
            let spinner = spinnerFrames[Int((elapsed * 12).rounded(.down)) % spinnerFrames.count]
            let litSegments = min(bootSegments, max(1, Int((progress * Double(bootSegments)).rounded(.down))))
            let pulse = 0.65 + 0.35 * sin((elapsed + pulseSeed) * 4.2)
            let activeLineIndex = min(max(0, revealCount - 1), transcriptLines.count - 1)
            let systemMillis = Int((elapsed * 1_000).rounded(.down)) % 1_000
            let systemSeconds = Int(elapsed.rounded(.down))
            let statusPulse = 0.4 + 0.6 * abs(sin(elapsed * 2.2))

            ZStack {
                Color.black.ignoresSafeArea()
                TubLaunchShellGrid()
                    .ignoresSafeArea()
                    .opacity(0.16)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.1), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 136)
                    .offset(x: tracerX)
                    .blur(radius: 1.2)
                    .blendMode(.screen)
                    .opacity(reduceMotion ? 0 : 1)

                bootContent(
                    spinner: spinner,
                    systemSeconds: systemSeconds,
                    systemMillis: systemMillis,
                    statusPulse: statusPulse,
                    revealCount: revealCount,
                    activeLineIndex: activeLineIndex,
                    litSegments: litSegments,
                    progress: progress,
                    cursorOn: cursorOn,
                    pulse: pulse
                )
            }
        }
        .onAppear {
            startedAt = Date()
            playReadyAt = isPlaySurfaceReady ? Date() : nil
            sessionToken = TubLaunchScreenView.makeSessionToken()
            pulseSeed = Double.random(in: 0.2...1.1)
            tracerX = -280
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                tracerX = 280
            }
        }
        .onChange(of: isPlaySurfaceReady) { _, isReady in
            if isReady, playReadyAt == nil {
                playReadyAt = Date()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("THE TUB is initializing")
        .accessibilityIdentifier("launch.screen")
    }

    @ViewBuilder
    private func bootContent(
        spinner: String,
        systemSeconds: Int,
        systemMillis: Int,
        statusPulse: Double,
        revealCount: Int,
        activeLineIndex: Int,
        litSegments: Int,
        progress: Double,
        cursorOn: Bool,
        pulse: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TUBCORP ENTERPRISE SCLI // THE TUB")
                    .playMono(11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text("BOOT \(spinner) 00:\(String(format: "%02d", systemSeconds)):\(String(format: "%03d", systemMillis))")
                    .playMono(10, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.64 + statusPulse * 0.3))
                    .frame(width: 190, alignment: .trailing)
            }

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 1)
                .padding(.top, 10)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 10) {
                TubCorpWordmark(height: 48)
                    .scaleEffect(reduceMotion ? 1 : (0.995 + 0.005 * statusPulse), anchor: .leading)

                Text("LIVE CONTROL SHELL // READYING STAGE")
                    .playMono(12, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.74))

                HStack(spacing: 10) {
                    Text("SESSION \(sessionToken)")
                        .playMono(10, weight: .semibold)
                        .foregroundStyle(Color.white.opacity(0.64))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("NODE IOS")
                        .playMono(10, weight: .semibold)
                        .foregroundStyle(Color.white.opacity(0.64))
                        .frame(width: 86, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            }

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(transcriptLines.enumerated()), id: \.offset) { index, line in
                    let isRevealed = index < revealCount
                    let isActive = isRevealed && index == activeLineIndex
                    HStack(spacing: 8) {
                        Text(">")
                            .playMono(10, weight: .bold)
                            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.7))
                        Text(isRevealed ? line : "")
                            .playMono(10, weight: .medium)
                            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.74))
                        Spacer(minLength: 0)
                    }
                    .frame(height: transcriptRowHeight, alignment: .leading)
                    .opacity(isRevealed ? (isActive ? 1 : 0.72) : 0.16)
                    .animation(.easeInOut(duration: 0.08), value: activeLineIndex)
                }
            }
            .frame(height: (transcriptRowHeight * CGFloat(transcriptLines.count)) + 2, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 3) {
                ForEach(0..<bootSegments, id: \.self) { index in
                    Rectangle()
                        .fill(index < litSegments ? Color.white.opacity(0.95) : Color.white.opacity(0.16))
                        .scaleEffect(y: (!reduceMotion && index == max(0, litSegments - 1)) ? 1.16 : 1.0, anchor: .center)
                        .frame(height: 6)
                }
            }
            .animation(.linear(duration: 0.08), value: litSegments)

            HStack(spacing: 12) {
                Text(progress >= 1 ? "READY" : "INITIALIZING")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(cursorOn ? "_" : " ")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.82))
                Spacer()
                Text("SYNC \(Int((progress * 100).rounded(.down)))%")
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(.top, 8)

            Text("OPERATING PROFILE // PARTICIPANT CONTROL TERMINAL")
                .playMono(9, weight: .regular)
                .foregroundStyle(Color.white.opacity(0.44))
                .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .opacity(reduceMotion ? 1 : (0.9 + 0.1 * pulse))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 62)
    }

    private func resolvedProgress(baseProgress: Double, now: Date) -> Double {
        guard let playReadyAt else { return baseProgress }
        let readyElapsed = max(0, now.timeIntervalSince(playReadyAt))
        let quick = min(1, readyElapsed / quickFinishDuration)
        let quickCurve = TubLaunchScreenView.quickFinishCurve(quick)
        let blended = baseProgress + ((1 - baseProgress) * quickCurve)
        return max(baseProgress, min(1, blended))
    }

    private func revealCount(for progress: Double) -> Int {
        let clock = max(0, min(1, progress)) * TubLaunchScreenView.transcriptTotalDuration
        var count = 0
        for threshold in TubLaunchScreenView.transcriptStepTimeline where clock >= threshold {
            count += 1
        }
        return max(1, min(transcriptLines.count, count))
    }

    private static func physicalLoadingCurve(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        if clamped <= 0.68 {
            let early = clamped / 0.68
            return 0.82 * pow(early, 0.58)
        }
        let tail = (clamped - 0.68) / 0.32
        return 0.82 + (0.18 * pow(tail, 1.9))
    }

    private static func quickFinishCurve(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return 1 - pow(1 - clamped, 2.2)
    }

    private static func makeSessionToken() -> String {
        let generator = SystemRandomNumberGenerator()
        var g = generator
        let blockA = String(format: "%02X", Int.random(in: 0...255, using: &g))
        let blockB = String(format: "%02X", Int.random(in: 0...255, using: &g))
        let blockC = String(format: "%02X", Int.random(in: 0...255, using: &g))
        let blockD = String(format: "%02X", Int.random(in: 0...255, using: &g))
        return "\(blockA).\(blockB).\(blockC).\(blockD)"
    }
}

private struct TubLaunchShellGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()

            let horizontalStep = max(68, size.height / 9)
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += horizontalStep
            }

            let verticalStep = max(54, size.width / 7)
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += verticalStep
            }

            context.stroke(path, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
        }
    }
}

// playMono / playSans are now shared via BrandingUI.swift

struct ConnectionGateView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor

    let presentation: ConnectionGatePresentation
    let preferredIntent: EntryIntent?

    @State private var step: GateStep = .chooseIntent
    @State private var isAttemptingLocalConnect = false
    @State private var showCableHelp = false
    @State private var toasts: [Toast] = []
    @State private var fadeInButtons = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var slideInPills = false
    @State private var loaderRotation: Double = 0
    @State private var handshakeStatus: String?
    @State private var hasAttemptedAutoHarnessConnect = false
    @State private var didPrimeRuntimePermissions = false

    enum GateStep {
        case chooseIntent
        case playLive
        case feedBank
    }

    var body: some View {
        ZStack {
            Color(UIColor(named: "DarkBackground") ?? .black)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: presentation == .fullScreen ? 36 : 12)

                TubCorpWordmark(height: 32)

                Spacer(minLength: 28)

                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .chooseIntent:
                        chooseIntentContent
                    case .playLive:
                        playLiveContent
                    case .feedBank:
                        feedBankContent
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 18)

                Spacer(minLength: 24)

                statusStrip
                    .padding(.horizontal, 18)
                    .padding(.bottom, presentation == .fullScreen ? 28 : 18)
            }
            
            // Toast overlay at the top
            VStack(alignment: .leading, spacing: 8) {
                ForEach(toasts) { toast in
                    ToastView(toast: toast) {
                        toasts.removeAll { $0.id == toast.id }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .allowsHitTesting(false)
        }
        .onAppear {
            primeRuntimePermissionsIfNeeded()
            if let preferredIntent {
                switch preferredIntent {
                case .playLive:
                    presentPlayCableGate()
                case .feedBank:
                    primeRuntimePermissionsIfNeeded()
                    appState.chooseEntryIntent(preferredIntent)
                    step = .feedBank
                }
            }
            withAnimation(.easeIn(duration: 0.5)) {
                fadeInButtons = true
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                slideInPills = true
            }
            ensureAutoHarnessLinkAttemptIfNeeded()
        }
        .onChange(of: step) { _, _ in
            ensureAutoHarnessLinkAttemptIfNeeded()
        }
        .onReceive(harnessClient.$connectionState) { state in
            appState.syncHarnessState(state)
            switch state {
            case .connecting:
                break
            case .connected, .disconnected, .error:
                isAttemptingLocalConnect = false
            }
            
            // Show toast on successful connection
            if case .connected = state {
                addToast("✓ Connected to THE TUB!", style: .success)
                if step == .feedBank {
                    appState.requestTabNavigation(.steer)
                }
            }
        }
        .onReceive(externalAudioRouteMonitor.$isExternalAudioRouteActive) { isActive in
            // Show toast when cable is detected
            if isActive {
                addToast("🎙️ Cable detected!", style: .success)
            }
        }
    }
    
    // MARK: - Toast Helper
    
    private func addToast(_ message: String, style: Toast.ToastStyle) {
        let toast = Toast(message: message, style: style)
        toasts.append(toast)
    }

    private var chooseIntentContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How do you want to enter?")
                .playSans(18, weight: .semibold)
                .foregroundColor(.white)

            Text("Choose one path. You can change it later.")
                .playSans(11)
                .foregroundColor(.gray)

            Button(action: {
                presentPlayCableGate()
            }) {
                gateCommandWithIcon(
                    icon: "waveform.circle",
                    title: "Play Into the Tub",
                    subtitle: "Use the cable. Immediate live path."
                )
            }
            .opacity(fadeInButtons ? 1 : 0)
            .offset(y: fadeInButtons ? 0 : 10)
            .animation(.easeOut(duration: 0.4).delay(0.1), value: fadeInButtons)
            .accessibilityLabel(Text("Play into the tub"))
            .accessibilityHint(Text("Enter live play mode using USB-C cable connection"))

            Button(action: {
                primeRuntimePermissionsIfNeeded()
                appState.chooseEntryIntent(.feedBank)
                step = .feedBank
            }) {
                gateCommandWithIcon(
                    icon: "arrow.up.doc",
                    title: "Steer the Tub ML",
                    subtitle: "Use the harness link. Session contribution path."
                )
            }
            .opacity(fadeInButtons ? 1 : 0)
            .offset(y: fadeInButtons ? 0 : 10)
            .animation(.easeOut(duration: 0.4).delay(0.2), value: fadeInButtons)
            .accessibilityLabel(Text("Steer THE TUB ML"))
            .accessibilityHint(Text("Steer machine learning picks and weights live using harness connection"))

            if let last = appState.lastEntryIntent {
                Button(action: {
                    switch last {
                    case .playLive:
                        presentPlayCableGate()
                    case .feedBank:
                        primeRuntimePermissionsIfNeeded()
                        appState.chooseEntryIntent(last)
                        step = .feedBank
                    }
                }) {
                    Text(last == .playLive ? "Resume live cable session" : "Reconnect to harness link")
                        .playSans(11, weight: .semibold)
                        .foregroundColor(.gray)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func presentPlayCableGate() {
        primeRuntimePermissionsIfNeeded()
        appState.rememberEntryIntent(.playLive)
        appState.clearCablePath()
        appState.forcePresentEntryGate = true
        appState.bypassPreferredEntryIntentOnce = false
        step = .playLive
    }

    private func primeRuntimePermissionsIfNeeded() {
        guard !didPrimeRuntimePermissions else { return }
        didPrimeRuntimePermissions = true

        externalAudioRouteMonitor.refreshRouteState()

        harnessClient.discoverHarnessOnLocalNetwork(port: appState.lastKnownHarnessPort) { _ in }
    }

    private var playLiveContent: some View {
        let routeActive = appState.isExternalAudioRouteActive
            || appState.isCablePathSatisfied
            || appState.isCableRouteSimulated

        return VStack(alignment: .leading, spacing: 18) {
            Text("Cable Required")
                .playSans(18, weight: .semibold)
                .foregroundColor(.white)

            HStack(spacing: 14) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .accessibilityHidden(true)
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                    .accessibilityHidden(true)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .accessibilityHidden(true)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, 16)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }

            Text("No sound will be output unless you are connected to THE TUB USB-C.")
                .playSans(11, weight: .semibold)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                externalAudioRouteMonitor.refreshRouteState()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Check again")
                }
                .playSans(11, weight: .semibold)
                .foregroundColor(.gray)
            }
            .accessibilityLabel(Text("Check cable connection"))
            .accessibilityHint(Text("Refresh cable detection"))

            Button(action: {
                if !routeActive {
                    appState.markCablePathSatisfied()
                    addToast("✓ Cable confirmed manually.", style: .success)
                }
                appState.forcePresentEntryGate = false
                appState.requestTabNavigation(.play)
            }) {
                Text(routeActive ? "Cable Ready" : "I'm Connected")
                    .playSans(20, weight: .heavy)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color(UIColor(named: "GlyphGreen") ?? .green))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(routeActive ? "Continue to play" : "Confirm cable connected"))
            .accessibilityHint(Text("Proceed even if iOS does not expose a cable route"))

            Button(action: {
                showCableHelp.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showCableHelp ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(showCableHelp ? "Hide cable help" : "Need help finding the cable?")
                }
                .playSans(11, weight: .semibold)
                .foregroundColor(.gray)
            }
            .accessibilityLabel(Text(showCableHelp ? "Hide cable help" : "Show cable help"))
            .accessibilityHint(Text("Toggle detailed cable connection steps"))

            if showCableHelp {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "1.circle.fill")
                            .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                        Text("Connect phone to USB-C audio adapter/cable")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "2.circle.fill")
                            .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                        Text("Route analog TRS line to THE TUB input")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "3.circle.fill")
                            .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                        Text("Press 'Check again' when ready")
                    }
                }
                .playSans(10)
                .foregroundColor(.gray)
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(4)
            }

            secondaryNavRow(backAction: {
                appState.resetEntryFlow()
                step = .chooseIntent
            })
        }
    }

    private var feedBankContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Steer the ML")
                .playSans(18, weight: .semibold)
                .foregroundColor(.white)

            Text("Link to THE TUB harness to submit material into the exhibition queue.")
                .playSans(11)
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 8) {
                Text("Harness Link")
                    .playSans(10, weight: .bold)
                    .foregroundColor(.gray)

                Text("AUTO DISCOVERY ENABLED")
                    .playMono(11, weight: .semibold)
                    .foregroundColor(.white)

                Text("NO ADDRESS OR PORT ENTRY REQUIRED")
                    .playMono(10)
                    .foregroundColor(.gray)
            }

            Button(action: {
                startHarnessLinkAttempt()
            }) {
                ZStack {
                    gateCommand(
                        title: isAttemptingLocalConnect ? "Connecting…" : "Retry Harness Link",
                        subtitle: "Resolve harness automatically."
                    )
                    
                    if isAttemptingLocalConnect {
                        HStack {
                            Spacer()
                            Image(systemName: "hourglass")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black)
                                .rotationEffect(.degrees(loaderRotation))
                                .padding(.trailing, 14)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .disabled(isAttemptingLocalConnect)
            .accessibilityLabel(Text("Connect to harness"))
            .accessibilityHint(Text("Establish harness link to THE TUB server"))
            .accessibilityValue(Text(isAttemptingLocalConnect ? "Connecting" : "Ready"))

            if let handshakeStatus {
                Text(handshakeStatus)
                    .playMono(10)
                    .foregroundColor(.gray)
            }

            connectionStatusLine

            secondaryNavRow(backAction: {
                appState.resetEntryFlow()
                hasAttemptedAutoHarnessConnect = false
                step = .chooseIntent
            })
        }
    }

    private func ensureAutoHarnessLinkAttemptIfNeeded() {
        guard step == .feedBank else { return }
        guard appState.harnessConnectionState != .connected else { return }
        guard !isAttemptingLocalConnect else { return }
        guard !hasAttemptedAutoHarnessConnect else { return }

        hasAttemptedAutoHarnessConnect = true
        startHarnessLinkAttempt()
    }

    private func startHarnessLinkAttempt() {
        let preferredHost = appState.lastKnownHarnessHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = preferredHost.isEmpty ? "tub-harness.local" : preferredHost
        let parsedPort = appState.lastKnownHarnessPort

        appState.updateHarnessAddress(host: host, port: parsedPort)
        isAttemptingLocalConnect = true
        handshakeStatus = nil
        loaderRotation = 0
        withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
            loaderRotation = 360
        }

        harnessClient.connectToHarness(host: host, port: parsedPort)
        harnessClient.preflightHandshake(host: host, port: parsedPort) { result in
            switch result {
            case .success(let payload):
                let preferredHost = payload.hostHints?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedHost = (preferredHost?.isEmpty == false) ? preferredHost! : host
                let resolvedPort = payload.audiencePort
                    .flatMap { UInt16(exactly: $0) }
                    ?? parsedPort

                if (resolvedHost != host || resolvedPort != parsedPort), appState.harnessConnectionState != .connected {
                    appState.updateHarnessAddress(host: resolvedHost, port: resolvedPort)
                    harnessClient.disconnect()
                    harnessClient.connectToHarness(host: resolvedHost, port: resolvedPort)
                }

                let announcedPort = String(resolvedPort)
                if let preferredHost {
                    handshakeStatus = "Handshake OK (\(payload.status.uppercased())) / \(preferredHost):\(announcedPort)"
                } else {
                    handshakeStatus = "Handshake OK (\(payload.status.uppercased())) / audience port \(announcedPort)"
                }
            case .failure(let error):
                guard
                    harnessClient.shouldAttemptLocalDiscovery(for: host),
                    appState.harnessConnectionState != .connected
                else {
                    handshakeStatus = "Handshake unavailable (\(error.localizedDescription)). Socket link still attempting."
                    return
                }

                handshakeStatus = "Handshake unavailable (\(error.localizedDescription)). Scanning local network…"
                harnessClient.discoverHarnessOnLocalNetwork(port: parsedPort) { discovery in
                    switch discovery {
                    case .success(let result):
                        let discoveredPort = result.payload.audiencePort
                            .flatMap { UInt16(exactly: $0) }
                            ?? parsedPort
                        appState.updateHarnessAddress(host: result.host, port: discoveredPort)
                        harnessClient.disconnect()
                        harnessClient.connectToHarness(host: result.host, port: discoveredPort)
                        handshakeStatus = "Harness discovered at \(result.host):\(discoveredPort). Connecting…"
                    case .failure(let discoveryError):
                        handshakeStatus = "Handshake unavailable (\(error.localizedDescription)). Local scan failed (\(discoveryError.localizedDescription))."
                    }
                }
            }
        }
    }

    private var connectionStatusLine: some View {
        Group {
            switch appState.harnessConnectionState {
            case .connected:
                Text("Live link established.")
                    .playMono(10)
                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
            case .connecting:
                Text("Attempting harness link…")
                    .playMono(10)
                    .foregroundColor(.gray)
            case .error(let message):
                Text(message)
                    .playMono(10)
                    .foregroundColor(.red)
            case .disconnected:
                Text("Harness link not established yet.")
                    .playMono(10)
                    .foregroundColor(.gray)
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 18) {
            gateStatusPill(
                label: "CABLE",
                active: appState.isExternalAudioRouteActive
                    || appState.isCablePathSatisfied
                    || appState.isCableRouteSimulated
            )
            .offset(x: slideInPills ? 0 : -20)
            .opacity(slideInPills ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.1), value: slideInPills)

            gateStatusPill(
                label: "HARNESS",
                active: appState.isBackendPathSatisfied
            )
            .offset(x: slideInPills ? 0 : -20)
            .opacity(slideInPills ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.2), value: slideInPills)

            gateStatusPill(
                label: "SESSION",
                active: appState.sessionId != nil
            )
            .offset(x: slideInPills ? 0 : -20)
            .opacity(slideInPills ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.3), value: slideInPills)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func secondaryNavRow(backAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: backAction) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Choose another way to enter")
                }
                .playSans(10, weight: .semibold)
                .foregroundColor(.gray)
            }
            .accessibilityLabel(Text("Go back"))
            .accessibilityHint(Text("Return to entry intent selection"))

            Spacer()
        }
    }

    @ViewBuilder
    private func gateCommand(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .playSans(14, weight: .bold)
                .foregroundColor(.black)

            Text(subtitle)
                .playSans(10)
                .foregroundColor(.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(UIColor(named: "GlyphGreen") ?? .green))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func gateStatusPill(label: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color(UIColor(named: "GlyphGreen") ?? .green) : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
                .scaleEffect(active ? 1.2 : 1.0)
                .animation(
                    active ? Animation.easeInOut(duration: 1.2)
                        .repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
                    value: active
                )
                .accessibilityHidden(true)

            Text(label)
                .playMono(10, weight: .semibold)
                .foregroundColor(active ? Color(UIColor(named: "GlyphGreen") ?? .green) : .gray)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(4)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(active ? "Ready" : "Not ready"))
        .accessibilityHint(Text("\(label) status indicator"))
    }
    
    @ViewBuilder
    private func gateCommandWithIcon(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.black)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .playSans(14, weight: .bold)
                    .foregroundColor(.black)

                Text(subtitle)
                    .playSans(10)
                    .foregroundColor(.black.opacity(0.75))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(UIColor(named: "GlyphGreen") ?? .green))
        .cornerRadius(4)
    }
    
}

struct ConnectionRequiredOverlay: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    let preferredIntent: EntryIntent?
    @State private var hasStartedQuietReconnect = false
    @State private var quietReconnectSuppressedUntil: Date?
    @State private var lastQuietReconnectAt: Date?
    private let quietReconnectWindow: TimeInterval = 5.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()

            if shouldRenderGateContent {
                VStack(alignment: .leading, spacing: 14) {
                    Text(preferredIntent == .feedBank ? "Harness Link Required" : "Cable Route Required")
                        .playSans(18, weight: .bold)
                        .foregroundColor(.white)

                    Text(preferredIntent == .feedBank
                         ? "STEER needs a live harness link before controls can be used."
                         : "PLAY needs an external audio route before controls can be used.")
                        .playSans(11)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)

                    if isReconnecting {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color(UIColor(named: "GlyphGreen") ?? .green))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("RECONNECTING HARNESS…")
                                    .playMono(11, weight: .semibold)
                                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                                Text("HOLDING GATE WHILE LINK RECOVERS.")
                                    .playMono(10)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text(statusText)
                            .playMono(10, weight: .semibold)
                            .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                    }

                    Button(action: primaryAction) {
                        Text(primaryActionLabel)
                            .playSans(12, weight: .bold)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color(UIColor(named: "GlyphGreen") ?? .green))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connection.overlay.primary")

                    Button(action: {
                        appState.resetEntryFlow()
                    }) {
                        Text("Return to Entry Ritual")
                            .playSans(11, weight: .semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connection.overlay.back")
                }
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
                .padding(.horizontal, 20)
            } else if isQuietReconnectPhase {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color(UIColor(named: "GlyphGreen") ?? .green))
                    Text("RECONNECTING HARNESS…")
                        .playMono(12, weight: .semibold)
                        .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                    Text("HOLDING GATE WHILE LINK RECOVERS.")
                        .playMono(10)
                        .foregroundColor(.gray)
                }
                .padding(16)
            }
        }
        .allowsHitTesting(shouldBlockInteraction)
        .onAppear {
            beginQuietReconnectIfNeeded(force: true)
        }
        .onChange(of: appState.harnessConnectionState) { _, state in
            guard preferredIntent == .feedBank else { return }
            switch state {
            case .connected:
                quietReconnectSuppressedUntil = nil
            case .connecting:
                hasStartedQuietReconnect = true
                quietReconnectSuppressedUntil = Date().addingTimeInterval(quietReconnectWindow)
            case .disconnected, .error:
                if !shouldRenderGateContent {
                    beginQuietReconnectIfNeeded(force: false)
                }
            }
        }
        .task(id: preferredIntent == .feedBank) {
            guard preferredIntent == .feedBank else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .connected = appState.harnessConnectionState {
                    continue
                }
                beginQuietReconnectIfNeeded(force: false)
            }
        }
    }

    private var isReconnecting: Bool {
        if case .connecting = appState.harnessConnectionState { return true }
        return false
    }

    private var primaryActionLabel: String {
        preferredIntent == .feedBank ? "Reconnect Harness" : "Check Audio Route"
    }

    private var statusText: String {
        if preferredIntent == .feedBank {
            switch appState.harnessConnectionState {
            case .connected:
                return "HARNESS CONNECTED."
            case .connecting:
                return "ATTEMPTING HARNESS LINK…"
            case .error(let message):
                return message.uppercased()
            case .disconnected:
                return "HARNESS OFFLINE."
            }
        }
        return appState.externalAudioRouteDescription.uppercased()
    }

    private func primaryAction() {
        if preferredIntent == .feedBank {
            beginQuietReconnectIfNeeded(force: true)
            return
        }

        externalAudioRouteMonitor.refreshRouteState()
    }

    private var shouldRenderGateContent: Bool {
        guard preferredIntent == .feedBank else { return true }
        guard hasStartedQuietReconnect else { return false }
        if case .connected = appState.harnessConnectionState { return false }
        if case .connecting = appState.harnessConnectionState { return false }
        if let quietReconnectSuppressedUntil, Date() < quietReconnectSuppressedUntil {
            return false
        }
        return true
    }

    private var isQuietReconnectPhase: Bool {
        preferredIntent == .feedBank && !shouldRenderGateContent
    }

    private var shouldBlockInteraction: Bool {
        if preferredIntent == .feedBank {
            return true
        }
        return shouldRenderGateContent
    }

    private func beginQuietReconnectIfNeeded(force: Bool) {
        guard preferredIntent == .feedBank else { return }
        if !force {
            if case .connected = appState.harnessConnectionState { return }
            if case .connecting = appState.harnessConnectionState { return }
            if let lastQuietReconnectAt, Date().timeIntervalSince(lastQuietReconnectAt) < 1.6 {
                return
            }
        }

        let host = appState.lastKnownHarnessHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "tub-harness.local" : host
        let resolvedPort = appState.lastKnownHarnessPort
        hasStartedQuietReconnect = true
        lastQuietReconnectAt = Date()
        quietReconnectSuppressedUntil = Date().addingTimeInterval(quietReconnectWindow)
        appState.syncHarnessState(.connecting)
        harnessClient.connectToHarness(host: resolvedHost, port: resolvedPort)
        harnessClient.preflightHandshake(host: resolvedHost, port: resolvedPort) { result in
            guard case .success(let payload) = result else { return }
            let hintedHost = payload.hostHints?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let handshakeHost = (hintedHost?.isEmpty == false) ? hintedHost! : resolvedHost
            let handshakePort = payload.audiencePort.flatMap { UInt16(exactly: $0) } ?? resolvedPort
            guard handshakeHost != resolvedHost || handshakePort != resolvedPort else { return }
            appState.updateHarnessAddress(host: handshakeHost, port: handshakePort)
            harnessClient.disconnect(manual: false)
            harnessClient.connectToHarness(host: handshakeHost, port: handshakePort)
        }
    }
}

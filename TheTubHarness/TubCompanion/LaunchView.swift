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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
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
    private let bootDuration: TimeInterval = 2.95

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let progress = min(1, elapsed / bootDuration)
            let revealCount = max(1, min(transcriptLines.count, Int((progress * Double(transcriptLines.count)).rounded(.up))))
            let cursorOn = (Int((elapsed * 2).rounded(.down)) % 2) == 0
            let spinner = spinnerFrames[Int((elapsed * 12).rounded(.down)) % spinnerFrames.count]
            let litSegments = min(bootSegments, max(1, Int((progress * Double(bootSegments)).rounded(.down))))
            let pulse = 0.65 + 0.35 * sin((elapsed + pulseSeed) * 4.2)
            let activeLineIndex = min(max(0, revealCount - 1), Int((elapsed * 6).rounded(.down)) % max(1, revealCount))
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

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("TUBCORP ENTERPRISE SCLI // THE TUB")
                            .launchMono(11, weight: .semibold)
                            .foregroundStyle(Color.white.opacity(0.92))
                        Spacer()
                        Text("BOOT \(spinner) 00:\(String(format: "%02d", systemSeconds)):\(String(format: "%03d", systemMillis))")
                            .launchMono(10, weight: .bold)
                            .foregroundStyle(Color.white.opacity(0.64 + statusPulse * 0.3))
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(height: 1)
                        .padding(.top, 10)

                    Spacer(minLength: 24)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("THE TUB")
                            .launchMono(54, weight: .black)
                            .tracking(2.6)
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)
                            .scaleEffect(reduceMotion ? 1 : (0.995 + 0.005 * statusPulse), anchor: .leading)

                        Text("LIVE CONTROL SHELL // READYING STAGE")
                            .launchMono(12, weight: .semibold)
                            .foregroundStyle(Color.white.opacity(0.74))

                        HStack(spacing: 10) {
                            Text("SESSION \(sessionToken)")
                                .launchMono(10, weight: .semibold)
                                .foregroundStyle(Color.white.opacity(0.64))
                            Text("NODE IOS")
                                .launchMono(10, weight: .semibold)
                                .foregroundStyle(Color.white.opacity(0.64))
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
                        ForEach(Array(transcriptLines.prefix(revealCount).enumerated()), id: \.offset) { index, line in
                            HStack(spacing: 8) {
                                Text(">")
                                    .launchMono(10, weight: .bold)
                                    .foregroundStyle(index == activeLineIndex ? Color.white : Color.white.opacity(0.7))
                                Text(line)
                                    .launchMono(10, weight: .medium)
                                    .foregroundStyle(index == activeLineIndex ? Color.white : Color.white.opacity(0.74))
                                Spacer(minLength: 0)
                            }
                            .opacity(index == activeLineIndex ? 1 : 0.72)
                            .animation(.easeInOut(duration: 0.08), value: activeLineIndex)
                        }
                    }
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
                            .launchMono(10, weight: .bold)
                            .foregroundStyle(Color.white.opacity(0.92))
                        Text(cursorOn ? "_" : " ")
                            .launchMono(10, weight: .bold)
                            .foregroundStyle(Color.white.opacity(0.82))
                        Spacer()
                        Text("SYNC \(Int((progress * 100).rounded(.down)))%")
                            .launchMono(10, weight: .semibold)
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .padding(.top, 8)

                    Text("OPERATING PROFILE // PARTICIPANT CONTROL TERMINAL")
                        .launchMono(9, weight: .regular)
                        .foregroundStyle(Color.white.opacity(0.44))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .opacity(reduceMotion ? 1 : (0.9 + 0.1 * pulse))
            }
        }
        .onAppear {
            startedAt = Date()
            sessionToken = TubLaunchScreenView.makeSessionToken()
            pulseSeed = Double.random(in: 0.2...1.1)
            tracerX = -280
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                tracerX = 280
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("THE TUB is initializing")
        .accessibilityIdentifier("launch.screen")
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

private extension View {
    func launchMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        self.font(IBMPlexMonoFont.font(weight.toPlexVariant, size: size))
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

private extension Font.Weight {
    var toPlexVariant: IBMPlexMonoFont.Variant {
        switch self {
        case .bold, .black, .heavy:
            return .bold
        case .semibold:
            return .semibold
        case .medium:
            return .medium
        case .light, .thin, .ultraLight:
            return .light
        default:
            return .regular
        }
    }
}

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
    @State private var showPlayLiveConfirmation = false
    @State private var fadeInButtons = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var slideInPills = false
    @State private var loaderRotation: Double = 0
    @State private var handshakeStatus: String?
    @State private var hasAttemptedAutoHarnessConnect = false

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

                VStack(spacing: 10) {
                    Text("THE TUB")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))

                    Text("Entry Ritual")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }

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
        }
        .overlay(
            Group {
                if showPlayLiveConfirmation {
                    playLiveConfirmationModal
                }
            }
        )
        .onAppear {
            if let preferredIntent {
                step = preferredIntent == .playLive ? .playLive : .feedBank
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
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text("Choose one path. You can change it later.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)

            Button(action: {
                showPlayLiveConfirmation = true
            }) {
                gateCommandWithIcon(
                    icon: "waveform.circle",
                    title: "PLAY INTO THE TUB",
                    subtitle: "Use the cable. Immediate live path."
                )
            }
            .opacity(fadeInButtons ? 1 : 0)
            .offset(y: fadeInButtons ? 0 : 10)
            .animation(.easeOut(duration: 0.4).delay(0.1), value: fadeInButtons)
            .accessibilityLabel(Text("Play into the tub"))
            .accessibilityHint(Text("Enter live play mode using USB-C cable connection"))

            Button(action: {
                appState.chooseEntryIntent(.feedBank)
                step = .feedBank
            }) {
                gateCommandWithIcon(
                    icon: "arrow.up.doc",
                    title: "STEER THE TUB ML",
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
                    appState.chooseEntryIntent(last)
                    step = last == .playLive ? .playLive : .feedBank
                }) {
                    Text(last == .playLive ? "Resume live cable session" : "Reconnect to harness link")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var playLiveContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PLAY INTO THE TUB")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text("Connect the USB-C audio cable. This path uses the phone’s external audio route.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)

            gateCommand(
                title: (appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) ? "CABLE READY" : "CONNECT USB-C CABLE",
                subtitle: (appState.isExternalAudioRouteActive || appState.isCablePathSatisfied)
                    ? "External audio route detected."
                    : "Waiting for external audio route."
            )

            HStack(spacing: 8) {
                Image(systemName: (appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor((appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) ? Color(UIColor(named: "GlyphGreen") ?? .green) : .red)
                    .font(.system(size: 12, weight: .semibold))

                Text(appState.externalAudioRouteDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor((appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) ? Color(UIColor(named: "GlyphGreen") ?? .green) : .gray)
            }

            Button(action: {
                externalAudioRouteMonitor.refreshRouteState()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Check again")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
            }
            .accessibilityLabel(Text("Check cable connection"))
            .accessibilityHint(Text("Refresh cable detection"))

            if !(appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) {
                Button(action: {
                    appState.markCablePathSatisfied()
                    addToast("✓ Cable confirmed manually.", style: .success)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("I'M CONNECTED")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                }
                .accessibilityLabel(Text("Confirm cable connected"))
                .accessibilityHint(Text("Proceed even if iOS does not expose a cable route"))
            }

            Button(action: {
                showCableHelp.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showCableHelp ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(showCableHelp ? "Hide cable help" : "Need help finding the cable?")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 10, design: .monospaced))
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
            Text("FEED THE SOUND BANK")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text("Link to THE TUB harness to submit material into the exhibition queue.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 8) {
                Text("HARNESS LINK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                Text("AUTO DISCOVERY ENABLED")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)

                Text("NO ADDRESS OR PORT ENTRY REQUIRED")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }

            Button(action: {
                startHarnessLinkAttempt()
            }) {
                ZStack {
                    gateCommand(
                        title: isAttemptingLocalConnect ? "CONNECTING…" : "RETRY HARNESS LINK",
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
                    .font(.system(size: 10, design: .monospaced))
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
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
            case .connecting:
                Text("Attempting harness link…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            case .error(let message):
                Text(message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
            case .disconnected:
                Text("Harness link not established yet.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 18) {
            gateStatusPill(
                label: "CABLE",
                active: appState.isExternalAudioRouteActive || appState.isCablePathSatisfied
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.black)

            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)

                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.black.opacity(0.75))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(UIColor(named: "GlyphGreen") ?? .green))
        .cornerRadius(4)
    }
    
    private var playLiveConfirmationModal: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                    
                    Text("PLAY INTO THE TUB")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("You're about to enter live play mode. Make sure:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("USB-C cable connected", systemImage: "checkmark.circle")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor((appState.isExternalAudioRouteActive || appState.isCablePathSatisfied) ? Color(UIColor(named: "GlyphGreen") ?? .green) : .gray)
                        
                        Label("Audio input routed correctly", systemImage: "checkmark.circle")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(4)
                }
                
                HStack(spacing: 12) {
                    Button(action: {
                        showPlayLiveConfirmation = false
                    }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(4)
                    }
                    .accessibilityLabel(Text("Cancel"))
                    .accessibilityHint(Text("Close this confirmation dialog"))
                    
                    Button(action: {
                        appState.chooseEntryIntent(.playLive)
                        step = .playLive
                        showPlayLiveConfirmation = false
                        addToast("✓ Entering live mode", style: .success)
                    }) {
                        Text("ENTER")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color(UIColor(named: "GlyphGreen") ?? .green))
                            .cornerRadius(4)
                    }
                    .accessibilityLabel(Text("Enter live mode"))
                    .accessibilityHint(Text("Proceed to live play mode"))
                }
            }
            .padding(20)
            .background(BrandingColors.darkBackground)
            .cornerRadius(8)
            .padding(20)
        }
    }
}

struct ConnectionRequiredOverlay: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    let preferredIntent: EntryIntent?

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

        }
    }
}

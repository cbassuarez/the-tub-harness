//
//  TubCompanionApp.swift
//  TubCompanion
//
//  Main iOS companion app entry point.
//  Manages session state, harness connection, tab navigation.
//

import SwiftUI
import Combine

@main
struct TubCompanionApp: App {
    @StateObject private var externalAudioRouteMonitor = ExternalAudioRouteMonitor()
    @StateObject private var appState = TubCompanionAppState()
    @StateObject private var harnessClient = HarnessClient()
    
    var body: some Scene {
        WindowGroup {
            CompanionRootView(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor
            )
            #if targetEnvironment(macCatalyst)
            .frame(minWidth: 980, minHeight: 700)
            #endif
            .environmentObject(appState)
            .environmentObject(harnessClient)
            .environmentObject(externalAudioRouteMonitor)
            .onAppear {
                appState.initializeSession()
                if let sessionId = appState.sessionId {
                    harnessClient.setSessionId(sessionId)
                }
                appState.syncExternalAudioRoute(
                    isActive: externalAudioRouteMonitor.isExternalAudioRouteActive,
                    description: externalAudioRouteMonitor.routeDescription,
                    isDebugOutputSimulated: externalAudioRouteMonitor.isDebugOutputSimulated,
                    isCableRouteSimulated: externalAudioRouteMonitor.isCableRouteSimulated
                )
            }
            .onReceive(harnessClient.$connectionState.receive(on: RunLoop.main)) { state in
                appState.syncHarnessState(state)
            }
            .onReceive(externalAudioRouteMonitor.$isExternalAudioRouteActive.receive(on: RunLoop.main)) { _ in
                appState.syncExternalAudioRoute(
                    isActive: externalAudioRouteMonitor.isExternalAudioRouteActive,
                    description: externalAudioRouteMonitor.routeDescription,
                    isDebugOutputSimulated: externalAudioRouteMonitor.isDebugOutputSimulated,
                    isCableRouteSimulated: externalAudioRouteMonitor.isCableRouteSimulated
                )
            }
            .onReceive(externalAudioRouteMonitor.$routeDescription.receive(on: RunLoop.main)) { _ in
                appState.syncExternalAudioRoute(
                    isActive: externalAudioRouteMonitor.isExternalAudioRouteActive,
                    description: externalAudioRouteMonitor.routeDescription,
                    isDebugOutputSimulated: externalAudioRouteMonitor.isDebugOutputSimulated,
                    isCableRouteSimulated: externalAudioRouteMonitor.isCableRouteSimulated
                )
            }
            .onReceive(externalAudioRouteMonitor.$isDebugOutputSimulated.receive(on: RunLoop.main)) { _ in
                appState.syncExternalAudioRoute(
                    isActive: externalAudioRouteMonitor.isExternalAudioRouteActive,
                    description: externalAudioRouteMonitor.routeDescription,
                    isDebugOutputSimulated: externalAudioRouteMonitor.isDebugOutputSimulated,
                    isCableRouteSimulated: externalAudioRouteMonitor.isCableRouteSimulated
                )
            }
            .onReceive(externalAudioRouteMonitor.$isCableRouteSimulated.receive(on: RunLoop.main)) { _ in
                appState.syncExternalAudioRoute(
                    isActive: externalAudioRouteMonitor.isExternalAudioRouteActive,
                    description: externalAudioRouteMonitor.routeDescription,
                    isDebugOutputSimulated: externalAudioRouteMonitor.isDebugOutputSimulated,
                    isCableRouteSimulated: externalAudioRouteMonitor.isCableRouteSimulated
                )
            }
        }
    }
}

enum EntryIntent: String, Codable {
    case playLive
    case feedBank

    var title: String {
        switch self {
        case .playLive: return "Play into THE TUB"
        case .feedBank: return "Feed the sound bank"
        }
    }
}

enum FeatureGate {
    case steer
    case play
}

enum SteerAccessState: Equatable {
    case locked
    case inChallenge
    case cooldown(until: Date)
    case grantedAnimating
    case unlocked

    var chipLabel: String {
        switch self {
        case .locked: return "LOCKED"
        case .inChallenge: return "CHALLENGE"
        case .cooldown: return "COOLDOWN"
        case .grantedAnimating: return "GRANTING"
        case .unlocked: return "UNLOCKED"
        }
    }
}

struct SteerHackRoundSpec: Equatable {
    let targetToken: String
    let stripSpeed: Double
    let windowTolerance: Int
}

struct SteerHackSession: Equatable {
    var roundIndex: Int
    var strikes: Int
    var startedAt: Date
    var cooldownUntil: Date?
    var lastInputAt: Date?
}

enum AppTab: String, Hashable {
    case steer
    case play
    case learn
    case settings
}

enum ShellLayoutClass: String, Equatable {
    case compact
    case regular
    case wide

    static func classify(width: CGFloat, metrics: ShellLayoutMetrics = .default) -> ShellLayoutClass {
        if width < metrics.compactUpperBound {
            return .compact
        }
        if width < metrics.regularUpperBound {
            return .regular
        }
        return .wide
    }
}

struct ShellLayoutMetrics: Equatable {
    let compactUpperBound: CGFloat
    let regularUpperBound: CGFloat
    let railWidthRegular: CGFloat
    let railWidthWide: CGFloat
    let inspectorWidthRegular: CGFloat
    let inspectorWidthWide: CGFloat
    let paneSpacing: CGFloat

    static let `default` = ShellLayoutMetrics(
        compactUpperBound: 700,
        regularUpperBound: 1024,
        railWidthRegular: 140,
        railWidthWide: 152,
        inspectorWidthRegular: 312,
        inspectorWidthWide: 360,
        paneSpacing: 12
    )
}

@MainActor
final class ShellLayoutModel: ObservableObject {
    @Published private(set) var layoutClass: ShellLayoutClass = .compact
    @Published private(set) var measuredWidth: CGFloat = 0
    @Published private(set) var isRegularInspectorVisible: Bool

    let metrics: ShellLayoutMetrics

    private let defaults = UserDefaults.standard
    private let persistRegularInspectorVisibility: Bool
    private static let regularInspectorVisibilityKey = "ShellRegularInspectorVisible"

    init(
        metrics: ShellLayoutMetrics = .default,
        persistRegularInspectorVisibility: Bool = true
    ) {
        self.metrics = metrics
        self.persistRegularInspectorVisibility = persistRegularInspectorVisibility
        if persistRegularInspectorVisibility {
            self.isRegularInspectorVisible = defaults.bool(forKey: Self.regularInspectorVisibilityKey)
        } else {
            self.isRegularInspectorVisible = false
        }
    }

    var usesLeftRail: Bool {
        layoutClass != .compact
    }

    var showsSecondaryPane: Bool {
        switch layoutClass {
        case .compact:
            return false
        case .regular:
            return isRegularInspectorVisible
        case .wide:
            return true
        }
    }

    var railWidth: CGFloat {
        layoutClass == .wide ? metrics.railWidthWide : metrics.railWidthRegular
    }

    var inspectorWidth: CGFloat {
        layoutClass == .wide ? metrics.inspectorWidthWide : metrics.inspectorWidthRegular
    }

    func update(for width: CGFloat) {
        measuredWidth = width
        let nextClass = ShellLayoutClass.classify(width: width, metrics: metrics)
        if nextClass != layoutClass {
            layoutClass = nextClass
        }
    }

    func toggleInspectorPane() {
        guard layoutClass == .regular else { return }
        isRegularInspectorVisible.toggle()
        if persistRegularInspectorVisibility {
            defaults.set(isRegularInspectorVisible, forKey: Self.regularInspectorVisibilityKey)
        }
    }
}

struct SteerInspectorState: Equatable {
    let linkStatus: String
    let descriptorSource: String
    let mode: String
    let access: String
    let activeDescriptor: String
    let preferenceCount: Int
    let lastPreferenceEvent: String
}

struct PlayInspectorState: Equatable {
    let cableStatus: String
    let routeDescription: String
    let sessionId: String
    let contributionCount: Int
    let debugOutput: String
}

struct LearnInspectorState: Equatable {
    let linkStatus: String
    let stageFeed: String
    let lastReturnMode: String
    let lastReturnChapter: String
}

struct SettingsInspectorState: Equatable {
    let harnessStatus: String
    let stageFeed: String
    let sessionId: String
    let lastSuccessfulSessionAt: String
}

struct CompanionRootView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    @State private var showLaunchScreen = true
    @State private var didScheduleLaunchDismiss = false
    @State private var isPlaySurfaceReady = false

    var body: some View {
        ZStack {
            if !appState.shouldPresentConnectionGate {
                MainShellView(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor,
                    onPlaySurfaceReady: {
                        isPlaySurfaceReady = true
                    }
                )
            }
            if appState.shouldPresentConnectionGate {
                ConnectionGateView(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor,
                    presentation: .fullScreen,
                    preferredIntent: appState.bypassPreferredEntryIntentOnce ? nil : appState.lastEntryIntent
                )
                .transition(.opacity)
                .zIndex(10)
            }
            if showLaunchScreen {
                TubLaunchScreenView()
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .onAppear {
            guard !didScheduleLaunchDismiss else { return }
            didScheduleLaunchDismiss = true

            #if DEBUG
            let shouldSkip = ProcessInfo.processInfo.arguments.contains("-DEBUG_SKIP_CUSTOM_LAUNCH")
            #else
            let shouldSkip = false
            #endif

            if shouldSkip {
                showLaunchScreen = false
                return
            }

            Task { @MainActor in
                let minLaunchDuration: UInt64 = 2_900_000_000
                try? await Task.sleep(nanoseconds: minLaunchDuration)
                let readinessDeadline = Date().addingTimeInterval(1.8)
                while !isPlaySurfaceReady, Date() < readinessDeadline {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                withAnimation(.easeOut(duration: 0.35)) {
                    showLaunchScreen = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: appState.shouldPresentConnectionGate)
        .animation(.easeOut(duration: 0.24), value: showLaunchScreen)
    }
}

struct MainShellView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    var onPlaySurfaceReady: () -> Void = {}
    @State private var selectedTab: AppTab = .steer
    @State private var isPlaySurfacePrimed = false
    @State private var didApplyInitialTab = false
    @StateObject private var shellLayout = ShellLayoutModel()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if shellLayout.layoutClass == .compact {
                    compactShell
                } else {
                    wideShell(safeAreaInsets: proxy.safeAreaInsets)
                }
                if selectedTab != .play, !isPlaySurfacePrimed {
                    PlayTabHostView(
                        appState: appState,
                        harnessClient: harnessClient,
                        externalAudioRouteMonitor: externalAudioRouteMonitor,
                        isActivated: true,
                        isPrimed: $isPlaySurfacePrimed
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                shellLayout.update(for: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                shellLayout.update(for: width)
            }
        }
        .onAppear {
            guard !didApplyInitialTab else { return }
            didApplyInitialTab = true
            if let requested = appState.tabNavigationRequest {
                selectTab(requested)
                appState.consumeTabNavigationRequest()
            } else {
                let initialTab = appState.initialTabSelection()
                selectTab(initialTab)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            appState.persistSelectedTab(tab)
        }
        .onChange(of: appState.tabNavigationRequest) { _, requested in
            guard let requested else { return }
            selectTab(requested)
            appState.consumeTabNavigationRequest()
        }
        .onChange(of: isPlaySurfacePrimed) { _, primed in
            guard primed else { return }
            onPlaySurfaceReady()
        }
    }

    private var compactShell: some View {
        ZStack {
            currentTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                CommandSignalRule()
                ShellCommandNavigator(
                    selectedTab: selectedTab,
                    layoutClass: .compact,
                    appState: appState,
                    harnessClient: harnessClient,
                    onSelect: { tab in
                        selectTab(tab)
                    },
                    showsInspectorToggle: false,
                    inspectorVisible: false,
                    onToggleInspector: nil
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .background(Color.black.opacity(0.96))
        }
    }

    private func wideShell(safeAreaInsets: EdgeInsets) -> some View {
        HStack(spacing: shellLayout.metrics.paneSpacing) {
            ShellCommandNavigator(
                selectedTab: selectedTab,
                layoutClass: shellLayout.layoutClass,
                appState: appState,
                harnessClient: harnessClient,
                onSelect: { tab in
                    selectTab(tab)
                },
                showsInspectorToggle: shellLayout.layoutClass == .regular,
                inspectorVisible: shellLayout.showsSecondaryPane,
                onToggleInspector: {
                    shellLayout.toggleInspectorPane()
                }
            )
            .frame(width: shellLayout.railWidth)
            .accessibilityIdentifier("shell.nav.rail")

            Rectangle()
                .fill(Color.white.opacity(0.13))
                .frame(width: 1)

            currentTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("shell.content.primary")

            if shellLayout.showsSecondaryPane {
                Rectangle()
                    .fill(Color.white.opacity(0.13))
                    .frame(width: 1)

                ShellInspectorPane(
                    selectedTab: selectedTab,
                    steerState: steerInspectorState,
                    playState: playInspectorState,
                    learnState: learnInspectorState,
                    settingsState: settingsInspectorState,
                    onSteerLess: {
                        harnessClient.sendIntensityNudge(direction: .less, intensity: 1, sessionId: appState.sessionId)
                        appState.recordPreference(
                            AudiencePreferenceEvent(
                                sessionId: appState.sessionId ?? "unknown",
                                eventType: .lessAction,
                                intensity: 1
                            )
                        )
                    },
                    onSteerMore: {
                        harnessClient.sendIntensityNudge(direction: .more, intensity: 1, sessionId: appState.sessionId)
                        appState.recordPreference(
                            AudiencePreferenceEvent(
                                sessionId: appState.sessionId ?? "unknown",
                                eventType: .moreAction,
                                intensity: 1
                            )
                        )
                    },
                    onJumpSteer: {
                        selectTab(.steer)
                    },
                    onJumpPlay: {
                        selectTab(.play)
                    }
                )
                .frame(width: shellLayout.inspectorWidth)
                .accessibilityIdentifier("shell.inspector")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, max(safeAreaInsets.top + 8, 12))
        .padding(.bottom, max(safeAreaInsets.bottom + 10, 12))
    }

    @ViewBuilder
    private var currentTabView: some View {
        switch selectedTab {
        case .steer:
            SteerView(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor
            )
            .accessibilityIdentifier("shell.content.steer")
        case .play:
            PlayTabHostView(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor,
                isActivated: true,
                isPrimed: $isPlaySurfacePrimed
            )
            .accessibilityIdentifier("shell.content.play")
        case .learn:
            ReadLearnView(appState: appState, harnessClient: harnessClient)
                .accessibilityIdentifier("shell.content.learn")
        case .settings:
            SettingsView(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor
            )
                .accessibilityIdentifier("shell.content.settings")
        }
    }

    private func selectTab(_ tab: AppTab) {
        if tab == .steer {
            attemptQuietHarnessReconnectIfNeeded()
        }
        selectedTab = tab
    }

    private func attemptQuietHarnessReconnectIfNeeded() {
        if case .connected = appState.harnessConnectionState {
            return
        }
        if case .connecting = appState.harnessConnectionState {
            return
        }

        let host = appState.lastKnownHarnessHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "tub-harness.local" : host
        let port = appState.lastKnownHarnessPort

        appState.syncHarnessState(.connecting)
        harnessClient.connectToHarness(host: resolvedHost, port: port)
        harnessClient.preflightHandshake(host: resolvedHost, port: port) { result in
            guard case .success(let payload) = result else { return }
            let hintedHost = payload.hostHints?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let handshakeHost = (hintedHost?.isEmpty == false) ? hintedHost! : resolvedHost
            let handshakePort = payload.audiencePort.flatMap { UInt16(exactly: $0) } ?? port
            guard handshakeHost != resolvedHost || handshakePort != port else { return }
            appState.updateHarnessAddress(host: handshakeHost, port: handshakePort)
            harnessClient.disconnect(manual: false)
            harnessClient.connectToHarness(host: handshakeHost, port: handshakePort)
        }
    }

    private var steerInspectorState: SteerInspectorState {
        let linkStatus: String
        if case .connected = appState.harnessConnectionState {
            linkStatus = "CONNECTED"
        } else {
            linkStatus = "OFFLINE"
        }
        let descriptorSource = harnessClient.descriptorSnapshot == nil ? "LOCAL" : "SERVER"
        let lastEvent = appState.preferenceEvents.last?.eventType.rawValue.uppercased() ?? "NONE"
        return SteerInspectorState(
            linkStatus: linkStatus,
            descriptorSource: descriptorSource,
            mode: "STEER",
            access: appState.steerAccessDisplayState.chipLabel,
            activeDescriptor: appState.currentDescriptors.first?.uppercased() ?? "NONE",
            preferenceCount: appState.preferenceEvents.count,
            lastPreferenceEvent: lastEvent
        )
    }

    private var playInspectorState: PlayInspectorState {
        let cableConnected = appState.isExternalAudioRouteActive || appState.isCableRouteSimulated || appState.isCablePathSatisfied
        return PlayInspectorState(
            cableStatus: cableConnected ? "CONNECTED" : "MISSING",
            routeDescription: appState.externalAudioRouteDescription.uppercased(),
            sessionId: appState.sessionId?.uppercased() ?? "NONE",
            contributionCount: appState.audioContributions.count,
            debugOutput: appState.isDebugOutputSimulated ? "SIMULATED" : "OFF"
        )
    }

    private var learnInspectorState: LearnInspectorState {
        let linkStatus: String
        if case .connected = appState.harnessConnectionState {
            linkStatus = "CONNECTED"
        } else {
            linkStatus = "OFFLINE"
        }
        return LearnInspectorState(
            linkStatus: linkStatus,
            stageFeed: harnessClient.stageFeedState.chipLabel,
            lastReturnMode: appState.learnReturnContext?.mode.title.uppercased() ?? "RITUAL",
            lastReturnChapter: appState.learnReturnContext.map { "\($0.chapter.rawValue + 1)".uppercased() } ?? "1"
        )
    }

    private var settingsInspectorState: SettingsInspectorState {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = appState.lastSuccessfulSessionAt.map { formatter.string(from: $0).uppercased() } ?? "NONE"
        let harnessStatus: String
        switch appState.harnessConnectionState {
        case .disconnected:
            harnessStatus = "DISCONNECTED"
        case .connecting:
            harnessStatus = "CONNECTING"
        case .connected:
            harnessStatus = "CONNECTED"
        case .error:
            harnessStatus = "ERROR"
        }
        return SettingsInspectorState(
            harnessStatus: harnessStatus,
            stageFeed: harnessClient.stageFeedState.chipLabel,
            sessionId: appState.sessionId?.uppercased() ?? "NONE",
            lastSuccessfulSessionAt: timestamp
        )
    }
}

private struct ShellCommandNavigator: View {
    let selectedTab: AppTab
    let layoutClass: ShellLayoutClass
    let appState: TubCompanionAppState
    let harnessClient: HarnessClient
    let onSelect: (AppTab) -> Void
    let showsInspectorToggle: Bool
    let inspectorVisible: Bool
    let onToggleInspector: (() -> Void)?

    private let allTabs: [AppTab] = [.steer, .play, .learn, .settings]
    @State private var hoveredTab: AppTab?
    @State private var hoveringInspector = false

    var body: some View {
        Group {
            if layoutClass == .compact {
                HStack(spacing: 8) {
                    tabButtons
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("COMMAND SHELL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.64))
                        .padding(.horizontal, 2)

                    VStack(spacing: 8) {
                        tabButtons
                    }

                    if showsInspectorToggle, let onToggleInspector {
                        Button {
                            onToggleInspector()
                        } label: {
                            Text(inspectorVisible ? "INSPECTOR ON" : "INSPECTOR OFF")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(inspectorVisible ? BrandingColors.aberrationCyan : Color.white.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    hoveringInspector
                                    ? BrandingColors.aberrationCyan.opacity(0.12)
                                    : Color.clear
                                )
                                .overlay {
                                    Rectangle()
                                        .stroke(
                                            inspectorVisible
                                            ? BrandingColors.aberrationCyan.opacity(0.66)
                                            : Color.white.opacity(0.2),
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("0", modifiers: [.command])
                        .onHover { hovering in
                            hoveringInspector = hovering
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(spacing: 8) {
                        CommandStatusChip(
                            title: "LINK",
                            value: appState.harnessConnectionState == .connected ? "CONNECTED" : "OFFLINE",
                            isActive: appState.harnessConnectionState == .connected
                        )
                        CommandStatusChip(
                            title: "STAGE FEED",
                            value: harnessClient.stageFeedState.chipLabel,
                            isActive: harnessClient.stageFeedState != .standby
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("shell.nav")
    }

    private var tabButtons: some View {
        ForEach(allTabs, id: \.rawValue) { tab in
            let selected = tab == selectedTab
            let hovered = hoveredTab == tab
            Button {
                onSelect(tab)
            } label: {
                Text(tabTitle(tab))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(selected ? BrandingColors.glyphGreen : Color.white.opacity(0.76))
                    .frame(maxWidth: .infinity, minHeight: layoutClass == .compact ? 46 : 50)
                    .background(
                        hovered
                        ? BrandingColors.glyphGreen.opacity(0.08)
                        : Color.clear
                    )
                    .overlay {
                        Rectangle()
                            .stroke(
                                selected
                                ? BrandingColors.glyphGreen.opacity(0.72)
                                : Color.white.opacity(hovered ? 0.32 : 0.16),
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcutKey(for: tab), modifiers: [.command])
            .onHover { hovering in
                if hovering {
                    hoveredTab = tab
                } else if hoveredTab == tab {
                    hoveredTab = nil
                }
            }
            .accessibilityIdentifier("shell.nav.button.\(tab.rawValue)")
            .accessibilityLabel(tabTitle(tab).lowercased())
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }

    private func tabTitle(_ tab: AppTab) -> String {
        switch tab {
        case .steer: return "STEER"
        case .play: return "PLAY"
        case .learn: return "LEARN"
        case .settings: return "SETTINGS"
        }
    }

    private func shortcutKey(for tab: AppTab) -> KeyEquivalent {
        switch tab {
        case .steer:
            return "1"
        case .play:
            return "2"
        case .learn:
            return "3"
        case .settings:
            return "4"
        }
    }
}

private struct ShellInspectorPane: View {
    let selectedTab: AppTab
    let steerState: SteerInspectorState
    let playState: PlayInspectorState
    let learnState: LearnInspectorState
    let settingsState: SettingsInspectorState
    let onSteerLess: () -> Void
    let onSteerMore: () -> Void
    let onJumpSteer: () -> Void
    let onJumpPlay: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(selectedTabTitle) INSPECTOR")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.72))

                CommandSignalRule(opacity: 0.14)

                switch selectedTab {
                case .steer:
                    steerPane
                case .play:
                    playPane
                case .learn:
                    learnPane
                case .settings:
                    settingsPane
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var steerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorLine("LINK", steerState.linkStatus, active: steerState.linkStatus == "CONNECTED")
            inspectorLine("DESCRIPTORS", steerState.descriptorSource, active: steerState.descriptorSource == "SERVER")
            inspectorLine("ACCESS", steerState.access, active: steerState.access == "UNLOCKED")
            inspectorLine("ACTIVE", steerState.activeDescriptor, active: true)
            inspectorLine("EVENTS", "\(steerState.preferenceCount)")
            inspectorLine("LAST", steerState.lastPreferenceEvent)

            HStack(spacing: 8) {
                CommandRailButton(
                    title: "LESS",
                    isEnabled: steerState.linkStatus == "CONNECTED",
                    isActive: false,
                    accent: BrandingColors.glyphGreen,
                    action: onSteerLess
                )
                CommandRailButton(
                    title: "MORE",
                    isEnabled: steerState.linkStatus == "CONNECTED",
                    isActive: false,
                    accent: BrandingColors.glyphGreen,
                    action: onSteerMore
                )
            }

            Text("PRIMARY PAD REMAINS LIVE IN MAIN PANE.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorLine("CABLE", playState.cableStatus, active: playState.cableStatus == "CONNECTED")
            inspectorLine("ROUTE", playState.routeDescription)
            inspectorLine("SESSION", playState.sessionId)
            inspectorLine("CONTRIBUTIONS", "\(playState.contributionCount)")
            inspectorLine("DEBUG OUTPUT", playState.debugOutput, active: playState.debugOutput != "OFF")
            Text("GRID + LONG STRIP RUN IN PRIMARY PANE.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var learnPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorLine("LINK", learnState.linkStatus, active: learnState.linkStatus == "CONNECTED")
            inspectorLine("STAGE FEED", learnState.stageFeed, active: learnState.stageFeed == "LIVE")
            inspectorLine("RETURN MODE", learnState.lastReturnMode)
            inspectorLine("RETURN CHAPTER", learnState.lastReturnChapter)
            Text("ATLAS INDEX STAYS SCANNABLE IN PRIMARY DOC PANE.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                CommandRailButton(
                    title: "JUMP STEER",
                    isEnabled: true,
                    isActive: false,
                    accent: BrandingColors.glyphGreen,
                    action: onJumpSteer
                )
                CommandRailButton(
                    title: "JUMP PLAY",
                    isEnabled: true,
                    isActive: false,
                    accent: BrandingColors.glyphGreen,
                    action: onJumpPlay
                )
            }
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorLine("HARNESS", settingsState.harnessStatus, active: settingsState.harnessStatus == "CONNECTED")
            inspectorLine("STAGE FEED", settingsState.stageFeed, active: settingsState.stageFeed != "STANDBY")
            inspectorLine("SESSION", settingsState.sessionId)
            inspectorLine("LAST LINK", settingsState.lastSuccessfulSessionAt)
            Text("RUN RECOVERY + COVERT CONTROLS IN PRIMARY SETTINGS PANE.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedTabTitle: String {
        switch selectedTab {
        case .steer:
            return "STEER"
        case .play:
            return "PLAY"
        case .learn:
            return "LEARN"
        case .settings:
            return "SETTINGS"
        }
    }

    private func inspectorLine(_ label: String, _ value: String, active: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(minWidth: 92, alignment: .leading)
            Text(value.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(active ? BrandingColors.glyphGreen : Color.white.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct PlayTabHostView: View {
    let appState: TubCompanionAppState
    let harnessClient: HarnessClient
    let externalAudioRouteMonitor: ExternalAudioRouteMonitor
    let isActivated: Bool
    @Binding var isPrimed: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isPrimed {
                PlayIntoTUBView(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("PREPARING LIVE DECK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("SELECT PLAY TO INITIALIZE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .accessibilityIdentifier("play.tab.placeholder")
            }
        }
        .task(id: isActivated) {
            guard isActivated, !isPrimed else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 220_000_000)
            isPrimed = true
        }
    }
}

// MARK: - App State

@MainActor
class TubCompanionAppState: NSObject, ObservableObject {
    @Published var isExternalAudioRouteActive = false
    @Published var isDebugOutputSimulated = false
    @Published var isCableRouteSimulated = false
    @Published var externalAudioRouteDescription = "No external audio route"
    @Published var sessionId: String?
    @Published var harnessConnectionState: HarnessConnectionState = .disconnected
    @Published var currentDescriptors: [String] = []
    @Published var preferenceEvents: [AudiencePreferenceEvent] = []
    @Published var audioContributions: [AudienceAudioContribution] = []

    @Published var entryIntent: EntryIntent?
    @Published var lastEntryIntent: EntryIntent?
    @Published var isCablePathSatisfied = false
    @Published var lastKnownHarnessHost: String = "tub-harness.local"
    @Published var lastKnownHarnessPort: UInt16 = 9911
    @Published var didCompleteCableGuidance = false
    @Published var lastSuccessfulSessionAt: Date?
    @Published var tabNavigationRequest: AppTab?
    @Published var learnReturnContext: LearnReturnContext?
    @Published var steerAccessState: SteerAccessState = .locked
    @Published var steerUnlockExpiresAt: Date?
    @Published private(set) var steerHackSession: SteerHackSession
    @Published private(set) var steerHackRoundSpecs: [SteerHackRoundSpec]
    @Published var forcePresentEntryGate = false
    @Published var bypassPreferredEntryIntentOnce = false

    private let defaults = UserDefaults.standard
    private let debugBypassSteerLockOverride: Bool?
    
    #if DEBUG
    private func debugFlag(_ name: String, defaultValue: Bool) -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: name), index + 1 < args.count {
            let value = args[index + 1].uppercased()
            if value == "YES" || value == "TRUE" || value == "1" { return true }
            if value == "NO" || value == "FALSE" || value == "0" { return false }
        }

        if let raw = ProcessInfo.processInfo.environment[name]?.uppercased() {
            if raw == "YES" || raw == "TRUE" || raw == "1" { return true }
            if raw == "NO" || raw == "FALSE" || raw == "0" { return false }
        }
        return defaultValue
    }

    /// Debug flag to skip entry ritual gate. 
    /// In Xcode, add to Scheme > Run > Arguments Passed On Launch: 
    /// `-DEBUG_SKIP_ENTRY_GATE YES`
    private var debugSkipEntryGate: Bool {
        // Debug default is ON to avoid blocking launch flow during development.
        // Explicitly set to NO if you want to exercise the gate.
        debugFlag("-DEBUG_SKIP_ENTRY_GATE", defaultValue: true)
    }

    private var debugResetAppState: Bool {
        debugFlag("-DEBUG_RESET_APP_STATE", defaultValue: false)
    }

    private var debugAllowSteerWithoutLink: Bool {
        debugFlag("-DEBUG_ALLOW_STEER_WITHOUT_LINK", defaultValue: false)
    }

    private var debugBypassSteerLock: Bool {
        if let debugBypassSteerLockOverride {
            return debugBypassSteerLockOverride
        }
        return debugFlag("-DEBUG_BYPASS_STEER_LOCK", defaultValue: false)
    }

    private var debugForceSteerHackMiss: Bool {
        debugFlag("-DEBUG_STEER_HACK_FORCE_MISS", defaultValue: false)
    }
    #endif

    private enum DefaultsKey {
        static let sessionId = "SessionID"
        static let lastEntryIntent = "LastEntryIntent"
        static let lastKnownHarnessHost = "LastKnownHarnessHost"
        static let lastKnownHarnessPort = "LastKnownHarnessPort"
        static let didCompleteCableGuidance = "DidCompleteCableGuidance"
        static let lastSuccessfulSessionAt = "LastSuccessfulSessionAt"
        static let lastSelectedTab = "LastSelectedTab"
        static let lastSelectedTabIntent = "LastSelectedTabIntent"
    }

    init(debugBypassSteerLockOverride: Bool? = nil) {
        self.debugBypassSteerLockOverride = debugBypassSteerLockOverride
        let now = Date()
        self.steerHackSession = SteerHackSession(
            roundIndex: 0,
            strikes: 0,
            startedAt: now,
            cooldownUntil: nil,
            lastInputAt: nil
        )
        self.steerHackRoundSpecs = []
        super.init()
        resetSteerAccess()
    }
    
    func syncExternalAudioRoute(
        isActive: Bool,
        description: String,
        isDebugOutputSimulated: Bool = false,
        isCableRouteSimulated: Bool = false
    ) {
        isExternalAudioRouteActive = isActive
        externalAudioRouteDescription = description
        self.isDebugOutputSimulated = isDebugOutputSimulated
        self.isCableRouteSimulated = isCableRouteSimulated
    }

    func initializeSession() {
        #if DEBUG
        if debugResetAppState {
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: bundleIdentifier)
            }
            entryIntent = nil
            lastEntryIntent = nil
            isCablePathSatisfied = false
            didCompleteCableGuidance = false
            lastSuccessfulSessionAt = nil
            sessionId = nil
        }
        #endif

        if let existingId = defaults.string(forKey: DefaultsKey.sessionId) {
            sessionId = existingId
        } else {
            let newId = UUID().uuidString
            sessionId = newId
            defaults.set(newId, forKey: DefaultsKey.sessionId)
        }

        if let rawIntent = defaults.string(forKey: DefaultsKey.lastEntryIntent) {
            lastEntryIntent = EntryIntent(rawValue: rawIntent)
        }

        if let host = defaults.string(forKey: DefaultsKey.lastKnownHarnessHost), !host.isEmpty {
            lastKnownHarnessHost = host
        }

        let storedPort = defaults.integer(forKey: DefaultsKey.lastKnownHarnessPort)
        if storedPort > 0, let port = UInt16(exactly: storedPort) {
            lastKnownHarnessPort = port
        }

        didCompleteCableGuidance = defaults.bool(forKey: DefaultsKey.didCompleteCableGuidance)

        if let lastDate = defaults.object(forKey: DefaultsKey.lastSuccessfulSessionAt) as? Date {
            lastSuccessfulSessionAt = lastDate
        }

        if entryIntent == nil {
            entryIntent = lastEntryIntent
        }

        resetSteerAccess()

    }

    func syncHarnessState(_ state: HarnessConnectionState) {
        harnessConnectionState = state

        if case .connected = state {
            lastSuccessfulSessionAt = Date()
            defaults.set(lastSuccessfulSessionAt, forKey: DefaultsKey.lastSuccessfulSessionAt)
        }
    }

    func chooseEntryIntent(_ intent: EntryIntent) {
        forcePresentEntryGate = false
        bypassPreferredEntryIntentOnce = false
        entryIntent = intent
        lastEntryIntent = intent
        defaults.set(intent.rawValue, forKey: DefaultsKey.lastEntryIntent)
        requestTabNavigation(defaultTab(for: intent))
    }

    func markCablePathSatisfied() {
        isCablePathSatisfied = true
        didCompleteCableGuidance = true
        defaults.set(true, forKey: DefaultsKey.didCompleteCableGuidance)
    }

    func clearCablePath() {
        isCablePathSatisfied = false
    }

    func updateHarnessAddress(host: String, port: UInt16) {
        lastKnownHarnessHost = host
        lastKnownHarnessPort = port
        defaults.set(host, forKey: DefaultsKey.lastKnownHarnessHost)
        defaults.set(Int(port), forKey: DefaultsKey.lastKnownHarnessPort)
    }

    func resetEntryFlow() {
        forcePresentEntryGate = true
        bypassPreferredEntryIntentOnce = true
        entryIntent = nil
        isCablePathSatisfied = false
    }

    func clearRememberedEntryPreset() {
        entryIntent = nil
        lastEntryIntent = nil
        isCablePathSatisfied = false
        didCompleteCableGuidance = false

        defaults.removeObject(forKey: DefaultsKey.lastEntryIntent)
        defaults.removeObject(forKey: DefaultsKey.didCompleteCableGuidance)
    }

    var isBackendPathSatisfied: Bool {
        if case .connected = harnessConnectionState { return true }
        return false
    }

    var shouldPresentConnectionGate: Bool {
        if forcePresentEntryGate {
            return true
        }
        #if DEBUG
        if debugSkipEntryGate {
            return false
        }
        #endif
        
        guard let entryIntent else { return true }

        switch entryIntent {
        case .playLive:
            return false
        case .feedBank:
            // FeedBank should land directly in STEER and attempt quiet reconnect first.
            // Hard gating is handled in the STEER overlay so this full-screen ritual only
            // appears when explicitly forced (e.g. RETURN TO ENTRY RITUAL).
            return false
        }
    }

    func shouldPresentOverlay(for feature: FeatureGate) -> Bool {
        #if DEBUG
        if feature == .steer, debugAllowSteerWithoutLink {
            return false
        }
        if debugSkipEntryGate, feature != .steer {
            return false
        }
        #endif
        
        switch feature {
        case .steer:
            return !isBackendPathSatisfied
        case .play:
            return false
        }
    }

    var shouldPresentSteerAccessOverlay: Bool {
        guard !shouldPresentOverlay(for: .steer) else { return false }
        return !isSteerAccessUnlocked
    }

    var steerAccessDisplayState: SteerAccessState {
        #if DEBUG
        if debugBypassSteerLock {
            return .unlocked
        }
        #endif
        return steerAccessState
    }

    func recordPreference(_ event: AudiencePreferenceEvent) {
        preferenceEvents.append(event)
    }

    func recordContribution(_ contribution: AudienceAudioContribution) {
        audioContributions.append(contribution)
    }

    func requestTabNavigation(_ tab: AppTab) {
        tabNavigationRequest = tab
    }

    func consumeTabNavigationRequest() {
        tabNavigationRequest = nil
    }

    func storeLearnReturnContext(_ context: LearnReturnContext) {
        learnReturnContext = context
    }

    @discardableResult
    func rotateSessionId() -> String {
        let newId = UUID().uuidString
        sessionId = newId
        defaults.set(newId, forKey: DefaultsKey.sessionId)
        return newId
    }

    func clearLearnReturnContext() {
        learnReturnContext = nil
    }

    func beginSteerChallenge() {
        #if DEBUG
        if debugBypassSteerLock {
            steerAccessState = .unlocked
            if steerUnlockExpiresAt == nil {
                steerUnlockExpiresAt = Date()
            }
            return
        }
        #endif

        if case .cooldown(let until) = steerAccessState, until > Date() {
            return
        }
        if case .grantedAnimating = steerAccessState {
            return
        }
        if case .unlocked = steerAccessState {
            return
        }

        steerHackRoundSpecs = makeSteerHackRoundSpecs()
        steerHackSession = SteerHackSession(
            roundIndex: 0,
            strikes: 0,
            startedAt: Date(),
            cooldownUntil: nil,
            lastInputAt: nil
        )
        steerAccessState = .inChallenge
    }

    func recordSteerHackInput(didMatch: Bool, observedToken: String, at timestamp: Date = Date()) {
        guard case .inChallenge = steerAccessState else { return }
        _ = observedToken
        var nextSession = steerHackSession
        nextSession.lastInputAt = timestamp
        steerHackSession = nextSession

        #if DEBUG
        if debugBypassSteerLock {
            completeSteerChallenge()
            return
        }
        #endif

        #if DEBUG
        let resolvedMatch = debugForceSteerHackMiss ? false : didMatch
        #else
        let resolvedMatch = didMatch
        #endif

        if resolvedMatch {
            nextSession.strikes = 0
            if nextSession.roundIndex + 1 >= max(1, steerHackRoundSpecs.count) {
                completeSteerChallenge()
                return
            }
            nextSession.roundIndex += 1
            steerHackSession = nextSession
        } else {
            nextSession.strikes += 1
            steerHackSession = nextSession
            if nextSession.strikes >= 3 {
                failSteerChallenge()
            }
        }
    }

    func failSteerChallenge() {
        let until = Date().addingTimeInterval(5.0)
        var nextSession = steerHackSession
        nextSession.cooldownUntil = until
        steerHackSession = nextSession
        steerAccessState = .cooldown(until: until)
    }

    func completeSteerChallenge() {
        steerUnlockExpiresAt = Date()
        steerAccessState = .grantedAnimating
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self else { return }
            if case .grantedAnimating = self.steerAccessState {
                self.steerAccessState = .unlocked
            }
        }
    }

    func resetSteerAccess() {
        #if DEBUG
        if debugBypassSteerLock {
            steerAccessState = .unlocked
            steerUnlockExpiresAt = Date()
            if steerHackRoundSpecs.isEmpty {
                steerHackRoundSpecs = makeSteerHackRoundSpecs()
            }
            steerHackSession = SteerHackSession(
                roundIndex: 0,
                strikes: 0,
                startedAt: Date(),
                cooldownUntil: nil,
                lastInputAt: nil
            )
            return
        }
        #endif

        steerHackRoundSpecs = makeSteerHackRoundSpecs()
        steerHackSession = SteerHackSession(
            roundIndex: 0,
            strikes: 0,
            startedAt: Date(),
            cooldownUntil: nil,
            lastInputAt: nil
        )
        steerAccessState = .locked
        steerUnlockExpiresAt = nil
    }

    func refreshSteerCooldownIfNeeded(now: Date = Date()) {
        guard case .cooldown(let until) = steerAccessState else { return }
        if now >= until {
            steerAccessState = .locked
            var nextSession = steerHackSession
            nextSession.cooldownUntil = nil
            steerHackSession = nextSession
        }
    }

    func initialTabSelection() -> AppTab {
        let intentToken = tabPersistenceIntentToken
        let storedIntent = defaults.string(forKey: DefaultsKey.lastSelectedTabIntent)
        if storedIntent == intentToken,
           let rawTab = defaults.string(forKey: DefaultsKey.lastSelectedTab),
           let tab = AppTab(rawValue: rawTab) {
            return tab
        }
        return defaultTab(for: entryIntent ?? lastEntryIntent)
    }

    func persistSelectedTab(_ tab: AppTab) {
        defaults.set(tab.rawValue, forKey: DefaultsKey.lastSelectedTab)
        defaults.set(tabPersistenceIntentToken, forKey: DefaultsKey.lastSelectedTabIntent)
    }

    private var tabPersistenceIntentToken: String {
        (entryIntent ?? lastEntryIntent)?.rawValue ?? "none"
    }

    private var isSteerAccessUnlocked: Bool {
        if case .unlocked = steerAccessDisplayState {
            return true
        }
        return false
    }

    private func makeSteerHackRoundSpecs() -> [SteerHackRoundSpec] {
        var shuffled = CodeMatchChallengeCore.baseTokens.shuffled()
        if shuffled.count < 3 {
            shuffled = Array(repeating: "AA", count: 3)
        }
        let targets = Array(shuffled.prefix(3))

        return [
            SteerHackRoundSpec(targetToken: targets[0], stripSpeed: 3.6, windowTolerance: 1),
            SteerHackRoundSpec(targetToken: targets[1], stripSpeed: 4.9, windowTolerance: 1),
            SteerHackRoundSpec(targetToken: targets[2], stripSpeed: 5.4, windowTolerance: 1)
        ]
    }

    private func defaultTab(for intent: EntryIntent?) -> AppTab {
        switch intent {
        case .playLive:
            return .play
        case .feedBank:
            return .steer
        case .none:
            return .steer
        }
    }
}

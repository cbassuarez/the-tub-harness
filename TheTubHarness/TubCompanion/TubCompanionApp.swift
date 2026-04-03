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

struct CompanionRootView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    @State private var showLaunchScreen = true
    @State private var didScheduleLaunchDismiss = false
    @State private var isPlaySurfaceReady = false

    var body: some View {
        ZStack {
            MainShellView(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor,
                onPlaySurfaceReady: {
                    isPlaySurfaceReady = true
                }
            )
            if appState.shouldPresentConnectionGate {
                ConnectionGateView(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor,
                    presentation: .fullScreen,
                    preferredIntent: appState.lastEntryIntent
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            currentTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                CommandSignalRule()
                ShellCommandNavigator(
                    selectedTab: selectedTab,
                    onSelect: { tab in
                        selectTab(tab)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .background(Color.black.opacity(0.96))
        }
        .onAppear {
            guard !didApplyInitialTab else { return }
            didApplyInitialTab = true
            let initialTab = appState.initialTabSelection()
            selectTab(initialTab)
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
        selectedTab = tab
    }
}

private struct ShellCommandNavigator: View {
    let selectedTab: AppTab
    let onSelect: (AppTab) -> Void

    private let allTabs: [AppTab] = [.steer, .play, .learn, .settings]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(allTabs, id: \.rawValue) { tab in
                let selected = tab == selectedTab
                Button {
                    onSelect(tab)
                } label: {
                    Text(tabTitle(tab))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(selected ? BrandingColors.glyphGreen : Color.white.opacity(0.76))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay {
                            Rectangle()
                                .stroke(
                                    selected
                                    ? BrandingColors.glyphGreen.opacity(0.72)
                                    : Color.white.opacity(0.16),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shell.nav.button.\(tab.rawValue)")
                .accessibilityLabel(tabTitle(tab).lowercased())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityIdentifier("shell.nav")
    }

    private func tabTitle(_ tab: AppTab) -> String {
        switch tab {
        case .steer: return "STEER"
        case .play: return "PLAY"
        case .learn: return "LEARN"
        case .settings: return "SETTINGS"
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
        entryIntent = intent
        lastEntryIntent = intent
        defaults.set(intent.rawValue, forKey: DefaultsKey.lastEntryIntent)
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
            return !isBackendPathSatisfied
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
        #if DEBUG
        if debugBypassSteerLock {
            return true
        }
        #endif

        if case .unlocked = steerAccessState {
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

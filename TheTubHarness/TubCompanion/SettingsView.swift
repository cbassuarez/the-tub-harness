//
//  SettingsView.swift
//  TubCompanion
//
//  Settings v2: operator console + covert power layer.
//

import SwiftUI
import Combine
import AVFAudio

enum SettingsGuardedAction: String, Identifiable {
    case rotateSession
    case clearPreset
    case resetEntryFlow
    case disconnectHarness
    case relockSteer
    case clearTemporaryOverlays
    case clearLearnContext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rotateSession: return "ROTATE SESSION ID"
        case .clearPreset: return "CLEAR SAVED ENTRY PRESET"
        case .resetEntryFlow: return "RESET ENTRY FLOW"
        case .disconnectHarness: return "DISCONNECT HARNESS LINK"
        case .relockSteer: return "RELOCK STEER ACCESS"
        case .clearTemporaryOverlays: return "CLEAR TEMPORARY OVERLAYS"
        case .clearLearnContext: return "CLEAR LEARN RETURN CONTEXT"
        }
    }

    var message: String {
        switch self {
        case .rotateSession:
            return "Generate a new audience session identifier for this device."
        case .clearPreset:
            return "Forget saved entry intent and cable guidance state."
        case .resetEntryFlow:
            return "Return this device to entry ritual state."
        case .disconnectHarness:
            return "Drop the active harness socket link."
        case .relockSteer:
            return "Lock STEER again until challenge is completed."
        case .clearTemporaryOverlays:
            return "Reset temporary operator vector influence to neutral."
        case .clearLearnContext:
            return "Forget Learn tab return position and mode state."
        }
    }

    var confirmTitle: String {
        switch self {
        case .rotateSession: return "ROTATE"
        case .clearPreset: return "CLEAR PRESET"
        case .resetEntryFlow: return "RESET FLOW"
        case .disconnectHarness: return "DISCONNECT"
        case .relockSteer: return "RELOCK"
        case .clearTemporaryOverlays: return "CLEAR OVERLAYS"
        case .clearLearnContext: return "CLEAR CONTEXT"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .disconnectHarness, .clearPreset, .resetEntryFlow, .relockSteer, .clearTemporaryOverlays, .clearLearnContext:
            return .destructive
        case .rotateSession:
            return nil
        }
    }
}

struct OperatorVectorState: Equatable {
    var param: Double = 0
    var thought: Double = 0
    var audio: Double = 0

    static let zero = OperatorVectorState()

    var isNeutral: Bool {
        isApproximatelyNeutral()
    }

    func isApproximatelyNeutral(epsilon: Double = 0.01) -> Bool {
        abs(param) <= epsilon && abs(thought) <= epsilon && abs(audio) <= epsilon
    }

    func isApproximatelyEqual(to other: OperatorVectorState, epsilon: Double = 0.01) -> Bool {
        abs(param - other.param) <= epsilon &&
        abs(thought - other.thought) <= epsilon &&
        abs(audio - other.audio) <= epsilon
    }
}

enum AdvancedSettingsAccessState: Equatable {
    case locked
    case inChallenge
    case cooldown(until: Date)
    case grantedAnimating
    case unlocked

    var label: String {
        switch self {
        case .locked: return "LOCKED"
        case .inChallenge: return "CHALLENGE"
        case .cooldown: return "COOLDOWN"
        case .grantedAnimating: return "GRANTING"
        case .unlocked: return "UNLOCKED"
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    private enum VectorAuthority {
        case local
        case remote
    }

    @Published var pendingGuardedAction: SettingsGuardedAction?
    @Published var showPowerUnlockGate = false
    @Published var showPowerLayerModal = false
    @Published private(set) var advancedAccessState: AdvancedSettingsAccessState = .locked
    @Published private(set) var harnessActionStatus: String = "READY."
    @Published private(set) var lastOperatorAck: String = "NONE"
    @Published private(set) var lastOperatorAckAt: Date?
    @Published private(set) var pendingOperatorAck = false
    @Published private(set) var lastOperatorSendAt: Date?
    @Published private(set) var operatorVector: OperatorVectorState = .zero
    @Published private(set) var operatorVectorExpiresAt: Date?
    @Published private(set) var vectorCountdownLabel: String = "00:00:00"
    @Published private(set) var isEditingOperatorVector = false
    @Published private(set) var pendingRemoteOperatorVector: OperatorVectorLiveState?
    @Published private(set) var lastVectorSourceSessionId: String?

    private let appState: TubCompanionAppState
    private let harnessClient: HarnessClient
    private let externalAudioRouteMonitor: ExternalAudioRouteMonitor
    private let vectorTTLSeconds: TimeInterval = 60 * 60
    private let vectorComponentDeadband: Double = 0.01
    private let vectorNoopEpsilon: Double = 0.01

    private var decayStartAt: Date?
    private var decayStartVector: OperatorVectorState = .zero
    private var decayDurationSeconds: TimeInterval = 0
    private var decayTicker: AnyCancellable?
    private var pendingVectorSendWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var vectorAuthority: VectorAuthority = .local

    init(
        appState: TubCompanionAppState,
        harnessClient: HarnessClient,
        externalAudioRouteMonitor: ExternalAudioRouteMonitor
    ) {
        self.appState = appState
        self.harnessClient = harnessClient
        self.externalAudioRouteMonitor = externalAudioRouteMonitor

        harnessClient.$lastAudienceAck
            .receive(on: RunLoop.main)
            .sink { [weak self] ack in
                guard let self, let ack else { return }
                if ack.uppercased().contains("OPERATOR VECTOR") {
                    self.lastOperatorAck = ack.uppercased()
                    self.lastOperatorAckAt = Date()
                    self.pendingOperatorAck = false
                }
            }
            .store(in: &cancellables)

        harnessClient.$lastOperatorVectorState
            .receive(on: RunLoop.main)
            .sink { [weak self] liveState in
                guard let self, let liveState else { return }
                self.applyRemoteOperatorVector(liveState)
            }
            .store(in: &cancellables)

        decayTicker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                self?.applyDecay(now: now)
            }
    }

    deinit {
        decayTicker?.cancel()
        pendingVectorSendWorkItem?.cancel()
    }

    var harnessStatusLabel: String {
        switch appState.harnessConnectionState {
        case .disconnected: return "DISCONNECTED"
        case .connecting: return "CONNECTING"
        case .connected: return "CONNECTED"
        case .error: return "ERROR"
        }
    }

    var isHarnessLinked: Bool {
        if case .connected = appState.harnessConnectionState {
            return true
        }
        return false
    }

    var lastSessionTimestampLabel: String {
        guard let stamp = appState.lastSuccessfulSessionAt else { return "NONE" }
        return Self.timestampFormatter.string(from: stamp).uppercased()
    }

    var debugLines: [String] {
        #if DEBUG
        let outputTypes = externalAudioRouteMonitor.lastSeenOutputPortTypes
            .map { $0.rawValue.uppercased() }
            .joined(separator: ", ")
        return [
            "DEBUG OUTPUT SIMULATED: \(appState.isDebugOutputSimulated ? "YES" : "NO")",
            "CABLE ROUTE SIMULATED: \(appState.isCableRouteSimulated ? "YES" : "NO")",
            "OUTPUT PORT TYPES: \(outputTypes.isEmpty ? "NONE" : outputTypes)"
        ]
        #else
        return []
        #endif
    }

    var countdownDisplay: String {
        operatorVectorExpiresAt == nil ? "NEUTRAL" : vectorCountdownLabel
    }

    var vectorSyncChipValue: String {
        isHarnessLinked ? "CANONICAL" : "OFFLINE"
    }

    var vectorSourceChipValue: String {
        guard let source = lastVectorSourceSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
            return "LOCAL"
        }
        let upper = source.uppercased()
        return upper.count <= 12 ? upper : String(upper.prefix(12))
    }

    var vectorStateChipValue: String {
        if isEditingOperatorVector {
            return "LOCAL HOLD"
        }
        if pendingRemoteOperatorVector != nil {
            return "REMOTE QUEUED"
        }
        return "FOLLOWING"
    }

    var vectorAckChipValue: String {
        if !isHarnessLinked {
            return "OFFLINE"
        }
        if pendingOperatorAck {
            return "PENDING"
        }
        if lastOperatorAckAt != nil {
            return "SUCCESS"
        }
        return "IDLE"
    }

    var vectorAckDetail: String {
        if pendingOperatorAck {
            return "WAITING FOR HARNESS STATUS PING..."
        }
        if let lastOperatorAckAt {
            return "\(lastOperatorAck) @ \(Self.timestampFormatter.string(from: lastOperatorAckAt).uppercased())"
        }
        return "SEND A VECTOR TO START LIVE SYNC."
    }

    func requestGuardedAction(_ action: SettingsGuardedAction) {
        pendingGuardedAction = action
    }

    func dismissGuardedAction() {
        pendingGuardedAction = nil
    }

    func executeGuardedAction(_ action: SettingsGuardedAction) {
        pendingGuardedAction = nil
        switch action {
        case .rotateSession:
            let newSession = appState.rotateSessionId()
            harnessClient.setSessionId(newSession)
            harnessActionStatus = "SESSION ROTATED / \(newSession.uppercased())"
        case .clearPreset:
            appState.clearRememberedEntryPreset()
            harnessActionStatus = "ENTRY PRESET CLEARED."
        case .resetEntryFlow:
            appState.resetEntryFlow()
            harnessActionStatus = "ENTRY FLOW RESET."
        case .disconnectHarness:
            harnessClient.disconnect()
            harnessActionStatus = "HARNESS DISCONNECTED."
        case .relockSteer:
            appState.resetSteerAccess()
            harnessActionStatus = "STEER ACCESS RELOCKED."
        case .clearTemporaryOverlays:
            resetVectorsToNeutral(sendToHarness: true)
            harnessActionStatus = "TEMPORARY OVERLAYS CLEARED."
        case .clearLearnContext:
            appState.clearLearnReturnContext()
            harnessActionStatus = "LEARN CONTEXT CLEARED."
        }
    }

    func reconnectHarness() {
        let address = normalizedAddress()
        appState.updateHarnessAddress(host: address.host, port: address.port)
        harnessActionStatus = "PROBING HARNESS..."
        // Handshake first to resolve the correct address, then connect.
        // Running connectToHarness concurrently with the HTTP handshake
        // can saturate the server's connection handler and cause the
        // handshake to time out even though the link succeeds.
        harnessClient.disconnect(manual: false)
        runHandshake(host: address.host, port: address.port, reconnectOnResolve: true)
    }

    func reprobeHarnessLink() {
        let address = normalizedAddress()
        appState.updateHarnessAddress(host: address.host, port: address.port)
        harnessActionStatus = "PROBING HANDSHAKE..."
        runHandshake(host: address.host, port: address.port, reconnectOnResolve: false)
    }

    func beginPowerUnlockGate() {
        if advancedAccessState == .unlocked || advancedAccessState == .grantedAnimating {
            showPowerLayerModal = true
            return
        }
        showPowerUnlockGate = true
        if case .cooldown = advancedAccessState {
            return
        }
        advancedAccessState = .locked
    }

    func dismissPowerUnlockGate() {
        showPowerUnlockGate = false
        if advancedAccessState == .inChallenge {
            advancedAccessState = .locked
        }
    }

    func dismissPowerLayerModal() {
        endVectorEdit()
        showPowerLayerModal = false
    }

    func handlePowerUnlockSucceeded() {
        showPowerUnlockGate = false
        advancedAccessState = .unlocked
        harnessActionStatus = "COVERT LAYER AUTHENTICATED."
        showPowerLayerModal = true
    }

    func relockPowerLayer() {
        advancedAccessState = .locked
        endVectorEdit()
        showPowerLayerModal = false
        pendingRemoteOperatorVector = nil
        resetVectorsToNeutral(sendToHarness: true)
        harnessActionStatus = "COVERT LAYER LOCKED."
    }

    func setVector(param: Double? = nil, thought: Double? = nil, audio: Double? = nil) {
        guard advancedAccessState == .unlocked else { return }

        let current = operatorVector
        var next = operatorVector
        if let param { next.param = normalizedVectorComponent(param) }
        if let thought { next.thought = normalizedVectorComponent(thought) }
        if let audio { next.audio = normalizedVectorComponent(audio) }

        guard !next.isApproximatelyEqual(to: current, epsilon: vectorNoopEpsilon) else {
            return
        }

        operatorVector = next
        vectorAuthority = .local
        lastVectorSourceSessionId = appState.sessionId
        pendingRemoteOperatorVector = nil
        if next.isNeutral {
            if current.isNeutral && operatorVectorExpiresAt == nil {
                return
            }
            resetVectorsToNeutral(sendToHarness: !current.isNeutral)
            harnessActionStatus = "OPERATOR VECTOR NEUTRAL."
            return
        }

        let now = Date()
        let ttl = remainingVectorTTL(at: now) ?? vectorTTLSeconds
        decayStartAt = now
        decayStartVector = next
        decayDurationSeconds = ttl
        operatorVectorExpiresAt = now.addingTimeInterval(ttl)
        vectorCountdownLabel = Self.durationLabel(from: ttl)

        queueVectorSend(ttlSeconds: ttl)
    }

    func beginVectorEdit() {
        guard advancedAccessState == .unlocked else { return }
        isEditingOperatorVector = true
    }

    func endVectorEdit() {
        guard isEditingOperatorVector else { return }
        isEditingOperatorVector = false
        if let pending = pendingRemoteOperatorVector {
            pendingRemoteOperatorVector = nil
            applyRemoteOperatorVector(pending)
        }
    }

    func applyRemoteOperatorVector(_ liveState: OperatorVectorLiveState) {
        if isEditingOperatorVector {
            pendingRemoteOperatorVector = liveState
            return
        }

        let normalized = OperatorVectorState(
            param: normalizedVectorComponent(liveState.param),
            thought: normalizedVectorComponent(liveState.thought),
            audio: normalizedVectorComponent(liveState.audio)
        )

        let isLocalEcho = (liveState.sessionId == appState.sessionId)
        if isLocalEcho && normalized.isApproximatelyEqual(to: operatorVector, epsilon: vectorNoopEpsilon) {
            lastVectorSourceSessionId = liveState.sessionId
            return
        }

        lastVectorSourceSessionId = liveState.sessionId
        vectorAuthority = (liveState.sessionId == appState.sessionId) ? .local : .remote
        pendingRemoteOperatorVector = nil

        if liveState.ttlSeconds <= 0 || normalized.isNeutral {
            resetVectorsToNeutral(sendToHarness: false)
            harnessActionStatus = "CANONICAL VECTOR RESET."
            return
        }

        operatorVector = normalized
        let now = Date()
        decayStartAt = now
        decayStartVector = normalized
        decayDurationSeconds = max(0.1, liveState.ttlSeconds)
        operatorVectorExpiresAt = now.addingTimeInterval(decayDurationSeconds)
        vectorCountdownLabel = Self.durationLabel(from: decayDurationSeconds)
        harnessActionStatus = "CANONICAL VECTOR FROM \(vectorSourceChipValue)."
    }

    func resetVectorsToNeutral(sendToHarness: Bool) {
        operatorVector = .zero
        decayStartAt = nil
        decayStartVector = .zero
        decayDurationSeconds = 0
        operatorVectorExpiresAt = nil
        vectorCountdownLabel = "00:00:00"
        vectorAuthority = .local
        if sendToHarness {
            sendCurrentVector(ttlSeconds: 0)
        }
    }

    private func runHandshake(host: String, port: UInt16, reconnectOnResolve: Bool) {
        harnessClient.preflightHandshake(host: host, port: port) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                let preferredHost = payload.hostHints?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedHost = (preferredHost?.isEmpty == false) ? preferredHost! : host
                let resolvedPort = payload.audiencePort.flatMap { UInt16(exactly: $0) } ?? port
                self.appState.updateHarnessAddress(host: resolvedHost, port: resolvedPort)

                if reconnectOnResolve {
                    if resolvedHost != host || resolvedPort != port {
                        self.harnessClient.disconnect(manual: false)
                    }
                    self.harnessClient.connectToHarness(host: resolvedHost, port: resolvedPort)
                }

                self.harnessActionStatus = "HANDSHAKE OK / \(resolvedHost.uppercased()):\(resolvedPort)"
            case .failure(let error):
                guard self.harnessClient.shouldAttemptLocalDiscovery(for: host), !self.isHarnessLinked else {
                    self.harnessActionStatus = "HANDSHAKE FAILED / \(error.localizedDescription.uppercased())"
                    return
                }

                self.harnessActionStatus = "HANDSHAKE UNAVAILABLE. SCANNING LOCAL NETWORK..."
                self.harnessClient.discoverHarnessOnLocalNetwork(port: port) { discovery in
                    switch discovery {
                    case .success(let result):
                        let discoveredPort = result.payload.audiencePort.flatMap { UInt16(exactly: $0) } ?? port
                        self.appState.updateHarnessAddress(host: result.host, port: discoveredPort)
                        if reconnectOnResolve {
                            self.harnessClient.disconnect()
                            self.harnessClient.connectToHarness(host: result.host, port: discoveredPort)
                        }
                        self.harnessActionStatus = "HARNESS DISCOVERED / \(result.host.uppercased()):\(discoveredPort)"
                    case .failure(let discoveryError):
                        self.harnessActionStatus = "LOCAL DISCOVERY FAILED / \(discoveryError.localizedDescription.uppercased())"
                    }
                }
            }
        }
    }

    private func normalizedAddress() -> (host: String, port: UInt16) {
        let host = appState.lastKnownHarnessHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host.isEmpty ? "tub-harness.local" : host
        return (normalizedHost, appState.lastKnownHarnessPort)
    }

    private func queueVectorSend(ttlSeconds: TimeInterval) {
        pendingVectorSendWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.sendCurrentVector(ttlSeconds: ttlSeconds)
        }
        pendingVectorSendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func sendCurrentVector(ttlSeconds: TimeInterval) {
        guard let sessionId = appState.sessionId else {
            harnessActionStatus = "SESSION ID MISSING. VECTOR SEND CANCELLED."
            return
        }
        guard isHarnessLinked else {
            pendingOperatorAck = false
            return
        }
        lastOperatorSendAt = Date()
        pendingOperatorAck = true
        harnessClient.sendOperatorVector(
            paramVector: operatorVector.param,
            thoughtVector: operatorVector.thought,
            audioVector: operatorVector.audio,
            ttlSeconds: ttlSeconds,
            sessionId: sessionId
        )
    }

    private func normalizedVectorComponent(_ value: Double) -> Double {
        let clamped = Self.clampSigned(value)
        return abs(clamped) <= vectorComponentDeadband ? 0 : clamped
    }

    private func remainingVectorTTL(at now: Date) -> TimeInterval? {
        guard let expiresAt = operatorVectorExpiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            return nil
        }
        return max(0.1, remaining)
    }

    private func applyDecay(now: Date) {
        guard let decayStartAt, let expiresAt = operatorVectorExpiresAt else { return }
        guard advancedAccessState == .unlocked else { return }

        if now >= expiresAt {
            if !operatorVector.isNeutral {
                operatorVector = .zero
                if vectorAuthority == .local {
                    sendCurrentVector(ttlSeconds: 0)
                }
            }
            self.decayStartAt = nil
            decayStartVector = .zero
            decayDurationSeconds = 0
            operatorVectorExpiresAt = nil
            vectorCountdownLabel = "00:00:00"
            harnessActionStatus = "OPERATOR VECTOR EXPIRED TO NEUTRAL."
            return
        }

        let elapsed = max(0, now.timeIntervalSince(decayStartAt))
        let duration = max(0.1, decayDurationSeconds)
        let progress = max(0, min(1, elapsed / duration))
        let factor = 1 - progress
        operatorVector = OperatorVectorState(
            param: decayStartVector.param * factor,
            thought: decayStartVector.thought * factor,
            audio: decayStartVector.audio * factor
        )
        vectorCountdownLabel = Self.durationLabel(from: expiresAt.timeIntervalSince(now))
    }

    private static func clampSigned(_ value: Double) -> Double {
        max(-1, min(1, value))
    }

    private static func durationLabel(from seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - Testing Hooks

    func setPowerLayerUnlockedForTesting() {
        advancedAccessState = .unlocked
    }

    func applyVectorDecayForTesting(now: Date) {
        applyDecay(now: now)
    }
}

@MainActor
final class SettingsPowerUnlockChallengeViewModel: ObservableObject {
    @Published private(set) var state: AdvancedSettingsAccessState = .locked
    @Published private(set) var stripTokens: [String] = []
    @Published private(set) var targetToken: String = "--"
    @Published private(set) var activeIndex: Int = 0
    @Published private(set) var roundDisplay: Int = 1
    @Published private(set) var roundsTotal: Int = 4
    @Published private(set) var strikes: Int = 0
    @Published private(set) var roundTimeRemaining: TimeInterval = 0
    @Published private(set) var cooldownRemaining: TimeInterval = 0
    @Published private(set) var statusLine: String = "POWER LAYER LOCKED."
    @Published private(set) var commandLog: [String] = ["PRIVILEGED MODULE SEALED."]
    @Published private(set) var interruptionActive = false
    @Published private(set) var qteEffort: Double = 0
    @Published private(set) var qteThreshold: Double = 0.72
    @Published private(set) var qteRemaining: TimeInterval = 0
    @Published private(set) var transitionActive = false
    @Published private(set) var transitionTitle: String = ""
    @Published private(set) var transitionSubtitle: String = ""

    private let codeRoundCount = 4
    private let codeRoundSpeeds: [Double] = [5.4, 6.0, 6.0, 6.2]
    private let codeRoundDurations: [TimeInterval] = [40.0, 40.0, 40.0, 40.0]
    private let codeWindowTolerance = 1
    private let qteDuration: TimeInterval = 5.0
    private let qteTapGain = 0.1
    private let qteDecayPerSecond = 0.3
    private let transitionBeatDuration: TimeInterval = 0.72
    private let interruptionTriggerRoundIndex = 2

    private var currentRoundIndex: Int = 0
    private var targetSlotIndex: Int = 0
    private var rollTimer: Timer?
    private var roundTimer: Timer?
    private var cooldownTimer: Timer?
    private var interruptionTimer: Timer?
    private var interruptionEndsAt: Date?
    private var lastInterruptionTickAt: Date?
    private var lastTickAt: Date?
    private var roundEndsAt: Date?
    private var roundSpecs: [SteerHackRoundSpec] = []
    private var interruptionCompleted = false
    private var transitionWorkItem: DispatchWorkItem?

    deinit {
        rollTimer?.invalidate()
        roundTimer?.invalidate()
        cooldownTimer?.invalidate()
        interruptionTimer?.invalidate()
        transitionWorkItem?.cancel()
    }

    func activate() {
        guard state == .locked else { return }
        startChallenge()
    }

    func unlockViaCredentialBypass() {
        guard state != .unlocked else { return }
        clearTransitionState()
        stopRollTimer()
        stopInterruptionTimer()
        stopCooldownTimer()
        interruptionActive = false
        qteEffort = 0
        qteRemaining = 0
        statusLine = "TOKEN VERIFIED."
        appendLog("TOKEN VERIFIED. PRIVILEGED MODULE UNSEALED.")
        finishChallenge()
    }

    func matchTapped() {
        guard state == .inChallenge else { return }
        guard !transitionActive else { return }
        guard !interruptionActive else { return }
        guard !stripTokens.isEmpty else { return }

        let spec = currentSpec
        let now = Date()
        let token = stripTokens[activeIndex]
        let didMatch = CodeMatchChallengeCore.isMatchWithLateGrace(
            activeIndex: activeIndex,
            targetIndex: targetSlotIndex,
            tokenCount: stripTokens.count,
            windowTolerance: spec.windowTolerance,
            lastTickAt: lastTickAt,
            now: now,
            tickInterval: CodeMatchChallengeCore.timerInterval(stripSpeed: spec.stripSpeed)
        )
        resolveMatch(didMatch: didMatch, token: token, skipTransitions: false)
    }

    func submitMatchForTesting(_ didMatch: Bool) {
        guard state == .inChallenge else { return }
        guard !interruptionActive else { return }
        resolveMatch(didMatch: didMatch, token: targetToken, skipTransitions: true)
    }

    func interruptionTap() {
        guard state == .inChallenge else { return }
        guard !transitionActive else { return }
        guard interruptionActive else { return }
        qteEffort = min(1, qteEffort + qteTapGain)
        statusLine = "PATCH EFFORT \(Int((qteEffort * 100).rounded()))% / \(Int((qteThreshold * 100).rounded()))%"
        if qteEffort >= qteThreshold {
            resolveInterruption(skipTransitions: false)
        }
    }

    func resolveInterruptionForTesting() {
        guard interruptionActive else { return }
        resolveInterruption(skipTransitions: true)
    }

    func forceRoundTimeoutForTesting() {
        guard state == .inChallenge, !interruptionActive else { return }
        handleRoundTimeout()
    }

    func forceInterruptionTimeoutForTesting() {
        guard state == .inChallenge, interruptionActive else { return }
        handleInterruptionTimeout()
    }

    private func resolveMatch(didMatch: Bool, token: String, skipTransitions: Bool) {
        if didMatch {
            appendLog("MATCH \(token) ACCEPTED.")
            currentRoundIndex += 1

            if !interruptionCompleted, currentRoundIndex == interruptionTriggerRoundIndex + 1 {
                if skipTransitions {
                    triggerInterruptionRound(resetLives: true)
                } else {
                    transitionIntoInterruptionRound()
                }
                return
            }

            if currentRoundIndex >= roundSpecs.count {
                finishChallenge()
            } else {
                configureRound(resetLives: true)
            }
        } else {
            loseLifeAndContinue(
                eventLine: "MISS \(token). DRIFT DETECTED.",
                retryAction: { [weak self] in
                    self?.configureRound(resetLives: false)
                },
                clearInterruptionState: false
            )
        }
    }

    func retryTapped() {
        guard !transitionActive else { return }
        if case .cooldown(let until) = state, Date() < until {
            return
        }
        startChallenge()
    }

    private var currentSpec: SteerHackRoundSpec {
        if roundSpecs.isEmpty {
            return .init(targetToken: "--", stripSpeed: 5.0, windowTolerance: 1)
        }
        let index = min(max(0, currentRoundIndex), roundSpecs.count - 1)
        return roundSpecs[index]
    }

    private func makeRoundSpecs() -> [SteerHackRoundSpec] {
        var shuffled = CodeMatchChallengeCore.baseTokens.shuffled()
        if shuffled.count < codeRoundCount {
            while shuffled.count < codeRoundCount {
                shuffled.append("AA")
            }
        }
        return (0..<codeRoundCount).map { index in
            let speed = codeRoundSpeeds[min(index, codeRoundSpeeds.count - 1)]
            return SteerHackRoundSpec(
                targetToken: shuffled[index],
                stripSpeed: speed,
                windowTolerance: codeWindowTolerance
            )
        }
    }

    private func startChallenge() {
        clearTransitionState()
        stopCooldownTimer()
        stopInterruptionTimer()
        stopRollTimer()
        stopRoundTimer()
        roundSpecs = makeRoundSpecs()
        strikes = 0
        cooldownRemaining = 0
        currentRoundIndex = 0
        roundsTotal = roundSpecs.count
        interruptionActive = false
        interruptionCompleted = false
        qteEffort = 0
        qteRemaining = 0
        interruptionEndsAt = nil
        lastInterruptionTickAt = nil
        state = .inChallenge
        configureRound(resetLives: true)
    }

    private func configureRound(resetLives: Bool) {
        let spec = currentSpec
        if resetLives {
            strikes = 0
        }
        roundDisplay = currentRoundIndex + 1
        targetToken = spec.targetToken.uppercased()
        statusLine = "ROUND \(roundDisplay): ALIGN \(targetToken)"
        appendLog("ROUND \(roundDisplay) TARGET \(targetToken).")

        let strip = CodeMatchChallengeCore.buildStrip(roundIndex: currentRoundIndex + 2, targetToken: targetToken)
        stripTokens = strip.tokens
        targetSlotIndex = strip.targetSlotIndex
        activeIndex = (targetSlotIndex + 3) % max(1, stripTokens.count)
        lastTickAt = Date()
        startRollTimer(speed: spec.stripSpeed)
        startRoundTimer(roundIndex: currentRoundIndex)
    }

    private func startRollTimer(speed: Double) {
        rollTimer?.invalidate()
        let interval = CodeMatchChallengeCore.timerInterval(stripSpeed: speed)
        rollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .inChallenge, !self.stripTokens.isEmpty else { return }
                self.activeIndex = (self.activeIndex + 1) % self.stripTokens.count
                self.lastTickAt = Date()
            }
        }
        rollTimer?.tolerance = 0.02
    }

    private func failChallenge() {
        clearTransitionState()
        stopRollTimer()
        stopRoundTimer()
        stopInterruptionTimer()
        interruptionActive = false
        qteEffort = 0
        qteRemaining = 0
        interruptionEndsAt = nil
        lastInterruptionTickAt = nil
        let until = Date().addingTimeInterval(5)
        state = .cooldown(until: until)
        statusLine = "LOCKOUT ACTIVE."
        appendLog("LOCKOUT TRIGGERED. WAIT 5 SECONDS.")
        startCooldownTimer(until: until)
    }

    private func finishChallenge() {
        clearTransitionState()
        stopRollTimer()
        stopRoundTimer()
        stopInterruptionTimer()
        stopCooldownTimer()
        statusLine = "ACCESS GRANTED."
        state = .grantedAnimating
        appendLog("PRIVILEGED MODULE UNSEALED.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if case .grantedAnimating = self.state {
                self.state = .unlocked
            }
        }
    }

    private func startCooldownTimer(until: Date) {
        cooldownTimer?.invalidate()
        cooldownRemaining = max(0, until.timeIntervalSinceNow)
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cooldownRemaining = max(0, until.timeIntervalSinceNow)
                if self.cooldownRemaining <= 0 {
                    self.stopCooldownTimer()
                    self.state = .locked
                    self.statusLine = "LOCKOUT CLEARED. RETRY AVAILABLE."
                    self.appendLog("LOCKOUT CLEARED.")
                    self.interruptionActive = false
                    self.qteEffort = 0
                    self.qteRemaining = 0
                    self.interruptionEndsAt = nil
                    self.lastInterruptionTickAt = nil
                }
            }
        }
        cooldownTimer?.tolerance = 0.03
    }

    private func stopRollTimer() {
        rollTimer?.invalidate()
        rollTimer = nil
    }

    private func startRoundTimer(roundIndex: Int) {
        stopRoundTimer()
        let duration = codeRoundDurations[min(max(0, roundIndex), codeRoundDurations.count - 1)]
        roundEndsAt = Date().addingTimeInterval(duration)
        roundTimeRemaining = duration
        roundTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .inChallenge, !self.interruptionActive else {
                    self.stopRoundTimer()
                    return
                }
                guard let endsAt = self.roundEndsAt else {
                    self.stopRoundTimer()
                    return
                }

                self.roundTimeRemaining = max(0, endsAt.timeIntervalSinceNow)
                if self.roundTimeRemaining <= 0 {
                    self.handleRoundTimeout()
                }
            }
        }
        roundTimer?.tolerance = 0.03
    }

    private func stopRoundTimer() {
        roundTimer?.invalidate()
        roundTimer = nil
        roundEndsAt = nil
        roundTimeRemaining = 0
    }

    private func stopCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }

    private func triggerInterruptionRound(resetLives: Bool) {
        clearTransitionState()
        stopRollTimer()
        stopRoundTimer()
        interruptionActive = true
        if resetLives {
            strikes = 0
        }
        qteEffort = 0
        qteRemaining = qteDuration
        interruptionEndsAt = Date().addingTimeInterval(qteDuration)
        lastInterruptionTickAt = Date()
        roundDisplay = min(roundsTotal, currentRoundIndex + 1)
        targetToken = "PATCH"
        stripTokens = []
        activeIndex = 0
        statusLine = "RAPID TAP REQUIRED. BUILD PATCH EFFORT."
        appendLog("SECURITY INTERRUPTION DETECTED.")
        startInterruptionTimer()
    }

    private func resolveInterruption(skipTransitions: Bool) {
        interruptionActive = false
        qteEffort = 0
        qteRemaining = 0
        interruptionEndsAt = nil
        lastInterruptionTickAt = nil
        stopInterruptionTimer()
        appendLog("PATCH COMPLETE. UPLINK RESTORED.")
        interruptionCompleted = true
        if currentRoundIndex >= roundSpecs.count {
            finishChallenge()
            return
        }
        if skipTransitions {
            configureRound(resetLives: true)
        } else {
            transitionOutOfInterruptionRound()
        }
    }

    private func startInterruptionTimer() {
        stopInterruptionTimer()
        interruptionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.interruptionActive else { return }
                guard let endsAt = self.interruptionEndsAt else { return }

                let now = Date()
                if let lastTick = self.lastInterruptionTickAt {
                    let delta = max(0, now.timeIntervalSince(lastTick))
                    self.qteEffort = max(0, self.qteEffort - (delta * self.qteDecayPerSecond))
                }
                self.lastInterruptionTickAt = now
                self.qteRemaining = max(0, endsAt.timeIntervalSince(now))
                self.statusLine = "PATCH EFFORT \(Int((self.qteEffort * 100).rounded()))% / \(Int((self.qteThreshold * 100).rounded()))%"

                if self.qteEffort >= self.qteThreshold {
                    self.resolveInterruption(skipTransitions: false)
                    return
                }

                if self.qteRemaining <= 0 {
                    self.handleInterruptionTimeout()
                }
            }
        }
        interruptionTimer?.tolerance = 0.02
    }

    private func stopInterruptionTimer() {
        interruptionTimer?.invalidate()
        interruptionTimer = nil
    }

    private func handleRoundTimeout() {
        stopRoundTimer()
        loseLifeAndContinue(
            eventLine: "ROUND \(roundDisplay) TIMEOUT.",
            retryAction: { [weak self] in
                self?.configureRound(resetLives: false)
            },
            clearInterruptionState: false
        )
    }

    private func handleInterruptionTimeout() {
        stopInterruptionTimer()
        loseLifeAndContinue(
            eventLine: "PATCH WINDOW EXPIRED.",
            retryAction: { [weak self] in
                self?.triggerInterruptionRound(resetLives: false)
            },
            clearInterruptionState: true
        )
    }

    private func loseLifeAndContinue(
        eventLine: String,
        retryAction: @escaping @MainActor () -> Void,
        clearInterruptionState: Bool
    ) {
        strikes += 1
        appendLog(eventLine)
        let remaining = livesRemaining
        if strikes >= 3 {
            failChallenge()
            return
        }

        if clearInterruptionState {
            interruptionActive = false
            qteEffort = 0
            qteRemaining = 0
            interruptionEndsAt = nil
            lastInterruptionTickAt = nil
        }

        statusLine = "LIFE LOST. \(remaining)/3 REMAINING."
        appendLog("LIFE LOST. ROUND CONTINUES.")

        startTransition(
            title: "TRACE DESYNC",
            subtitle: "\(remaining)/3 LIVES REMAIN",
            duration: transitionBeatDuration,
            completion: retryAction
        )
    }

    private func transitionIntoInterruptionRound() {
        startTransition(
            title: "COUNTERMEASURE",
            subtitle: "PATCH CHANNEL OPENING",
            duration: transitionBeatDuration
        ) { [weak self] in
            self?.triggerInterruptionRound(resetLives: true)
        }
    }

    private func transitionOutOfInterruptionRound() {
        let nextRound = min(roundsTotal, currentRoundIndex + 1)
        startTransition(
            title: "PATCH ACCEPTED",
            subtitle: "RESUME TRACE ROUND \(nextRound)",
            duration: transitionBeatDuration
        ) { [weak self] in
            self?.configureRound(resetLives: true)
        }
    }

    private func startTransition(
        title: String,
        subtitle: String,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        transitionWorkItem?.cancel()
        transitionTitle = title
        transitionSubtitle = subtitle
        transitionActive = true
        statusLine = "\(title) // \(subtitle)"

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .inChallenge else {
                    self.clearTransitionState()
                    return
                }
                self.clearTransitionState()
                completion()
            }
        }
        transitionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func clearTransitionState() {
        transitionWorkItem?.cancel()
        transitionWorkItem = nil
        transitionActive = false
        transitionTitle = ""
        transitionSubtitle = ""
    }

    private func appendLog(_ line: String) {
        commandLog.append(line)
        if commandLog.count > 8 {
            commandLog.removeFirst(commandLog.count - 8)
        }
    }

    var livesRemaining: Int {
        max(0, 3 - strikes)
    }
}

struct SettingsView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    @Environment(\.shellLayoutClass) private var shellLayoutClass
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel: SettingsViewModel
    @State private var showAdvancedTools = false
    @State private var showLoopRateModal = false

    private static let gridLoopIntervalKey = "PlayGridLoopIntervalMs"

    private var gridLoopMs: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.gridLoopIntervalKey)
        return stored > 0 ? max(20, min(500, stored)) : 140
    }

    init(
        appState: TubCompanionAppState,
        harnessClient: HarnessClient,
        externalAudioRouteMonitor: ExternalAudioRouteMonitor
    ) {
        self.appState = appState
        self.harnessClient = harnessClient
        self.externalAudioRouteMonitor = externalAudioRouteMonitor
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                appState: appState,
                harnessClient: harnessClient,
                externalAudioRouteMonitor: externalAudioRouteMonitor
            )
        )
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    CommandSignalRule()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 8) {
                                CommandStatusChip(
                                    title: "LINK",
                                    value: viewModel.harnessStatusLabel,
                                    isActive: viewModel.isHarnessLinked,
                                    accent: BrandingColors.glyphGreen
                                )
                                CommandStatusChip(
                                    title: "STAGE",
                                    value: harnessClient.stageFeedState.chipLabel,
                                    isActive: isStageFeedOnline,
                                    accent: BrandingColors.aberrationCyan
                                )
                                CommandStatusChip(
                                    title: "AUDIO",
                                    value: audioChipValue,
                                    isActive: isAudioOutputAvailable,
                                    accent: BrandingColors.warningYellow
                                )
                            }

                            SettingsSection(title: "CONNECTION") {
                                statusLine("HARNESS LINK", viewModel.harnessStatusLabel, active: viewModel.isHarnessLinked)
                                statusLine("STAGE FEED", harnessClient.stageFeedState.chipLabel, active: isStageFeedOnline)
                                statusLine("OUTPUT", appState.externalAudioRouteDescription, active: isAudioOutputAvailable)

                                HStack(spacing: 8) {
                                    CommandRailButton(
                                        title: "RECONNECT",
                                        systemImage: "arrow.triangle.2.circlepath",
                                        isEnabled: true,
                                        isActive: true,
                                        isSolid: true,
                                        accent: BrandingColors.glyphGreen
                                    ) {
                                        viewModel.reconnectHarness()
                                    }

                                    CommandRailButton(
                                        title: "RE-PROBE",
                                        systemImage: "antenna.radiowaves.left.and.right",
                                        isEnabled: true,
                                        isActive: false,
                                        accent: BrandingColors.aberrationCyan
                                    ) {
                                        viewModel.reprobeHarnessLink()
                                    }
                                }

                                Text(viewModel.harnessActionStatus)
                                    .playMono(10, weight: .semibold)
                                    .foregroundStyle(Color.white.opacity(0.66))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            SettingsSection(title: "APP") {
                                statusLine("SESSION ID", appState.sessionId ?? "NONE")
                                statusLine("ENTRY PATH", appState.lastEntryIntent?.title ?? "NONE")
                                statusLine("STEER ACCESS", appState.steerAccessState.chipLabel, active: isSteerAccessUnlocked)
                                actionRow(
                                    title: "RELOCK STEER",
                                    systemImage: "lock",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.relockSteer)
                                }
                                actionRow(
                                    title: "RESET ENTRY FLOW",
                                    systemImage: "arrow.counterclockwise",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.resetEntryFlow)
                                }
                            }

                            SettingsSection(title: "PLAY") {
                                actionRow(title: "LOOP RATE: \(gridLoopMs)ms", systemImage: "repeat") {
                                    showLoopRateModal = true
                                }
                            }

                            SettingsSection(title: "ABOUT") {
                                HStack(spacing: 12) {
                                    Image("AppIconDisplay")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 11))

                                    VStack(alignment: .leading, spacing: 3) {
                                        TubCorpWordmark(height: 18)
                                        Text("Public Space Governance Platform")
                                            .playSans(9, weight: .semibold)
                                            .foregroundStyle(Color.white.opacity(0.58))
                                    }

                                    Spacer(minLength: 0)
                                }

                                HStack(spacing: 8) {
                                    CommandStatusChip(
                                        title: "POLICY",
                                        value: "CONTROLLED",
                                        isActive: true,
                                        accent: BrandingColors.glyphGreen
                                    )
                                    CommandStatusChip(
                                        title: "OPS",
                                        value: "SUPERVISED",
                                        isActive: true,
                                        accent: BrandingColors.aberrationCyan
                                    )
                                    CommandStatusChip(
                                        title: "TRUST",
                                        value: "AUDITABLE",
                                        isActive: true,
                                        accent: BrandingColors.warningYellow
                                    )
                                }

                                Text("TubCorp provides end-to-end infrastructure for governed interaction in public spaces. From signal acquisition to behavioral inference to stage projection, every layer is policy-controlled, operator-supervised, and fully auditable.")
                                    .playSans(11, weight: .semibold)
                                    .foregroundStyle(Color.white.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 8) {
                                    externalLinkButton(
                                        title: "WEBSITE",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site",
                                        accent: BrandingColors.glyphGreen,
                                        isSolid: true
                                    )
                                    externalLinkButton(
                                        title: "COMPANY",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site/company",
                                        accent: BrandingColors.aberrationCyan
                                    )
                                }

                                HStack(spacing: 8) {
                                    externalLinkButton(
                                        title: "PLATFORM",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site/platform",
                                        accent: BrandingColors.glyphGreen
                                    )
                                    externalLinkButton(
                                        title: "OPERATORS",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site/operators",
                                        accent: BrandingColors.aberrationCyan
                                    )
                                }

                                HStack(spacing: 8) {
                                    externalLinkButton(
                                        title: "SOLUTIONS",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site/solutions",
                                        accent: BrandingColors.warningYellow
                                    )
                                    externalLinkButton(
                                        title: "PROCUREMENT",
                                        url: "https://cbassuarez.github.io/tubcorp-command-site/procurement",
                                        accent: BrandingColors.warningYellow
                                    )
                                }

                                externalLinkButton(
                                    title: "CASE STUDIES",
                                    url: "https://cbassuarez.github.io/tubcorp-command-site/case-studies",
                                    accent: BrandingColors.aberrationCyan
                                )
                            }

                            SettingsSection(title: "ADVANCED") {
                                CommandRailButton(
                                    title: showAdvancedTools ? "HIDE ADVANCED TOOLS" : "SHOW ADVANCED TOOLS",
                                    systemImage: showAdvancedTools ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                                    isEnabled: true,
                                    isActive: showAdvancedTools,
                                    accent: BrandingColors.warningYellow
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showAdvancedTools.toggle()
                                    }
                                }

                                if showAdvancedTools {
                                    actionRow(
                                        title: "DISCONNECT",
                                        systemImage: "bolt.slash",
                                        role: .destructive
                                    ) {
                                        viewModel.requestGuardedAction(.disconnectHarness)
                                    }
                                    actionRow(title: "ROTATE SESSION", systemImage: "arrow.clockwise") {
                                        viewModel.requestGuardedAction(.rotateSession)
                                    }
                                    actionRow(
                                        title: "CLEAR TEMP OVERLAYS",
                                        systemImage: "xmark.square",
                                        role: .destructive
                                    ) {
                                        viewModel.requestGuardedAction(.clearTemporaryOverlays)
                                    }
                                    actionRow(
                                        title: "CLEAR LEARN CONTEXT",
                                        systemImage: "eraser",
                                        role: .destructive
                                    ) {
                                        viewModel.requestGuardedAction(.clearLearnContext)
                                    }
                                    actionRow(
                                        title: "CLEAR PRESET",
                                        systemImage: "slider.horizontal.below.rectangle",
                                        role: .destructive
                                    ) {
                                        viewModel.requestGuardedAction(.clearPreset)
                                    }
                                    ForEach(viewModel.debugLines, id: \.self) { line in
                                        Text(line)
                                            .playMono(10, weight: .semibold)
                                            .foregroundStyle(Color.white.opacity(0.52))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }

                            covertTrigger
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, isPhoneLandscapeCompact ? 0 : 10)
                    }
                }
                .padding(.top, isPhoneLandscapeCompact ? 6 : 10)
                .padding(.bottom, isPhoneLandscapeCompact ? 0 : 10)

                if viewModel.showPowerUnlockGate {
                    SettingsPowerUnlockOverlay(
                        onUnlocked: {
                            viewModel.handlePowerUnlockSucceeded()
                        },
                        onCancel: {
                            viewModel.dismissPowerUnlockGate()
                        }
                    )
                    .transition(.opacity)
                    .zIndex(20)
                }

                if viewModel.showPowerLayerModal {
                    powerLayerModal
                        .transition(.opacity)
                        .zIndex(25)
                }

                if showLoopRateModal {
                    GridLoopRateModal(
                        currentMs: gridLoopMs,
                        onChangeMs: { ms in
                            let clamped = max(20, min(500, ms))
                            UserDefaults.standard.set(clamped, forKey: Self.gridLoopIntervalKey)
                        },
                        onClose: {
                            showLoopRateModal = false
                        }
                    )
                    .transition(.opacity)
                    .zIndex(30)
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("settings.root")
        .confirmationDialog(
            viewModel.pendingGuardedAction?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingGuardedAction != nil },
                set: { presented in
                    if !presented {
                        viewModel.dismissGuardedAction()
                    }
                }
            ),
            presenting: viewModel.pendingGuardedAction
        ) { action in
            Button(action.confirmTitle, role: action.role) {
                viewModel.executeGuardedAction(action)
            }
            Button("CANCEL", role: .cancel) {
                viewModel.dismissGuardedAction()
            }
        } message: { action in
            Text(action.message)
        }
    }

    private var isPhoneLandscapeCompact: Bool {
        shellLayoutClass == .phoneLandscapeCompact
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .playSans(12, weight: .bold)
                .foregroundStyle(Color.white.opacity(0.56))

            Text("System Controls")
                .playSans(22, weight: .black)
                .foregroundStyle(.white)

            Text("Clear status, quick actions, optional advanced tools.")
                .playSans(11, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func statusLine(_ key: String, _ value: String, active: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .playMono(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(minWidth: 106, alignment: .leading)
            Text(value.uppercased())
                .playMono(11, weight: .bold)
                .foregroundStyle(active ? BrandingColors.glyphGreen : Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var isSteerAccessUnlocked: Bool {
        if case .unlocked = appState.steerAccessState {
            return true
        }
        return false
    }

    private var isStageFeedOnline: Bool {
        harnessClient.stageFeedState != .standby
    }

    private var isAudioOutputAvailable: Bool {
        appState.isExternalAudioRouteActive || appState.isDebugOutputSimulated
    }

    private var audioChipValue: String {
        if appState.isExternalAudioRouteActive {
            return "DEVICE"
        }
        if appState.isDebugOutputSimulated {
            return "SPEAKER"
        }
        return "MISSING"
    }

    private func actionRow(
        title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        CommandRailButton(
            title: title,
            systemImage: systemImage,
            isEnabled: true,
            isActive: false,
            accent: role == .destructive ? BrandingColors.warningYellow : BrandingColors.glyphGreen,
            action: action
        )
        .accessibilityLabel(title.lowercased())
    }

    private func externalLinkButton(
        title: String,
        url: String,
        accent: Color,
        isSolid: Bool = false
    ) -> some View {
        CommandRailButton(
            title: title,
            systemImage: "arrow.up.right",
            isEnabled: true,
            isActive: !isSolid,
            isSolid: isSolid,
            accent: accent
        ) {
            guard let destination = URL(string: url) else { return }
            openURL(destination)
        }
        .accessibilityLabel("\(title.lowercased()) link")
        .accessibilityHint("Opens \(url)")
    }

    private var covertTrigger: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommandSignalRule(opacity: 0.11)
            HStack(spacing: 8) {
                Text("BUILD SIGNATURE \(String((appState.sessionId ?? "none").prefix(8)).uppercased())")
                    .playMono(9, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.36))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            CommandRailButton(
                title: "SPECIAL PRIVILEGES",
                systemImage: "key",
                isEnabled: true,
                isActive: false,
                accent: BrandingColors.warningYellow
            ) {
                viewModel.beginPowerUnlockGate()
            }
            .accessibilityIdentifier("settings.covert.trigger")
            .accessibilityLabel("Special privileges")
            .accessibilityHint("Opens access required prompt")
        }
    }

    private var powerLayerModal: some View {
        ZStack {
            Color.black.opacity(0.86)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.dismissPowerLayerModal()
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Covert Power Layer")
                        .playSans(14, weight: .black)
                        .foregroundStyle(.white)
                        .chromaticAberration()
                    Spacer()
                    Button {
                        viewModel.dismissPowerLayerModal()
                    } label: {
                        Text("Close")
                            .playSans(11, weight: .bold)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(minWidth: 84, minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.covert.modal.close")
                }

                CommandSignalRule(opacity: 0.18)

                HStack(spacing: 8) {
                    CommandStatusChip(
                        title: "SYNC",
                        value: viewModel.vectorSyncChipValue,
                        isActive: viewModel.isHarnessLinked,
                        accent: BrandingColors.glyphGreen
                    )
                    CommandStatusChip(
                        title: "SOURCE",
                        value: viewModel.vectorSourceChipValue,
                        isActive: true,
                        accent: BrandingColors.aberrationCyan
                    )
                    CommandStatusChip(
                        title: "STATE",
                        value: viewModel.vectorStateChipValue,
                        isActive: viewModel.pendingRemoteOperatorVector == nil,
                        accent: BrandingColors.warningYellow
                    )
                }

                statusLine("ACCESS", viewModel.advancedAccessState.label, active: viewModel.advancedAccessState == .unlocked)
                statusLine("TEMPORARY OVERRIDES", "ACTIVE")
                statusLine("AUTO-RESET IN", viewModel.countdownDisplay, active: true)

                CommandVectorRail(
                    title: "PARAM VECTOR",
                    value: viewModel.operatorVector.param
                ) { value in
                    viewModel.setVector(param: value)
                } onEditingChanged: { editing in
                    editing ? viewModel.beginVectorEdit() : viewModel.endVectorEdit()
                }

                CommandVectorRail(
                    title: "THOUGHT VECTOR",
                    value: viewModel.operatorVector.thought
                ) { value in
                    viewModel.setVector(thought: value)
                } onEditingChanged: { editing in
                    editing ? viewModel.beginVectorEdit() : viewModel.endVectorEdit()
                }

                CommandVectorRail(
                    title: "AUDIO VECTOR",
                    value: viewModel.operatorVector.audio
                ) { value in
                    viewModel.setVector(audio: value)
                } onEditingChanged: { editing in
                    editing ? viewModel.beginVectorEdit() : viewModel.endVectorEdit()
                }

                actionRow(
                    title: "RESET TO NEUTRAL",
                    systemImage: "arrow.uturn.backward",
                    role: .destructive
                ) {
                    viewModel.resetVectorsToNeutral(sendToHarness: true)
                }
                actionRow(
                    title: "LOCK POWER LAYER",
                    systemImage: "lock.fill",
                    role: .destructive
                ) {
                    viewModel.relockPowerLayer()
                }

                statusLine(
                    "STATUS",
                    viewModel.vectorAckChipValue,
                    active: viewModel.vectorAckChipValue == "SUCCESS"
                )

                Text(viewModel.vectorAckDetail)
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
            .padding(.horizontal, 20)
        }
        .accessibilityIdentifier("settings.covert.modal")
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(BrandingColors.glyphGreen.opacity(0.86))
                    .frame(width: 2, height: 12)
                Text(title.uppercased())
                    .playSans(11, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            CommandSignalRule(opacity: 0.14)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

enum CommandVectorRailMath {
    static func normalizedValue(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 1 else { return 0 }
        let clamped = max(0, min(width, x))
        let scalar = Double(clamped / width)
        return max(-1, min(1, (scalar * 2) - 1))
    }

    static func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let clampedValue = max(-1, min(1, value))
        return CGFloat((clampedValue + 1) * 0.5) * width
    }
}

private struct CommandVectorRail: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                Text(Self.signed(value))
                    .playMono(11, weight: .bold)
                    .foregroundStyle(BrandingColors.aberrationCyan)
            }

            HStack(spacing: 10) {
                Button {
                    onChange(max(-1, value - 0.05))
                } label: {
                    Text("-")
                        .playSans(16, weight: .bold)
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    let x = CommandVectorRailMath.xPosition(for: value, width: width)
                    let center = width * 0.5

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 32)

                        Rectangle()
                            .fill(BrandingColors.glyphGreen.opacity(0.18))
                            .frame(width: max(0, min(abs(x - center), width)), height: 32)
                            .offset(x: min(x, center))

                        Rectangle()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 1, height: 32)
                            .offset(x: center)

                        Rectangle()
                            .fill((isDragging ? BrandingColors.aberrationCyan : BrandingColors.glyphGreen).opacity(0.9))
                            .frame(width: 14, height: 40)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
                            }
                            .offset(x: max(0, min(width - 14, x - 7)))
                            .chromaticAberration()
                    }
                    .overlay {
                        Rectangle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { gesture in
                                if !isDragging {
                                    isDragging = true
                                    onEditingChanged(true)
                                }
                                onChange(CommandVectorRailMath.normalizedValue(for: gesture.location.x, width: width))
                            }
                            .onEnded { _ in
                                if isDragging {
                                    isDragging = false
                                    onEditingChanged(false)
                                }
                            }
                    )
                }
                .frame(height: 44)

                Button {
                    onChange(min(1, value + 0.05))
                } label: {
                    Text("+")
                        .playSans(16, weight: .bold)
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear {
            if isDragging {
                isDragging = false
                onEditingChanged(false)
            }
        }
    }

    private static func signed(_ value: Double) -> String {
        String(format: "%+.2f", max(-1, min(1, value)))
    }
}

private struct SettingsPowerUnlockOverlay: View {
    let onUnlocked: () -> Void
    let onCancel: () -> Void
    @StateObject private var viewModel = SettingsPowerUnlockChallengeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var unlockCallbackFired = false
    @State private var showPasswordModal = false
    @State private var challengeArmed = false
    @State private var failureGlitchPhase = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Privileged Module")
                        .playSans(12, weight: .bold)
                        .foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                    Button {
                        onCancel()
                    } label: {
                        Text("Abort")
                            .playSans(11, weight: .bold)
                            .foregroundStyle(Color.white.opacity(0.82))
                            .frame(minWidth: 72, minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.unlock.abort")
                }

                CommandSignalRule(opacity: 0.2)

                if case .grantedAnimating = viewModel.state {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Access Granted")
                            .playSans(34, weight: .black)
                            .foregroundStyle(.white)
                            .chromaticAberration()
                            .scaleEffect(reduceMotion ? 1.0 : 1.04)
                        Text("Covert controls exposed. Operator trace minimized.")
                            .playSans(11, weight: .semibold)
                            .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if challengeArmed {
                    challengeBody
                } else {
                    accessRequiredBody
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

            if showPasswordModal {
                AccessPasswordModal(
                    idPrefix: "settings.unlock.password",
                    title: "SPECIAL PRIVILEGES",
                    subtitle: "ENTER ACCESS TOKEN",
                    onCancel: { showPasswordModal = false },
                    onEnterSuccess: {
                        showPasswordModal = false
                        challengeArmed = false
                        viewModel.unlockViaCredentialBypass()
                    },
                    onHack: {
                        showPasswordModal = false
                        challengeArmed = true
                        viewModel.activate()
                    }
                )
            }
        }
        .onAppear {
            challengeArmed = false
        }
        .onChange(of: viewModel.state) { _, state in
            if case .unlocked = state, !unlockCallbackFired {
                unlockCallbackFired = true
                onUnlocked()
            }
            if case .locked = state, !showPasswordModal {
                challengeArmed = false
            }
            if case .cooldown = state {
                triggerFailureGlitch()
            }
        }
        .accessibilityIdentifier("settings.unlock.overlay")
    }

    private var accessRequiredBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Access Required")
                .playSans(28, weight: .black)
                .foregroundStyle(.white)
                .chromaticAberration()
                .accessibilityIdentifier("settings.unlock.required.title")

            Text("POWER LAYER SEALED.")
                .playMono(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.74))

            Text("Press enter to authenticate access.")
                .playSans(10, weight: .semibold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))

            CommandRailButton(
                title: "ENTER",
                systemImage: "arrow.right",
                isEnabled: true,
                isActive: true,
                isSolid: true,
                accent: BrandingColors.glyphGreen
            ) {
                showPasswordModal = true
            }
            .accessibilityIdentifier("settings.unlock.begin")
            .accessibilityLabel("Unlock special privileges")
            .accessibilityHint("Opens access token prompt")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var challengeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trace Active")
                .playSans(28, weight: .black)
                .foregroundStyle(.white)
                .chromaticAberration()

            Text("Align target tokens to maintain access.")
                .playSans(10, weight: .semibold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))

            HStack(spacing: 10) {
                chip(title: "ROUND", value: "\(viewModel.roundDisplay)/\(viewModel.roundsTotal)")
                chip(title: "TARGET", value: viewModel.targetToken)
                chip(title: "LIVES", value: "\(viewModel.livesRemaining)/3")
                chip(title: "TIME", value: viewModel.interruptionActive ? String(format: "%.1fs", viewModel.qteRemaining) : String(format: "%.1fs", viewModel.roundTimeRemaining))
            }

            Text(viewModel.statusLine)
                .playMono(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.7))

            if isFailureState {
                failurePanel
            } else if viewModel.transitionActive {
                transitionPanel
            } else if viewModel.interruptionActive {
                interruptionPanel
            } else {
                tokenGrid
            }

            primaryActionButton

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(viewModel.commandLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .playMono(10, weight: .semibold)
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenRows: [[Int]] {
        let count = viewModel.stripTokens.count
        guard count > 0 else { return [] }
        let columns: Int
        switch viewModel.roundDisplay {
        case 1: columns = 16
        case 2: columns = 8
        default: columns = 4
        }

        var rows: [[Int]] = []
        var start = 0
        while start < count {
            let end = min(start + columns, count)
            rows.append(Array(start..<end))
            start = end
        }
        return rows
    }

    private var interruptionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYSTEM COUNTERMEASURE DETECTED.")
                .playMono(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.74))

            Text("Tap patch fast until effort crosses the marker before time hits 0.")
                .playSans(10, weight: .bold)
                .foregroundStyle(BrandingColors.warningYellow)

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 12)

                    Rectangle()
                        .fill(BrandingColors.warningYellow.opacity(0.8))
                        .frame(width: max(6, 260 * viewModel.qteEffort), height: 12)

                    Rectangle()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 2, height: 14)
                        .offset(x: 260 * viewModel.qteThreshold - 1)
                }
                .frame(width: 260, alignment: .leading)

                HStack(spacing: 12) {
                    Text("EFFORT \(Int((viewModel.qteEffort * 100).rounded()))%")
                    Text("THRESHOLD \(Int((viewModel.qteThreshold * 100).rounded()))%")
                    Text("TIME \(String(format: "%.1f", viewModel.qteRemaining))s")
                }
                .playMono(10, weight: .bold)
                .foregroundStyle(BrandingColors.warningYellow)
            }
        }
        .padding(.vertical, 8)
    }

    private var transitionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.transitionTitle)
                .playSans(16, weight: .black)
                .foregroundStyle(.white)
                .chromaticAberration()
            Text(viewModel.transitionSubtitle)
                .playMono(10, weight: .semibold)
                .foregroundStyle(BrandingColors.warningYellow)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(BrandingColors.glyphGreen.opacity(0.82))
                        .frame(maxWidth: 220)
                }
        }
        .padding(.vertical, 8)
    }

    private var primaryActionButton: some View {
        CommandRailButton(
            title: primaryActionLabel,
            systemImage: primaryActionIcon,
            isEnabled: primaryActionEnabled,
            isActive: true,
            isSolid: true,
            accent: viewModel.interruptionActive || viewModel.transitionActive || isFailureState ? BrandingColors.warningYellow : BrandingColors.glyphGreen
        ) {
            switch viewModel.state {
            case .inChallenge:
                if viewModel.transitionActive {
                    break
                } else if viewModel.interruptionActive {
                    viewModel.interruptionTap()
                } else {
                    viewModel.matchTapped()
                }
            case .locked:
                viewModel.retryTapped()
            default:
                break
            }
        }
        .frame(minHeight: 54)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(primaryActionIdentifier)
    }

    private var primaryActionLabel: String {
        switch viewModel.state {
        case .inChallenge:
            if viewModel.transitionActive {
                return "SYNCING..."
            }
            return viewModel.interruptionActive ? "PATCH LINK" : "MATCH"
        case .cooldown:
            return "LOCKED \(Int(ceil(viewModel.cooldownRemaining)))s"
        case .locked:
            return "RETRY"
        case .grantedAnimating:
            return "GRANTING..."
        case .unlocked:
            return "UNLOCKED"
        }
    }

    private var primaryActionIcon: String {
        switch viewModel.state {
        case .inChallenge:
            if viewModel.transitionActive { return "arrow.triangle.2.circlepath" }
            return viewModel.interruptionActive ? "bolt.trianglebadge.exclamationmark" : "checkmark.circle"
        case .cooldown: return "lock.fill"
        case .locked: return "arrow.counterclockwise"
        case .grantedAnimating: return "checkmark.seal.fill"
        case .unlocked: return "lock.open.fill"
        }
    }

    private var primaryActionEnabled: Bool {
        switch viewModel.state {
        case .inChallenge, .locked:
            return !viewModel.transitionActive
        default:
            return false
        }
    }

    private var primaryActionStroke: Color {
        if viewModel.interruptionActive || isFailureState {
            return BrandingColors.warningYellow.opacity(0.76)
        }
        return BrandingColors.glyphGreen.opacity(0.72)
    }

    private var primaryActionIdentifier: String {
        switch viewModel.state {
        case .inChallenge:
            if viewModel.transitionActive {
                return "settings.unlock.transition"
            }
            return viewModel.interruptionActive ? "settings.unlock.patch" : "settings.unlock.match"
        default:
            return "settings.unlock.retry"
        }
    }

    private var isFailureState: Bool {
        switch viewModel.state {
        case .cooldown:
            return true
        case .locked:
            return viewModel.strikes >= 3
        default:
            return false
        }
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trace Wiped")
                .playSans(20, weight: .black)
                .foregroundStyle(BrandingColors.warningYellow)
                .offset(x: failureGlitchPhase ? -5 : 4)
                .opacity(failureGlitchPhase ? 0.82 : 1.0)
                .chromaticAberration()

            Text("COUNTER-FORENSICS TRIGGERED. WAIT FOR RETRY WINDOW.")
                .playMono(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.66))
        }
    }

    private func triggerFailureGlitch() {
        failureGlitchPhase = false
        withAnimation(.easeInOut(duration: 0.07).repeatCount(7, autoreverses: true)) {
            failureGlitchPhase = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            failureGlitchPhase = false
        }
    }

    private var tokenGrid: some View {
        VStack(spacing: 6) {
            ForEach(Array(tokenRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { index in
                        let token = viewModel.stripTokens[index]
                        let isActive = index == viewModel.activeIndex
                        Button {
                            viewModel.matchTapped()
                        } label: {
                            Text(token)
                                .playMono(isActive ? 15 : 13, weight: .bold)
                                .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.56))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .overlay {
                                    Rectangle()
                                        .stroke(
                                            isActive ? BrandingColors.glyphGreen.opacity(0.72) : Color.white.opacity(0.16),
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func chip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .playMono(9, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.56))
            Text(value)
                .playMono(13, weight: .bold)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay {
            Rectangle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }
}

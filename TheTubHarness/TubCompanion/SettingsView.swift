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
        abs(param) < 0.0001 && abs(thought) < 0.0001 && abs(audio) < 0.0001
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
    @Published var pendingGuardedAction: SettingsGuardedAction?
    @Published var showPowerUnlockGate = false
    @Published private(set) var advancedAccessState: AdvancedSettingsAccessState = .locked
    @Published private(set) var harnessActionStatus: String = "READY."
    @Published private(set) var lastOperatorAck: String = "NO VECTOR ACK YET."
    @Published private(set) var operatorVector: OperatorVectorState = .zero
    @Published private(set) var operatorVectorExpiresAt: Date?
    @Published private(set) var vectorCountdownLabel: String = "00:00:00"

    private let appState: TubCompanionAppState
    private let harnessClient: HarnessClient
    private let externalAudioRouteMonitor: ExternalAudioRouteMonitor
    private let vectorTTLSeconds: TimeInterval = 60 * 60

    private var decayStartAt: Date?
    private var decayStartVector: OperatorVectorState = .zero
    private var decayTicker: AnyCancellable?
    private var pendingVectorSendWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

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
                }
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
        let outputTypes = externalAudioRouteMonitor.lastSeenOutputPortTypes
            .map { $0.rawValue.uppercased() }
            .joined(separator: ", ")
        return [
            "DEBUG OUTPUT SIMULATED: \(appState.isDebugOutputSimulated ? "YES" : "NO")",
            "CABLE ROUTE SIMULATED: \(appState.isCableRouteSimulated ? "YES" : "NO")",
            "OUTPUT PORT TYPES: \(outputTypes.isEmpty ? "NONE" : outputTypes)"
        ]
    }

    var countdownDisplay: String {
        operatorVectorExpiresAt == nil ? "NEUTRAL" : vectorCountdownLabel
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
        harnessActionStatus = "ATTEMPTING HARNESS LINK..."
        harnessClient.connectToHarness(host: address.host, port: address.port)
        runHandshake(host: address.host, port: address.port, reconnectOnResolve: true)
    }

    func reprobeHarnessLink() {
        let address = normalizedAddress()
        appState.updateHarnessAddress(host: address.host, port: address.port)
        harnessActionStatus = "PROBING HANDSHAKE..."
        runHandshake(host: address.host, port: address.port, reconnectOnResolve: false)
    }

    func beginPowerUnlockGate() {
        guard advancedAccessState != .unlocked else { return }
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

    func handlePowerUnlockSucceeded() {
        showPowerUnlockGate = false
        advancedAccessState = .grantedAnimating
        harnessActionStatus = "COVERT LAYER AUTHENTICATED."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if case .grantedAnimating = self.advancedAccessState {
                self.advancedAccessState = .unlocked
            }
        }
    }

    func relockPowerLayer() {
        advancedAccessState = .locked
        resetVectorsToNeutral(sendToHarness: true)
        harnessActionStatus = "COVERT LAYER LOCKED."
    }

    func setVector(param: Double? = nil, thought: Double? = nil, audio: Double? = nil) {
        guard advancedAccessState == .unlocked else { return }

        var next = operatorVector
        if let param { next.param = Self.clampSigned(param) }
        if let thought { next.thought = Self.clampSigned(thought) }
        if let audio { next.audio = Self.clampSigned(audio) }

        operatorVector = next
        if next.isNeutral {
            resetVectorsToNeutral(sendToHarness: true)
            return
        }

        let now = Date()
        decayStartAt = now
        decayStartVector = next
        operatorVectorExpiresAt = now.addingTimeInterval(vectorTTLSeconds)
        vectorCountdownLabel = Self.durationLabel(from: vectorTTLSeconds)

        queueVectorSend(ttlSeconds: vectorTTLSeconds)
    }

    func resetVectorsToNeutral(sendToHarness: Bool) {
        operatorVector = .zero
        decayStartAt = nil
        decayStartVector = .zero
        operatorVectorExpiresAt = nil
        vectorCountdownLabel = "00:00:00"
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

                if reconnectOnResolve &&
                    (resolvedHost != host || resolvedPort != port || !self.isHarnessLinked) {
                    self.harnessClient.disconnect()
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
        harnessClient.sendOperatorVector(
            paramVector: operatorVector.param,
            thoughtVector: operatorVector.thought,
            audioVector: operatorVector.audio,
            ttlSeconds: ttlSeconds,
            sessionId: sessionId
        )
    }

    private func applyDecay(now: Date) {
        guard let decayStartAt, let expiresAt = operatorVectorExpiresAt else { return }
        guard advancedAccessState == .unlocked else { return }

        if now >= expiresAt {
            if !operatorVector.isNeutral {
                operatorVector = .zero
                sendCurrentVector(ttlSeconds: 0)
            }
            self.decayStartAt = nil
            decayStartVector = .zero
            operatorVectorExpiresAt = nil
            vectorCountdownLabel = "00:00:00"
            harnessActionStatus = "OPERATOR VECTOR EXPIRED TO NEUTRAL."
            return
        }

        let elapsed = max(0, now.timeIntervalSince(decayStartAt))
        let progress = max(0, min(1, elapsed / vectorTTLSeconds))
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
    @Published private(set) var cooldownRemaining: TimeInterval = 0
    @Published private(set) var statusLine: String = "POWER LAYER LOCKED."
    @Published private(set) var commandLog: [String] = ["PRIVILEGED MODULE SEALED."]
    @Published private(set) var interruptionActive = false
    @Published private(set) var qteEffort: Double = 0
    @Published private(set) var qteThreshold: Double = 0.78
    @Published private(set) var qteRemaining: TimeInterval = 0

    private let codeRoundCount = 3
    private let codeRoundSpeeds: [Double] = [5.6, 6.4, 7.1]
    private let codeWindowTolerance = 1
    private let qteDuration: TimeInterval = 3.2
    private let qteTapGain = 0.11
    private let qteDecayPerSecond = 0.46

    private var currentRoundIndex: Int = 0
    private var targetSlotIndex: Int = 0
    private var rollTimer: Timer?
    private var cooldownTimer: Timer?
    private var interruptionTimer: Timer?
    private var interruptionEndsAt: Date?
    private var lastInterruptionTickAt: Date?
    private var lastTickAt: Date?
    private var roundSpecs: [SteerHackRoundSpec] = []

    deinit {
        rollTimer?.invalidate()
        cooldownTimer?.invalidate()
        interruptionTimer?.invalidate()
    }

    func activate() {
        guard state == .locked else { return }
        startChallenge()
    }

    func unlockViaCredentialBypass() {
        guard state != .unlocked else { return }
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
        resolveMatch(didMatch: didMatch, token: token)
    }

    func submitMatchForTesting(_ didMatch: Bool) {
        guard state == .inChallenge else { return }
        guard !interruptionActive else { return }
        resolveMatch(didMatch: didMatch, token: targetToken)
    }

    func interruptionTap() {
        guard state == .inChallenge else { return }
        guard interruptionActive else { return }
        qteEffort = min(1, qteEffort + qteTapGain)
        statusLine = "PATCH EFFORT \(Int((qteEffort * 100).rounded()))% / \(Int((qteThreshold * 100).rounded()))%"
        if qteEffort >= qteThreshold {
            resolveInterruption()
        }
    }

    func resolveInterruptionForTesting() {
        guard interruptionActive else { return }
        resolveInterruption()
    }

    private func resolveMatch(didMatch: Bool, token: String) {
        if didMatch {
            appendLog("MATCH \(token) ACCEPTED.")
            currentRoundIndex += 1
            if currentRoundIndex >= roundSpecs.count {
                triggerInterruptionRound()
            } else {
                configureRound()
            }
        } else {
            strikes += 1
            appendLog("MISS \(token). DRIFT DETECTED.")
            if strikes >= 3 {
                failChallenge()
            }
        }
    }

    func retryTapped() {
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
        stopCooldownTimer()
        stopInterruptionTimer()
        stopRollTimer()
        roundSpecs = makeRoundSpecs()
        strikes = 0
        cooldownRemaining = 0
        currentRoundIndex = 0
        roundsTotal = roundSpecs.count + 1
        interruptionActive = false
        qteEffort = 0
        qteRemaining = 0
        interruptionEndsAt = nil
        lastInterruptionTickAt = nil
        state = .inChallenge
        configureRound()
    }

    private func configureRound() {
        let spec = currentSpec
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
        stopRollTimer()
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
        stopRollTimer()
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

    private func stopCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }

    private func triggerInterruptionRound() {
        stopRollTimer()
        interruptionActive = true
        qteEffort = 0
        qteRemaining = qteDuration
        interruptionEndsAt = Date().addingTimeInterval(qteDuration)
        lastInterruptionTickAt = Date()
        roundDisplay = roundsTotal
        targetToken = "PATCH"
        stripTokens = []
        activeIndex = 0
        statusLine = "UPLINK FAILURE. BUILD PATCH EFFORT."
        appendLog("SECURITY INTERRUPTION DETECTED.")
        startInterruptionTimer()
    }

    private func resolveInterruption() {
        interruptionActive = false
        qteEffort = 0
        qteRemaining = 0
        interruptionEndsAt = nil
        lastInterruptionTickAt = nil
        stopInterruptionTimer()
        appendLog("PATCH COMPLETE. UPLINK RESTORED.")
        finishChallenge()
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
                    self.resolveInterruption()
                    return
                }

                if self.qteRemaining <= 0 {
                    self.appendLog("PATCH WINDOW EXPIRED.")
                    self.failChallenge()
                }
            }
        }
        interruptionTimer?.tolerance = 0.02
    }

    private func stopInterruptionTimer() {
        interruptionTimer?.invalidate()
        interruptionTimer = nil
    }

    private func appendLog(_ line: String) {
        commandLog.append(line)
        if commandLog.count > 8 {
            commandLog.removeFirst(commandLog.count - 8)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor
    @StateObject private var viewModel: SettingsViewModel

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
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    CommandSignalRule()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 18) {
                            SettingsSection(title: "SYSTEM STATUS") {
                                statusLine("HARNESS LINK", viewModel.harnessStatusLabel, active: viewModel.isHarnessLinked)
                                statusLine("STAGE FEED", harnessClient.stageFeedState.chipLabel, active: harnessClient.stageFeedState != .standby)
                                statusLine("SESSION ID", appState.sessionId ?? "NONE")
                                statusLine("ROUTE", appState.externalAudioRouteDescription)
                                statusLine("LAST LINK", viewModel.lastSessionTimestampLabel)
                            }

                            SettingsSection(title: "HARNESS LINK") {
                                actionRow(
                                    title: "RECONNECT",
                                    action: viewModel.reconnectHarness
                                )
                                actionRow(
                                    title: "RE-PROBE HANDSHAKE",
                                    action: viewModel.reprobeHarnessLink
                                )
                                actionRow(
                                    title: "DISCONNECT",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.disconnectHarness)
                                }
                                Text(viewModel.harnessActionStatus)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(0.9)
                                    .foregroundStyle(Color.white.opacity(0.66))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            SettingsSection(title: "SESSION + ENTRY") {
                                statusLine("LAST ENTRY PATH", appState.lastEntryIntent?.title ?? "NONE")
                                statusLine("ENTRY FLOW", appState.entryIntent?.title ?? "UNSET")

                                actionRow(title: "ROTATE SESSION") {
                                    viewModel.requestGuardedAction(.rotateSession)
                                }
                                actionRow(
                                    title: "CLEAR PRESET",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.clearPreset)
                                }
                                actionRow(
                                    title: "RESET ENTRY FLOW",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.resetEntryFlow)
                                }
                            }

                            SettingsSection(title: "RECOVERY") {
                                actionRow(
                                    title: "RELOCK STEER",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.relockSteer)
                                }
                                actionRow(
                                    title: "CLEAR TEMP OVERLAYS",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.clearTemporaryOverlays)
                                }
                                actionRow(
                                    title: "CLEAR LEARN CONTEXT",
                                    role: .destructive
                                ) {
                                    viewModel.requestGuardedAction(.clearLearnContext)
                                }
                            }

                            SettingsSection(title: "DEBUG DIAGNOSTICS (READ-ONLY)") {
                                ForEach(viewModel.debugLines, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .tracking(0.9)
                                        .foregroundStyle(Color.white.opacity(0.72))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            covertTrigger

                            if viewModel.advancedAccessState == .unlocked || viewModel.advancedAccessState == .grantedAnimating {
                                SettingsSection(title: "COVERT POWER LAYER") {
                                    statusLine("ACCESS", viewModel.advancedAccessState.label, active: viewModel.advancedAccessState == .unlocked)
                                    statusLine("TEMPORARY OVERRIDES", "ACTIVE")
                                    statusLine("AUTO-RESET IN", viewModel.countdownDisplay, active: true)

                                    SettingsVectorControlRow(
                                        title: "PARAM VECTOR",
                                        value: viewModel.operatorVector.param
                                    ) { value in
                                        viewModel.setVector(param: value)
                                    }

                                    SettingsVectorControlRow(
                                        title: "THOUGHT VECTOR",
                                        value: viewModel.operatorVector.thought
                                    ) { value in
                                        viewModel.setVector(thought: value)
                                    }

                                    SettingsVectorControlRow(
                                        title: "AUDIO VECTOR",
                                        value: viewModel.operatorVector.audio
                                    ) { value in
                                        viewModel.setVector(audio: value)
                                    }

                                    actionRow(
                                        title: "RESET TO NEUTRAL",
                                        role: .destructive
                                    ) {
                                        viewModel.resetVectorsToNeutral(sendToHarness: true)
                                    }
                                    actionRow(
                                        title: "LOCK POWER LAYER",
                                        role: .destructive
                                    ) {
                                        viewModel.relockPowerLayer()
                                    }

                                    Text("VECTOR ACK: \(viewModel.lastOperatorAck)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .tracking(0.9)
                                        .foregroundStyle(Color.white.opacity(0.68))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: max(proxy.size.height * 0.8, 560), alignment: .top)
                    }
                }
                .padding(.top, max(proxy.safeAreaInsets.top + 6, 12))
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 10, 14))

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETTINGS")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.56))

            Text("OPERATOR CONSOLE")
                .font(.system(.title2, design: .monospaced, weight: .black))
                .tracking(1.2)
                .foregroundStyle(.white)
                .chromaticAberration()

            Text("AUTO-LINK // RECOVERY // COVERT CONTROL LAYER")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func statusLine(_ key: String, _ value: String, active: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(minWidth: 112, alignment: .leading)
            Text(value.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(active ? BrandingColors.glyphGreen : Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func actionRow(
        title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        CommandRailButton(
            title: title,
            isEnabled: true,
            isActive: false,
            accent: role == .destructive ? BrandingColors.warningYellow : BrandingColors.glyphGreen,
            action: action
        )
        .accessibilityLabel(title.lowercased())
    }

    private var covertTrigger: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommandSignalRule(opacity: 0.11)
            HStack(spacing: 8) {
                Text("BUILD SIGNATURE \(String((appState.sessionId ?? "none").prefix(8)).uppercased())")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.white.opacity(0.36))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            CommandRailButton(
                title: "SPECIAL PRIVILEGES",
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            CommandSignalRule(opacity: 0.14)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct SettingsVectorControlRow: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                Text(Self.signed(value))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(BrandingColors.aberrationCyan)
            }

            HStack(spacing: 10) {
                Button {
                    onChange(max(-1, value - 0.05))
                } label: {
                    Text("-")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { value },
                        set: { onChange($0) }
                    ),
                    in: -1...1
                )
                .tint(BrandingColors.glyphGreen)

                Button {
                    onChange(min(1, value + 0.05))
                } label: {
                    Text("+")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
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
                    Text("PRIVILEGED MODULE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                    Button {
                        onCancel()
                    } label: {
                        Text("ABORT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color.white.opacity(0.82))
                            .frame(minWidth: 72, minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.unlock.abort")
                }

                CommandSignalRule(opacity: 0.2)

                if case .grantedAnimating = viewModel.state {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACCESS GRANTED")
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(.white)
                            .chromaticAberration()
                            .scaleEffect(reduceMotion ? 1.0 : 1.04)
                        Text("COVERT CONTROLS EXPOSED. OPERATOR TRACE MINIMIZED.")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.0)
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
            Text("ACCESS REQUIRED")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
                .chromaticAberration()
                .accessibilityIdentifier("settings.unlock.required.title")

            Text("POWER LAYER SEALED.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.74))

            Text("PRESS ENTER TO AUTHENTICATE ACCESS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))

            CommandRailButton(
                title: "ENTER",
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
            Text("TRACE ACTIVE")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
                .chromaticAberration()

            Text("ALIGN TARGET TOKENS TO MAINTAIN ACCESS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))

            HStack(spacing: 10) {
                chip(title: "ROUND", value: "\(viewModel.roundDisplay)/\(viewModel.roundsTotal)")
                chip(title: "TARGET", value: viewModel.targetToken)
                chip(title: "STRIKES", value: "\(viewModel.strikes)/3")
            }

            Text(viewModel.statusLine)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.7))

            if isFailureState {
                failurePanel
            } else if viewModel.interruptionActive {
                interruptionPanel
            } else {
                tokenGrid
            }

            primaryActionButton

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(viewModel.commandLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
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
            Text("WARNING: LINK DESTABILIZED. BUILD PATCH EFFORT.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.74))

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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(BrandingColors.warningYellow)
            }
        }
        .padding(.vertical, 8)
    }

    private var primaryActionButton: some View {
        Button {
            switch viewModel.state {
            case .inChallenge:
                if viewModel.interruptionActive {
                    viewModel.interruptionTap()
                } else {
                    viewModel.matchTapped()
                }
            case .locked:
                viewModel.retryTapped()
            default:
                break
            }
        } label: {
            Text(primaryActionLabel)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(primaryActionEnabled ? .white : Color.white.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background {
                    if isFailureState, primaryActionEnabled {
                        Rectangle().fill(BrandingColors.warningYellow.opacity(0.2))
                    }
                }
                .overlay {
                    Rectangle()
                        .stroke(primaryActionStroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!primaryActionEnabled)
        .accessibilityIdentifier(primaryActionIdentifier)
    }

    private var primaryActionLabel: String {
        switch viewModel.state {
        case .inChallenge:
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

    private var primaryActionEnabled: Bool {
        switch viewModel.state {
        case .inChallenge, .locked:
            return true
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
            Text("TRACE WIPED")
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(BrandingColors.warningYellow)
                .offset(x: failureGlitchPhase ? -5 : 4)
                .opacity(failureGlitchPhase ? 0.82 : 1.0)
                .chromaticAberration()

            Text("COUNTER-FORENSICS TRIGGERED. WAIT FOR RETRY WINDOW.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
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
                                .font(.system(size: isActive ? 15 : 13, weight: .bold, design: .monospaced))
                                .tracking(1.0)
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
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.56))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(1.0)
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

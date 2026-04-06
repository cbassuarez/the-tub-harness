//
//  SoftLinkCoordinator.swift
//  TheTubHarness
//
//  Soft-link system: click-free channel activation via JOLT gesture.
//  Channels 2-N start at -inf. Staff gesture (3 taps + hold) opens a
//  12s pairing window. Plug-in transient detected → channel ramps up
//  smoothly. Same gesture again to unlink.
//

import Foundation
import Combine

// MARK: - Gesture Detection

/// Detects the staff-only link gesture: 3 quick taps within 4s, then a
/// 4th press held for ≥0.5s. Audience button-mashing (no sustained hold)
/// never triggers.
struct JoltLinkGesture {
    private var tapTimestamps: [Date] = []
    private var holdBeganAt: Date?

    private let requiredTaps: Int = 3
    private let tapWindowSeconds: TimeInterval = 4.0
    private let holdThresholdSeconds: TimeInterval = 0.5
    private let maxTapDuration: TimeInterval = 0.8

    /// Public access for scheduling deferred checks.
    var holdThreshold: TimeInterval { holdThresholdSeconds }

    /// Public access for logging.
    var maxTapDurationPublic: TimeInterval { maxTapDuration }

    /// Count of recent taps still within the window.
    func recentTapCount(at now: Date = Date()) -> Int {
        tapTimestamps.filter { now.timeIntervalSince($0) <= tapWindowSeconds }.count
    }

    /// Duration of the current hold, or 0 if not holding.
    func currentHoldDuration(at now: Date = Date()) -> TimeInterval {
        guard let began = holdBeganAt else { return 0 }
        return now.timeIntervalSince(began)
    }

    /// Record a completed quick press-release cycle.
    mutating func recordTap(at now: Date = Date()) {
        pruneExpiredTaps(at: now)
        tapTimestamps.append(now)
    }

    /// A hold began (button pressed down, not yet released).
    mutating func holdBegan(at now: Date = Date()) {
        pruneExpiredTaps(at: now)
        holdBeganAt = now
    }

    /// The hold ended (button released). If it was short enough, count
    /// it as a tap instead.
    mutating func holdEnded(at now: Date = Date()) {
        if let began = holdBeganAt {
            let duration = now.timeIntervalSince(began)
            if duration < maxTapDuration {
                recordTap(at: now)
            }
        }
        holdBeganAt = nil
    }

    /// Returns true when the gesture is complete: 4 recent taps + hold ≥1s.
    func shouldTrigger(at now: Date = Date()) -> Bool {
        guard let began = holdBeganAt else { return false }
        let holdDuration = now.timeIntervalSince(began)
        guard holdDuration >= holdThresholdSeconds else { return false }
        let recentTaps = tapTimestamps.filter { now.timeIntervalSince($0) <= tapWindowSeconds }
        return recentTaps.count >= requiredTaps
    }

    /// Reset after a successful trigger.
    mutating func reset() {
        tapTimestamps.removeAll()
        holdBeganAt = nil
    }

    /// Whether a hold is currently active (for forwarding to normal jolt).
    var isHolding: Bool { holdBeganAt != nil }

    private mutating func pruneExpiredTaps(at now: Date) {
        let window = tapWindowSeconds
        tapTimestamps.removeAll { now.timeIntervalSince($0) > window }
    }
}

// MARK: - State Machine

enum SoftLinkGlobalState: Equatable {
    case idle
    case listening(since: Date)
    case linked
}

enum SoftLinkChannelState: Equatable {
    case unlinked
    case rampingUp(since: Date)
    case linked
    case rampingDown(since: Date)
}

struct SoftLinkEvent: Identifiable, Equatable {
    let id = UUID()
    let channelIndex: Int
    let action: Action
    let timestamp: Date

    enum Action: Equatable {
        case pairingStarted
        case pairingCancelled
        case pairingTimedOut
        case channelLinked
        case channelUnlinked
    }

    static func == (lhs: SoftLinkEvent, rhs: SoftLinkEvent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Coordinator

@MainActor
final class SoftLinkCoordinator: ObservableObject {
    @Published private(set) var globalState: SoftLinkGlobalState = .idle
    @Published private(set) var channelStates: [SoftLinkChannelState] = []
    @Published private(set) var linkGainLinear: [Float] = []
    @Published private(set) var pendingEvents: [SoftLinkEvent] = []

    private var gesture = JoltLinkGesture()
    private var gestureTriggered = false
    private var noiseFloorBaseline: [Float] = []
    private var lastChannelCount: Int = 0

    // Tuning
    let listeningWindowDuration: TimeInterval = 12.0
    let rampUpDuration: TimeInterval = 2.0
    let rampDownDuration: TimeInterval = 1.5
    let spikeThreshold: Float = 0.08

    // MARK: - Gesture Input

    /// Called when jolt hold state changes (button press/release, Cmd+J).
    func handleJoltHoldChanged(isHeld: Bool, at now: Date = Date()) {
        if isHeld {
            gesture.holdBegan(at: now)
            print("[SoftLink] hold BEGAN (taps so far: \(gesture.recentTapCount(at: now)))")
            scheduleHoldCheck(at: now)
        } else {
            let wasTap = gesture.isHolding && gesture.currentHoldDuration(at: now) < gesture.maxTapDurationPublic
            gesture.holdEnded(at: now)
            if wasTap {
                print("[SoftLink] hold ended → counted as TAP (total taps: \(gesture.recentTapCount(at: now)))")
            } else {
                print("[SoftLink] hold ended (not a tap)")
            }
            if gestureTriggered {
                gestureTriggered = false
            }
        }
    }

    /// Called for momentary jolt pulses (command palette).
    /// Treated as an instantaneous tap.
    func handleJoltPulse(at now: Date = Date()) {
        gesture.recordTap(at: now)
        print("[SoftLink] pulse TAP recorded (total taps: \(gesture.recentTapCount(at: now)))")
    }

    /// Schedules a delayed check so the gesture triggers promptly
    /// without depending on the 10 Hz analysis tick.
    private func scheduleHoldCheck(at holdStart: Date) {
        let delay = gesture.holdThreshold + 0.05
        print("[SoftLink] scheduling hold check in \(String(format: "%.2f", delay))s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self else { return }
            guard self.gesture.isHolding else {
                print("[SoftLink] deferred check: hold already released")
                return
            }
            print("[SoftLink] deferred check: hold still active, checking gesture...")
            self.checkGestureTrigger(at: Date())
        }
    }

    /// Schedules a timeout for the listening window so it fires even
    /// when the 10 Hz tick isn't running (no active session).
    private func scheduleListeningTimeout() {
        let timeout = listeningWindowDuration + 0.2
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
            guard let self else { return }
            guard case .listening(let since) = self.globalState else { return }
            let now = Date()
            if now.timeIntervalSince(since) >= self.listeningWindowDuration {
                self.globalState = self.hasAnyLinkedChannel() ? .linked : .idle
                self.emit(.init(channelIndex: -1, action: .pairingTimedOut, timestamp: now))
                print("[SoftLink] pairing TIMEOUT")
            }
        }
    }

    // MARK: - 10 Hz Tick

    /// Called at 10Hz from the audio analysis cadence.
    /// `rawChannelLevels` bypasses the active mask so unlinked channels are visible.
    func tick(rawChannelLevels: [Float], channelCount: Int, at now: Date = Date()) {
        ensureChannelCount(channelCount)
        checkGestureTrigger(at: now)
        advanceStateMachine(rawChannelLevels: rawChannelLevels, channelCount: channelCount, at: now)
        recomputeGains(channelCount: channelCount, at: now)
    }

    /// Consume and clear pending events (called by video output / audience server).
    func drainEvents() -> [SoftLinkEvent] {
        let events = pendingEvents
        pendingEvents.removeAll()
        return events
    }

    /// Clear pending events after external processing.
    func clearEvents() {
        pendingEvents.removeAll()
    }

    // MARK: - Internals

    private func ensureChannelCount(_ channelCount: Int) {
        guard channelCount != lastChannelCount else { return }
        lastChannelCount = channelCount
        // Preserve existing states for channels that still exist.
        var newStates = Array(repeating: SoftLinkChannelState.unlinked, count: channelCount)
        for i in 0..<min(channelStates.count, channelCount) {
            newStates[i] = channelStates[i]
        }
        // Channel 0 is always linked.
        if channelCount > InputRoutingProfile.primaryChannelIndex {
            newStates[InputRoutingProfile.primaryChannelIndex] = .linked
        }
        channelStates = newStates
        linkGainLinear = Array(repeating: Float(0), count: channelCount)
        if channelCount > InputRoutingProfile.primaryChannelIndex {
            linkGainLinear[InputRoutingProfile.primaryChannelIndex] = 1.0
        }
        // Set gains for already-linked channels.
        for i in 0..<channelCount {
            if case .linked = channelStates[i] {
                linkGainLinear[i] = 1.0
            }
        }
    }

    private func checkGestureTrigger(at now: Date) {
        guard !gestureTriggered, gesture.shouldTrigger(at: now) else {
            if gesture.isHolding {
                print("[SoftLink] checkGestureTrigger: taps=\(gesture.recentTapCount(at: now)), holdDuration=\(String(format: "%.2f", gesture.currentHoldDuration(at: now)))s, triggered=\(gestureTriggered)")
            }
            return
        }
        gestureTriggered = true
        print("[SoftLink] ✓ GESTURE TRIGGERED!")
        triggerGesture(at: now)
    }

    private func triggerGesture(at now: Date) {
        gesture.reset()
        activatePairing(at: now)
    }

    /// Force-activate pairing mode (for keyboard shortcut / direct trigger).
    func activatePairing(at now: Date = Date()) {
        switch globalState {
        case .idle:
            globalState = .listening(since: now)
            noiseFloorBaseline = []
            emit(.init(channelIndex: -1, action: .pairingStarted, timestamp: now))
            scheduleListeningTimeout()
            print("[SoftLink] pairing mode ACTIVE — listening for \(listeningWindowDuration)s")

        case .listening:
            globalState = .idle
            emit(.init(channelIndex: -1, action: .pairingCancelled, timestamp: now))
            print("[SoftLink] pairing CANCELLED")

        case .linked:
            for i in 0..<channelStates.count {
                if case .linked = channelStates[i], i != InputRoutingProfile.primaryChannelIndex {
                    channelStates[i] = .rampingDown(since: now)
                    emit(.init(channelIndex: i, action: .channelUnlinked, timestamp: now))
                }
            }
        }
    }

    private func advanceStateMachine(rawChannelLevels: [Float], channelCount: Int, at now: Date) {
        switch globalState {
        case .idle:
            break

        case .listening(let since):
            // Capture noise floor baseline on first tick of the window.
            if noiseFloorBaseline.isEmpty {
                noiseFloorBaseline = rawChannelLevels
            }

            // Check for timeout.
            if now.timeIntervalSince(since) >= listeningWindowDuration {
                globalState = hasAnyLinkedChannel() ? .linked : .idle
                emit(.init(channelIndex: -1, action: .pairingTimedOut, timestamp: now))
                return
            }

            // Detect spikes on unlinked channels.
            for ch in 0..<channelCount {
                guard ch != InputRoutingProfile.primaryChannelIndex else { continue }
                guard case .unlinked = channelStates[ch] else { continue }
                let baseline = ch < noiseFloorBaseline.count ? noiseFloorBaseline[ch] : 0
                let level = ch < rawChannelLevels.count ? rawChannelLevels[ch] : 0
                if (level - baseline) >= spikeThreshold {
                    channelStates[ch] = .rampingUp(since: now)
                    emit(.init(channelIndex: ch, action: .channelLinked, timestamp: now))
                }
            }

        case .linked:
            // Check if all ramp-downs have completed → transition to idle.
            let anyRampingDown = channelStates.contains { state in
                if case .rampingDown = state { return true }
                return false
            }
            let anyLinkedNonPrimary = channelStates.enumerated().contains { idx, state in
                guard idx != InputRoutingProfile.primaryChannelIndex else { return false }
                switch state {
                case .linked, .rampingUp: return true
                default: return false
                }
            }
            if !anyRampingDown && !anyLinkedNonPrimary {
                globalState = .idle
            }
        }

        // Advance per-channel ramps.
        for ch in 0..<channelStates.count {
            switch channelStates[ch] {
            case .rampingUp(let since):
                if now.timeIntervalSince(since) >= rampUpDuration {
                    channelStates[ch] = .linked
                    if case .listening = globalState {
                        // Stay listening — more channels might link.
                    } else if !hasAnyLinkedChannel() {
                        // Shouldn't happen, but be safe.
                    }
                    // Ensure we're in linked state if listening ended.
                    if case .idle = globalState {
                        globalState = .linked
                    }
                }
            case .rampingDown(let since):
                if now.timeIntervalSince(since) >= rampDownDuration {
                    channelStates[ch] = .unlinked
                }
            default:
                break
            }
        }

        // If listening window ended and we have linked channels, move to .linked.
        if case .listening(let since) = globalState,
           now.timeIntervalSince(since) >= listeningWindowDuration,
           hasAnyLinkedChannel() {
            globalState = .linked
        }

        // If we were in listening and a channel finished ramping up, note we have links.
        if case .listening = globalState, hasAnyLinkedChannel() {
            // Stay in listening until window expires — allow more channels.
        }
    }

    private func recomputeGains(channelCount: Int, at now: Date) {
        guard linkGainLinear.count == channelCount else { return }
        for ch in 0..<channelCount {
            if ch == InputRoutingProfile.primaryChannelIndex {
                linkGainLinear[ch] = 1.0
                continue
            }
            switch channelStates[ch] {
            case .unlinked:
                linkGainLinear[ch] = 0
            case .rampingUp(let since):
                linkGainLinear[ch] = Self.raisedCosineRamp(
                    elapsed: now.timeIntervalSince(since),
                    duration: rampUpDuration
                )
            case .linked:
                linkGainLinear[ch] = 1.0
            case .rampingDown(let since):
                linkGainLinear[ch] = 1.0 - Self.raisedCosineRamp(
                    elapsed: now.timeIntervalSince(since),
                    duration: rampDownDuration
                )
            }
        }
    }

    private func hasAnyLinkedChannel() -> Bool {
        channelStates.enumerated().contains { idx, state in
            guard idx != InputRoutingProfile.primaryChannelIndex else { return false }
            switch state {
            case .linked, .rampingUp: return true
            default: return false
            }
        }
    }

    private func emit(_ event: SoftLinkEvent) {
        pendingEvents.append(event)
    }

    // MARK: - Ramp Curve

    /// Raised-cosine ramp: (1 - cos(π * t/d)) / 2.
    /// Zero-slope at both endpoints → no clicks.
    nonisolated static func raisedCosineRamp(elapsed: TimeInterval, duration: TimeInterval) -> Float {
        let t = max(0, min(1, elapsed / max(0.001, duration)))
        return Float((1.0 - cos(.pi * t)) / 2.0)
    }
}

// Free function for use in non-MainActor contexts (audio paths).
func softLinkRaisedCosineRamp(elapsed: TimeInterval, duration: TimeInterval) -> Float {
    SoftLinkCoordinator.raisedCosineRamp(elapsed: elapsed, duration: duration)
}

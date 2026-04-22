import Foundation
import Combine

enum SirenSongStatus: String, Equatable {
    case bypass = "Bypass"
    case armed = "Armed"
    case attract = "Attract"
    case enterFade = "Enter Fade"
}

@MainActor
final class SirenSongCoordinator: ObservableObject {
    struct Config {
        var requiredPedestalAddresses: [Int] = [1, 2, 3]
        var freshnessWindowSeconds: TimeInterval = 1.2
        var buttonReleasePresenceSeconds: TimeInterval = 6.0
        var emptyHoldSeconds: TimeInterval = 12.0
        var sirenStartFadeSeconds: TimeInterval = 1.2
        var sirenStopFadeSeconds: TimeInterval = 0.12
        var inputMuteFadeSeconds: TimeInterval = 0.35
        var inputFadeInSeconds: TimeInterval = 8.0
        var bypassInputRestoreSeconds: TimeInterval = 0.15
    }

    enum AudioCommand: Equatable {
        case setSirenActive(active: Bool, fadeSeconds: TimeInterval)
        case setExternalInputGain(target: Double, rampSeconds: TimeInterval)
    }

    @Published private(set) var status: SirenSongStatus = .bypass

    var onAudioCommand: ((AudioCommand) -> Void)?
    var onEvent: ((String) -> Void)?

    private var config = Config()
    private var runIsLive: Bool = false
    private var replayIsRunning: Bool = false
    private var bridgeConnected: Bool = false
    private var playlistReady: Bool = false
    private var pedestals: [Int: PedestalTelemetry] = [:]

    private var emptySince: Date?
    private var enterFadeUntil: Date?
    private var suppressedInitialPressedButtons: [Int: Bool] = [:]
    private var lastButtonState: [Int: Bool] = [:]
    private var releasePresenceUntil: [Int: Date] = [:]

    func updateConfig(_ mutate: (inout Config) -> Void) {
        mutate(&config)
    }

    func updateInputs(
        isBridgeConnected: Bool,
        pedestals: [Int: PedestalTelemetry],
        isLiveRun: Bool,
        isReplayRunning: Bool,
        playlistReady: Bool,
        now: Date = Date()
    ) {
        bridgeConnected = isBridgeConnected
        self.pedestals = pedestals
        runIsLive = isLiveRun
        replayIsRunning = isReplayRunning
        self.playlistReady = playlistReady
        evaluate(now: now)
    }

    private enum TransitionReason {
        case runScopeDisabled
        case bridgeUnavailable
        case playlistUnavailable
        case staleTelemetry
        case armed
        case emptyHoldSatisfied
        case occupancyDetected
        case enterFadeComplete
    }

    private func evaluate(now: Date) {
        let inRunScope = runIsLive && !replayIsRunning
        guard inRunScope else {
            emptySince = nil
            enterFadeUntil = nil
            resetPresenceState()
            transition(to: .bypass, reason: .runScopeDisabled)
            return
        }
        guard bridgeConnected else {
            emptySince = nil
            enterFadeUntil = nil
            resetPresenceState()
            transition(to: .bypass, reason: .bridgeUnavailable)
            return
        }
        guard playlistReady else {
            emptySince = nil
            enterFadeUntil = nil
            resetPresenceState()
            transition(to: .bypass, reason: .playlistUnavailable)
            return
        }

        let occupancy = freshOccupancy(now: now)
        let required = Set(config.requiredPedestalAddresses)
        let allFresh = required.allSatisfy { occupancy[$0] != nil }
        let anyOccupiedFresh = occupancy.contains { _, occupied in occupied }

        switch status {
        case .attract:
            if anyOccupiedFresh {
                emptySince = nil
                enterFadeUntil = now.addingTimeInterval(config.inputFadeInSeconds)
                transition(to: .enterFade, reason: .occupancyDetected)
                return
            }
            guard allFresh else {
                emptySince = nil
                enterFadeUntil = nil
                transition(to: .bypass, reason: .staleTelemetry)
                return
            }

        case .enterFade:
            if anyOccupiedFresh {
                enterFadeUntil = now.addingTimeInterval(config.inputFadeInSeconds)
                return
            }
            guard allFresh else {
                emptySince = nil
                enterFadeUntil = nil
                transition(to: .bypass, reason: .staleTelemetry)
                return
            }
            if let enterFadeUntil, now >= enterFadeUntil {
                transition(to: .armed, reason: .enterFadeComplete)
                self.enterFadeUntil = nil
            }

        case .armed, .bypass:
            guard allFresh else {
                emptySince = nil
                enterFadeUntil = nil
                transition(to: .bypass, reason: .staleTelemetry)
                return
            }
            if anyOccupiedFresh {
                emptySince = nil
                transition(to: .armed, reason: .armed)
                return
            }
            if emptySince == nil {
                emptySince = now
                transition(to: .armed, reason: .armed)
                return
            }
            guard let emptySince else { return }
            if now.timeIntervalSince(emptySince) >= config.emptyHoldSeconds {
                transition(to: .attract, reason: .emptyHoldSatisfied)
            } else {
                transition(to: .armed, reason: .armed)
            }
        }
    }

    private func freshOccupancy(now: Date) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for address in config.requiredPedestalAddresses {
            guard let telemetry = pedestals[address] else { continue }
            guard telemetry.online else { continue }
            let age = now.timeIntervalSince(telemetry.lastUpdate)
            guard age >= 0, age <= config.freshnessWindowSeconds else { continue }

            let isPressed = telemetry.button
            let previous = lastButtonState[address]
            let wasSuppressed = suppressedInitialPressedButtons[address] ?? false

            if previous == nil {
                // If a button is already held at startup (e.g., weighted "shut off ON"), treat it as baseline, not occupancy.
                suppressedInitialPressedButtons[address] = isPressed
            } else if previous == true, isPressed == false, wasSuppressed {
                // Releasing that baseline-held button implies a person is present now.
                suppressedInitialPressedButtons[address] = false
                releasePresenceUntil[address] = now.addingTimeInterval(config.buttonReleasePresenceSeconds)
            }

            let suppressed = suppressedInitialPressedButtons[address] ?? false
            let releaseLatchActive: Bool = {
                guard let until = releasePresenceUntil[address] else { return false }
                if until > now { return true }
                releasePresenceUntil[address] = nil
                return false
            }()

            let occupied = (!suppressed && isPressed) || releaseLatchActive
            out[address] = occupied
            lastButtonState[address] = isPressed
        }
        return out
    }

    private func resetPresenceState() {
        suppressedInitialPressedButtons.removeAll(keepingCapacity: false)
        lastButtonState.removeAll(keepingCapacity: false)
        releasePresenceUntil.removeAll(keepingCapacity: false)
    }

    private func transition(to next: SirenSongStatus, reason: TransitionReason) {
        guard status != next else { return }
        status = next

        switch next {
        case .bypass:
            onAudioCommand?(.setSirenActive(active: false, fadeSeconds: config.sirenStopFadeSeconds))
            onAudioCommand?(.setExternalInputGain(target: 1.0, rampSeconds: config.bypassInputRestoreSeconds))
            if reason == .staleTelemetry {
                onEvent?("Siren bypass: pedestal bridge health stale.")
            } else if reason == .bridgeUnavailable {
                onEvent?("Siren bypass: bridge unavailable.")
            } else if reason == .playlistUnavailable {
                onEvent?("Siren bypass: playlist unavailable.")
            }

        case .armed:
            onAudioCommand?(.setSirenActive(active: false, fadeSeconds: config.sirenStopFadeSeconds))
            if reason != .enterFadeComplete {
                onAudioCommand?(.setExternalInputGain(target: 1.0, rampSeconds: 0.2))
            }
            if reason == .armed {
                onEvent?("Siren armed: all pedestals healthy.")
            }

        case .attract:
            onAudioCommand?(.setExternalInputGain(target: 0.0, rampSeconds: config.inputMuteFadeSeconds))
            onAudioCommand?(.setSirenActive(active: true, fadeSeconds: config.sirenStartFadeSeconds))
            onEvent?("Siren attract started: room empty hold met.")

        case .enterFade:
            onAudioCommand?(.setSirenActive(active: false, fadeSeconds: config.sirenStopFadeSeconds))
            onAudioCommand?(.setExternalInputGain(target: 1.0, rampSeconds: config.inputFadeInSeconds))
            onEvent?("Siren stopped: occupant detected.")
        }
    }
}

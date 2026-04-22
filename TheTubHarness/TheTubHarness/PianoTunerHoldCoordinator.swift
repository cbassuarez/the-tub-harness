import Foundation

enum PianoTunerHoldState: Equatable {
    case idle
    case counting(startedAt: Date)
    case active(activatedAt: Date)

    var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }
}

struct PianoTunerHoldTransition: Equatable {
    let previousState: PianoTunerHoldState
    let state: PianoTunerHoldState

    var didActivate: Bool {
        !previousState.isActive && state.isActive
    }

    var didDeactivate: Bool {
        previousState.isActive && !state.isActive
    }

    var shouldSuppressJolt: Bool {
        state.isActive
    }
}

struct PianoTunerHoldCoordinator {
    struct Configuration: Equatable {
        var activationHoldSeconds: TimeInterval = 45.0
    }

    private(set) var state: PianoTunerHoldState = .idle
    var configuration: Configuration = .init()

    mutating func update(eligibleHoldActive: Bool, inRunScope: Bool, now: Date) -> PianoTunerHoldTransition {
        let previous = state

        if !inRunScope {
            state = .idle
            return PianoTunerHoldTransition(previousState: previous, state: state)
        }

        switch state {
        case .idle:
            if eligibleHoldActive {
                state = .counting(startedAt: now)
            }

        case let .counting(startedAt):
            if !eligibleHoldActive {
                state = .idle
            } else {
                let elapsed = max(0, now.timeIntervalSince(startedAt))
                if elapsed >= configuration.activationHoldSeconds {
                    state = .active(activatedAt: now)
                }
            }

        case .active:
            if !eligibleHoldActive {
                state = .idle
            }
        }

        return PianoTunerHoldTransition(previousState: previous, state: state)
    }

    mutating func reset() -> PianoTunerHoldTransition {
        let previous = state
        state = .idle
        return PianoTunerHoldTransition(previousState: previous, state: state)
    }
}

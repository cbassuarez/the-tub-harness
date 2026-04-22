import Foundation
import Testing
@testable import TheTubHarness

struct PianoTunerHoldCoordinatorTests {
    @Test("Piano tuner activates only after 45 seconds of continuous eligible hold")
    func activatesAfterContinuousHold() {
        var coordinator = PianoTunerHoldCoordinator()
        let t0 = Date(timeIntervalSince1970: 10_000)

        var transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0
        )
        #expect(!transition.didActivate)
        #expect(!transition.shouldSuppressJolt)

        transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0.addingTimeInterval(44.9)
        )
        #expect(!transition.didActivate)
        #expect(!transition.shouldSuppressJolt)

        transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0.addingTimeInterval(45.0)
        )
        #expect(transition.didActivate)
        #expect(transition.shouldSuppressJolt)
    }

    @Test("SoftLink-only hold never activates piano tuner")
    func softLinkOnlyNeverActivates() {
        var coordinator = PianoTunerHoldCoordinator()
        let t0 = Date(timeIntervalSince1970: 20_000)

        _ = coordinator.update(
            eligibleHoldActive: false,
            inRunScope: true,
            now: t0
        )
        let transition = coordinator.update(
            eligibleHoldActive: false,
            inRunScope: true,
            now: t0.addingTimeInterval(90.0)
        )
        #expect(!transition.shouldSuppressJolt)
        #expect(!transition.didActivate)
    }

    @Test("Piano tuner resets on release and rearms correctly")
    func releaseResetsAndRearms() {
        var coordinator = PianoTunerHoldCoordinator()
        let t0 = Date(timeIntervalSince1970: 30_000)

        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0)
        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0.addingTimeInterval(45.2))

        var transition = coordinator.update(
            eligibleHoldActive: false,
            inRunScope: true,
            now: t0.addingTimeInterval(45.3)
        )
        #expect(transition.didDeactivate)
        #expect(!transition.shouldSuppressJolt)

        _ = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0.addingTimeInterval(46.0)
        )
        transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0.addingTimeInterval(91.2)
        )
        #expect(transition.didActivate)
        #expect(transition.shouldSuppressJolt)
    }

    @Test("Replay and idle scopes never engage piano tuner and force deactivation")
    func liveRunScopeOnly() {
        var coordinator = PianoTunerHoldCoordinator()
        let t0 = Date(timeIntervalSince1970: 40_000)

        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0)
        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0.addingTimeInterval(45.0))

        var transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: false,
            now: t0.addingTimeInterval(45.1)
        )
        #expect(transition.didDeactivate)
        #expect(!transition.shouldSuppressJolt)

        transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: false,
            now: t0.addingTimeInterval(120.0)
        )
        #expect(!transition.didActivate)
        #expect(!transition.shouldSuppressJolt)
    }

    @Test("Active piano tuner is release-only while run scope stays live")
    func activeStateIsReleaseOnlyInLiveScope() {
        var coordinator = PianoTunerHoldCoordinator()
        let t0 = Date(timeIntervalSince1970: 50_000)

        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0)
        _ = coordinator.update(eligibleHoldActive: true, inRunScope: true, now: t0.addingTimeInterval(45.0))

        let transition = coordinator.update(
            eligibleHoldActive: true,
            inRunScope: true,
            now: t0.addingTimeInterval(120.0)
        )
        #expect(!transition.didDeactivate)
        #expect(transition.shouldSuppressJolt)
    }
}

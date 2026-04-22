import Foundation
import Testing
@testable import TheTubHarness

@MainActor
struct SirenSongCoordinatorTests {
    private func makePedestals(
        now: Date,
        occupied: Set<Int> = [],
        stale: Set<Int> = [],
        missing: Set<Int> = []
    ) -> [Int: PedestalTelemetry] {
        var out: [Int: PedestalTelemetry] = [:]
        for address in [1, 2, 3] {
            if missing.contains(address) { continue }
            out[address] = PedestalTelemetry(
                address: address,
                button: occupied.contains(address),
                tofMm: occupied.contains(address) ? 70 : 280,
                haloPwm: 0,
                online: true,
                lastUpdate: stale.contains(address) ? now.addingTimeInterval(-3.0) : now
            )
        }
        return out
    }

    @Test("Siren does not arm/start until all three pedestals are fresh")
    func sirenRequiresAllFreshPedestals() {
        let coordinator = SirenSongCoordinator()
        coordinator.updateConfig { cfg in
            cfg.emptyHoldSeconds = 2.0
        }

        let t0 = Date(timeIntervalSince1970: 1_000)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0, missing: [3]),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0
        )
        #expect(coordinator.status == .bypass)

        let t1 = t0.addingTimeInterval(1.0)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t1, stale: [3]),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t1
        )
        #expect(coordinator.status == .bypass)

        let t2 = t0.addingTimeInterval(2.0)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t2),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t2
        )
        #expect(coordinator.status == .armed)

        let t3 = t0.addingTimeInterval(4.2)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t3),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t3
        )
        #expect(coordinator.status == .attract)
    }

    @Test("Siren starts only after 12s empty hold")
    func sirenStartsAfterEmptyHold() {
        let coordinator = SirenSongCoordinator()
        let t0 = Date(timeIntervalSince1970: 2_000)

        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0
        )
        #expect(coordinator.status == .armed)

        let t1 = t0.addingTimeInterval(11.8)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t1),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t1
        )
        #expect(coordinator.status == .armed)

        let t2 = t0.addingTimeInterval(12.1)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t2),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t2
        )
        #expect(coordinator.status == .attract)
    }

    @Test("Any one fresh occupied pedestal exits attract with 120ms out and 8s input ramp")
    func sirenOccupancyStopUsesEnterFadeIntents() {
        let coordinator = SirenSongCoordinator()
        coordinator.updateConfig { cfg in
            cfg.emptyHoldSeconds = 0.0
        }
        var commands: [SirenSongCoordinator.AudioCommand] = []
        coordinator.onAudioCommand = { command in
            commands.append(command)
        }

        let t0 = Date(timeIntervalSince1970: 3_000)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0
        )
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0.addingTimeInterval(0.1)),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0.addingTimeInterval(0.1)
        )
        #expect(coordinator.status == .attract)

        // While attract is active, one fresh occupied pedestal is enough to stop.
        let t1 = t0.addingTimeInterval(0.2)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t1, occupied: [2], stale: [1, 3]),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t1
        )
        #expect(coordinator.status == .enterFade)

        let hasSirenCut = commands.contains { command in
            if case let .setSirenActive(active, fadeSeconds) = command {
                return active == false && abs(fadeSeconds - 0.12) < 0.000_1
            }
            return false
        }
        let hasInputFadeIn = commands.contains { command in
            if case let .setExternalInputGain(target, rampSeconds) = command {
                return abs(target - 1.0) < 0.000_1 && abs(rampSeconds - 8.0) < 0.000_1
            }
            return false
        }
        #expect(hasSirenCut)
        #expect(hasInputFadeIn)
    }

    @Test("Siren bypasses on stale bridge health while active and restores live input")
    func sirenBypassesOnStaleHealth() {
        let coordinator = SirenSongCoordinator()
        coordinator.updateConfig { cfg in
            cfg.emptyHoldSeconds = 0.0
        }
        var commands: [SirenSongCoordinator.AudioCommand] = []
        coordinator.onAudioCommand = { command in
            commands.append(command)
        }

        let t0 = Date(timeIntervalSince1970: 4_000)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0
        )
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: t0.addingTimeInterval(0.1)),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: t0.addingTimeInterval(0.1)
        )
        #expect(coordinator.status == .attract)

        let staleNow = t0.addingTimeInterval(2.0)
        coordinator.updateInputs(
            isBridgeConnected: true,
            pedestals: makePedestals(now: staleNow, stale: [1, 2, 3]),
            isLiveRun: true,
            isReplayRunning: false,
            playlistReady: true,
            now: staleNow
        )
        #expect(coordinator.status == .bypass)

        let hasBypassSirenStop = commands.contains { command in
            if case let .setSirenActive(active, fadeSeconds) = command {
                return active == false && abs(fadeSeconds - 0.12) < 0.000_1
            }
            return false
        }
        let hasBypassInputRestore = commands.contains { command in
            if case let .setExternalInputGain(target, rampSeconds) = command {
                return abs(target - 1.0) < 0.000_1 && abs(rampSeconds - 0.15) < 0.000_1
            }
            return false
        }
        #expect(hasBypassSirenStop)
        #expect(hasBypassInputRestore)
    }
}

@MainActor
struct SirenSongAudioEngineTests {
    @Test("External live-input gain ramp clamps to [0,1] and moves smoothly")
    func externalGainRampClampsAndInterpolates() {
        let audio = AudioEngineController()

        audio.setExternalLiveInputGain(target: -1.0, rampSeconds: 0.0)
        var snapshot = audio.externalInputGainSnapshotForTesting()
        #expect(abs(snapshot.current - 0.0) < 0.000_1)
        #expect(abs(snapshot.target - 0.0) < 0.000_1)

        audio.setExternalLiveInputGain(target: 2.0, rampSeconds: 1.0)
        snapshot = audio.externalInputGainSnapshotForTesting()
        #expect(abs(snapshot.target - 1.0) < 0.000_1)

        audio.advanceRenderAutomationForTesting(frames: 24_000)
        snapshot = audio.externalInputGainSnapshotForTesting()
        #expect(snapshot.current > 0.45 && snapshot.current < 0.55)

        audio.advanceRenderAutomationForTesting(frames: 30_000)
        snapshot = audio.externalInputGainSnapshotForTesting()
        #expect(abs(snapshot.current - 1.0) < 0.001)
    }

    @Test("Siren playback fade commands are idempotent and safe during rapid toggles")
    func sirenPlaybackRapidToggleIsSafe() {
        let audio = AudioEngineController()
        let clip = SirenTrackClip(
            id: "test",
            sampleRate: 48_000,
            samples: [0.0, 0.6, 0.1, -0.4, 0.2, -0.1, 0.0]
        )
        audio.loadSirenSongPlaylistForTesting([clip])
        #expect(audio.sirenPlaylistReady)

        audio.setSirenSongActive(true, fadeSeconds: 0.2)
        audio.setSirenSongActive(true, fadeSeconds: 0.2)
        audio.advanceRenderAutomationForTesting(frames: 9_600)

        var playback = audio.sirenPlaybackSnapshotForTesting()
        #expect(playback.trackCount == 1)
        #expect(playback.activeTarget)
        #expect(playback.gainCurrent > 0.0)
        #expect(playback.gainCurrent <= 0.5)

        audio.setSirenSongActive(false, fadeSeconds: 0.12)
        audio.setSirenSongActive(false, fadeSeconds: 0.12)
        audio.advanceRenderAutomationForTesting(frames: 6_000)
        playback = audio.sirenPlaybackSnapshotForTesting()
        #expect(!playback.activeTarget)
        #expect(playback.gainCurrent < 0.01)

        audio.setSirenSongActive(true, fadeSeconds: 0.1)
        audio.advanceRenderAutomationForTesting(frames: 5_000)
        playback = audio.sirenPlaybackSnapshotForTesting()
        #expect(playback.activeTarget)
        #expect(playback.gainCurrent > 0.0)
        #expect(playback.gainCurrent <= 0.5)
    }

    @Test("Piano tuner duck ramps down to 2% and restores to full on release")
    func pianoTunerDuckRampDownAndUp() {
        let audio = AudioEngineController()

        audio.setPianoTunerDuckActive(true, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        var duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(duck.activeTarget)
        #expect(abs(duck.target - 0.02) < 0.000_1)

        audio.advanceRenderAutomationForTesting(frames: 19_200)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(duck.current < 0.60 && duck.current > 0.40)

        audio.advanceRenderAutomationForTesting(frames: 24_000)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(abs(duck.current - 0.02) < 0.002)

        audio.setPianoTunerDuckActive(false, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(!duck.activeTarget)
        #expect(abs(duck.target - 1.0) < 0.000_1)

        audio.advanceRenderAutomationForTesting(frames: 6_000)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(duck.current < 0.65 && duck.current > 0.35)

        audio.advanceRenderAutomationForTesting(frames: 8_000)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(abs(duck.current - 1.0) < 0.002)
    }

    @Test("Piano tuner duck enter and exit commands stay stable under repeated calls")
    func pianoTunerDuckCommandsAreIdempotent() {
        let audio = AudioEngineController()

        audio.setPianoTunerDuckActive(true, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        audio.setPianoTunerDuckActive(true, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        audio.advanceRenderAutomationForTesting(frames: 40_000)
        var duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(duck.activeTarget)
        #expect(abs(duck.current - 0.02) < 0.002)

        audio.setPianoTunerDuckActive(false, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        audio.setPianoTunerDuckActive(false, duckGain: 0.02, fadeDownSeconds: 0.8, fadeUpSeconds: 0.25)
        audio.advanceRenderAutomationForTesting(frames: 14_000)
        duck = audio.pianoTunerDuckSnapshotForTesting()
        #expect(!duck.activeTarget)
        #expect(abs(duck.current - 1.0) < 0.002)
    }

    @Test("Empty Siren playlist keeps attract playback disabled")
    func sirenEmptyPlaylistStaysDisabled() {
        let audio = AudioEngineController()
        audio.loadSirenSongPlaylistForTesting([])
        #expect(!audio.sirenPlaylistReady)

        audio.setSirenSongActive(true, fadeSeconds: 0.0)
        let playback = audio.sirenPlaybackSnapshotForTesting()
        #expect(playback.trackCount == 0)
        #expect(!playback.activeTarget)
        #expect(abs(playback.gainTarget - 0.0) < 0.000_1)
        #expect(abs(playback.gainCurrent - 0.0) < 0.000_1)
    }
}

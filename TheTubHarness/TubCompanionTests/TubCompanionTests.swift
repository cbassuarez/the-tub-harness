//
//  TubCompanionTests.swift
//  TubCompanionTests
//
//  Created by Sebastian Suarez-Solis on 3/31/26.
//

import Foundation
import Testing
@testable import TubCompanion

@MainActor
struct TubCompanionTests {

    @Test
    func playSampleClassBoundaryAtFourSeconds() {
        #expect(PlaySampleClass.classify(duration: 3.99) == .short)
        #expect(PlaySampleClass.classify(duration: 4.0) == .long)
    }

    @Test
    func longBankLayoutDeterministicEightBanksWithOptionalCenter() {
        let entries: [PlayLongSampleEntry] = (0..<24).map { index in
            PlayLongSampleEntry(
                url: URL(fileURLWithPath: "/tmp/sample_\(index).wav"),
                duration: 5 + Double(index) * 0.1,
                displayToken: String(format: "L%02d", index),
                displayName: "sample_\(index)"
            )
        }

        let banks = PlayLongBankLayout.makeBanks(entries: entries)
        #expect(banks.count == 8)
        #expect(banks[0].left?.displayName == "sample_0")
        #expect(banks[0].right?.displayName == "sample_1")
        #expect(banks[0].center == nil)
        #expect(banks[4].center?.displayName == "sample_16")
        #expect(banks[7].center?.displayName == "sample_19")
    }

    @Test
    func playGridTokenAlphabetMatchesTubPattern() {
        #expect(PlayGridTokenAlphabet.token(cellSerial: 0, bankIndex: 0, gridDimension: 6) == "00")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 9, bankIndex: 0, gridDimension: 6) == "09")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 10, bankIndex: 0, gridDimension: 6) == "0A")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 17, bankIndex: 0, gridDimension: 6) == "0H")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 18, bankIndex: 0, gridDimension: 6) == "10")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 35, bankIndex: 0, gridDimension: 6) == "1H")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 0, bankIndex: 1, gridDimension: 6) == "20")
        #expect(PlayGridTokenAlphabet.token(cellSerial: 35, bankIndex: 1, gridDimension: 6) == "3H")
    }

    @Test
    func captureStateTransitionsPressRelease() async {
        let (_, _, _, engine, viewModel) = makeRig()

        if let firstPad = engine.pads.first {
            viewModel.armPad(firstPad.id)
        }

        viewModel.startCaptureHold()
        await wait(0.08)
        #expect(viewModel.captureState == .recording)

        viewModel.endCaptureHold()
        #expect(viewModel.captureState == .committing)

        let reachedPlaying = await waitUntil(timeout: 1.2) {
            viewModel.captureState == .playing
        }
        #expect(reachedPlaying)
        #expect(viewModel.queuedContributions.count == 1)
    }

    @Test
    func captureAutoStopsAtLimit() async {
        let (_, _, _, engine, viewModel) = makeRig(captureLimit: 0.2)

        if let firstPad = engine.pads.first {
            viewModel.armPad(firstPad.id)
        }

        viewModel.startCaptureHold()
        let reachedPlaying = await waitUntil(timeout: 1.2) {
            viewModel.captureState == .playing
        }

        #expect(reachedPlaying)
        #expect(viewModel.queuedContributions.count == 1)
    }

    @Test
    func quantizeModeSyncsToEngine() async {
        let (_, _, _, engine, viewModel) = makeRig()

        viewModel.setQuantizeMode(.bar)
        let barSynced = await waitUntil(timeout: 1.2) {
            engine.quantizeMode == .bar
        }
        #expect(viewModel.quantizeMode == .bar)
        #expect(barSynced)

        viewModel.setQuantizeMode(.free)
        let freeSynced = await waitUntil(timeout: 1.2) {
            engine.quantizeMode == .free
        }
        #expect(viewModel.quantizeMode == .free)
        #expect(freeSynced)
    }

    @Test
    func synthVoiceCapAndLifecycleUnderRapidTaps() async {
        let (_, _, _, engine, _) = makeRig()
        engine.setQuantizeMode(.free)

        (48...56).forEach { note in
            engine.triggerSynth(note: note, isOn: true)
        }

        let reachedCap = await waitUntil(timeout: 0.8) {
            engine.activeSynthVoiceCount == 6
        }
        #expect(reachedCap)
        #expect(engine.activeSynthNotes.count == 6)

        (48...56).forEach { note in
            engine.triggerSynth(note: note, isOn: false)
        }

        let voicesReleased = await waitUntil(timeout: 0.8) {
            engine.activeSynthVoiceCount == 0
        }
        #expect(voicesReleased)
        #expect(engine.activeSynthNotes.isEmpty)
    }

    @Test
    func synthGestureMappingIsDeterministic() async {
        let (_, _, _, engine, _) = makeRig()
        engine.setSynthScene(.drift)
        engine.updateSynthGesture(.init(note: 52, x: 0.78, y: 0.22, pressure: 0.65))

        let settled = await waitUntil(timeout: 0.5) {
            engine.synthGesture == SynthGesture(note: 52, x: 0.78, y: 0.22, pressure: 0.65)
        }
        #expect(settled)

        let snapshot = engine.synthMacroSnapshotForTesting()
        #expect(snapshot.scene == .drift)
        #expect(snapshot.gesture == SynthGesture(note: 52, x: 0.78, y: 0.22, pressure: 0.65))
        #expect(snapshot.enabled)
    }

    @Test
    func synthFreeVsQuantizedTimingBehavior() async {
        let (_, _, _, engine, _) = makeRig()
        engine.setTimelineAnchorForTesting(Date())
        engine.setQuantizeMode(.free)

        engine.triggerSynth(note: 60, isOn: true)
        let freeStarted = await waitUntil(timeout: 0.4) {
            engine.activeSynthNotes.contains(60)
        }
        #expect(freeStarted)
        engine.triggerSynth(note: 60, isOn: false)

        let tickBaseline = engine.synthQuantizeTickCounter
        engine.setTimelineAnchorForTesting(Date().addingTimeInterval(-0.35))
        engine.setQuantizeMode(.bar)
        engine.triggerSynth(note: 61, isOn: true)

        await wait(0.08)
        #expect(!engine.activeSynthNotes.contains(61))

        let quantizedStarted = await waitUntil(timeout: 4.5) {
            engine.activeSynthNotes.contains(61)
        }
        #expect(quantizedStarted)
        #expect(engine.synthQuantizeTickCounter > tickBaseline)
    }

    @Test
    func independentPadHeadProgressUpdates() async {
        let (_, _, _, engine, _) = makeRig()
        guard engine.pads.count >= 2 else {
            Issue.record("Expected at least 2 pads.")
            return
        }

        var first = engine.pads[0]
        first.playbackState = .playing
        first.duration = 4
        first.headAnchorDate = Date().addingTimeInterval(-1.0)
        first.waveformPeaks = Array(repeating: 0.6, count: 32)

        var second = engine.pads[1]
        second.playbackState = .playing
        second.duration = 5
        second.headAnchorDate = Date().addingTimeInterval(-2.0)
        second.waveformPeaks = Array(repeating: 0.4, count: 32)

        engine.pads[0] = first
        engine.pads[1] = second
        engine.refreshPadMetricsForTesting()

        let firstProgress = engine.padHeadProgress[first.id]
        let secondProgress = engine.padHeadProgress[second.id]

        #expect(firstProgress != nil)
        #expect(secondProgress != nil)
        #expect(firstProgress != secondProgress)
    }

    @Test
    func cableGuardrailBlocksCapture() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        appState.syncExternalAudioRoute(isActive: false, description: "No external route")

        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let engine = LooperEngine()
        let viewModel = PlayIntoTubViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor,
            looperEngine: engine,
            debugAllowCableBypassOverride: false
        )

        viewModel.startCaptureHold()
        let blockedByGuardrail: Bool
        if case .error = viewModel.captureState {
            blockedByGuardrail = true
        } else {
            blockedByGuardrail = false
        }
        #expect(blockedByGuardrail, "Expected an error state when cable is missing.")
    }

    @Test
    func clearAndUndoPadRestoresSnapshot() async {
        let (_, _, _, engine, _) = makeRig()
        guard let firstId = engine.pads.first?.id else {
            Issue.record("Expected at least one pad.")
            return
        }

        engine.pads[0].playbackState = .playing
        engine.pads[0].waveformPeaks = [0.8, 0.6, 0.4]
        engine.pads[0].duration = 4
        engine.pads[0].headAnchorDate = Date().addingTimeInterval(-1.2)

        engine.clearPad(firstId)
        await wait(0.4)
        #expect(engine.pads[0].playbackState == .empty)
        #expect(engine.pads[0].waveformPeaks.isEmpty)

        engine.undoLastClear()
        await wait(0.4)
        #expect(engine.pads[0].playbackState == .playing)
        #expect(!engine.pads[0].waveformPeaks.isEmpty)
    }

    @Test
    func internalMixRecordingMaintainsCaptureFlow() async {
        let (_, _, _, engine, viewModel) = makeRig(captureLimit: 0.45)
        guard let firstPad = engine.pads.first else {
            Issue.record("Expected at least one pad.")
            return
        }

        viewModel.recordSource = .internalMix
        viewModel.armPad(firstPad.id)
        viewModel.synthPadDown(note: 48)
        await wait(0.06)
        viewModel.startCaptureHold()
        await wait(0.12)
        viewModel.synthPadUp(note: 48)
        viewModel.endCaptureHold()

        let reachedPlaying = await waitUntil(timeout: 1.8) {
            viewModel.captureState == .playing
        }
        #expect(reachedPlaying)
        #expect(engine.pads[0].audioBuffer != nil)
    }

    @Test
    func hapticEventsDispatchForNoteAndQuantizeTick() async {
        let haptics = RecordingHapticsClient()
        let (_, _, _, _, viewModel) = makeRig(haptics: haptics)

        let note = viewModel.synthNotes.first ?? 48
        viewModel.synthPadDown(note: note)
        viewModel.synthPadUp(note: note)

        let noteEventDispatched = await waitUntil(timeout: 0.4) {
            haptics.events.contains(.noteOn)
        }
        #expect(noteEventDispatched)

        viewModel.setQuantizeMode(.bar)
        viewModel.synthPadDown(note: note + 1)

        let quantTickDispatched = await waitUntil(timeout: 2.8) {
            haptics.events.contains(.quantizeTick)
        }
        #expect(quantTickDispatched)
    }

    @Test
    func learnRitualProgressionAndBounds() {
        let viewModel = LearnViewModel(harnessClient: HarnessClient())

        #expect(viewModel.mode == .ritual)
        #expect(viewModel.activeChapter == .enter)

        viewModel.back()
        #expect(viewModel.activeChapter == .enter)

        viewModel.next()
        #expect(viewModel.activeChapter == .touch)
        viewModel.next()
        #expect(viewModel.activeChapter == .voice)
        viewModel.next()
        #expect(viewModel.activeChapter == .claim)

        viewModel.next()
        #expect(viewModel.mode == .atlas)
        #expect(viewModel.completedChapters.contains(.claim))
    }

    @Test
    func learnAtlasAnchorRestoreFromContext() {
        let first = LearnViewModel(harnessClient: HarnessClient())
        first.next() // touch
        first.skipToAtlas()

        let anchor = first.atlasSections.last?.id
        if let anchor {
            first.setAtlasAnchor(anchor)
        }

        let context = first.currentContext

        let second = LearnViewModel(harnessClient: HarnessClient())
        second.stageReturnContext(context)
        second.restoreContext()

        #expect(second.mode == .atlas)
        #expect(second.activeChapter == .touch)
        #expect(second.lastAtlasAnchor == anchor)
    }

    @Test
    func learnJumpRoutingStoresContextAndRequestsTab() {
        let appState = TubCompanionAppState()
        appState.initializeSession()

        let viewModel = LearnViewModel(harnessClient: HarnessClient())
        viewModel.next() // touch
        viewModel.jumpToPlay()

        if let jumpTarget = viewModel.pendingJumpTarget {
            appState.storeLearnReturnContext(viewModel.currentContext)
            appState.requestTabNavigation(jumpTarget.appTab)
            viewModel.consumePendingJumpTarget()
        }

        #expect(appState.tabNavigationRequest == .play)
        #expect(appState.learnReturnContext?.mode == .ritual)
        #expect(appState.learnReturnContext?.chapter == .touch)
    }

    @Test
    func learnCopyContractsAreUppercaseAndNonEmpty() {
        let viewModel = LearnViewModel(harnessClient: HarnessClient())

        for spec in viewModel.chapterSpecs.values {
            #expect(spec.title == spec.title.uppercased())
            #expect(!spec.briefLines.isEmpty)
            #expect(spec.briefLines.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }

        for section in viewModel.atlasSections {
            #expect(section.title == section.title.uppercased())
            #expect(!section.body.isEmpty)
            #expect(section.body.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    @Test
    func learnStageFeedTransitionsToDegradedWhenSnapshotStales() async {
        let harnessClient = HarnessClient()
        let viewModel = LearnViewModel(harnessClient: harnessClient)

        harnessClient.connectionState = .connected
        harnessClient.lastStageSnapshot = StageSnapshotPayload(
            mode: 4,
            sceneId: "relay_mesh",
            thought: "listening",
            thoughtLog: ["LISTENING"],
            density: 0.42,
            cohesion: 0.55,
            disruption: 0.31,
            isRunning: true,
            isWaiting: false,
            waitingReason: nil,
            paramLines: ["LEVEL 54"],
            pickLines: ["PRESET ORBIT"],
            changeLines: ["PARAM LEVEL 54"],
            audio: StageAudioSummaryPayload(
                rms: 0.2,
                transientFlux: 0.2,
                lowBand: 0.1,
                midBand: 0.2,
                highBand: 0.3,
                peak: 0.35,
                brightness: 0.41,
                overloadPulse: 0
            ),
            joltHeld: false,
            timestamp: Date()
        )

        let reachedLive = await waitUntil(timeout: 1.0) {
            viewModel.stageFeedState == .live
        }
        #expect(reachedLive)

        let reachedDegraded = await waitUntil(timeout: 3.2) {
            viewModel.stageFeedState == .degraded
        }
        #expect(reachedDegraded)
    }

    @Test
    func learnLegacyVisualFallbackBuildsSyntheticStageSnapshot() async {
        let harnessClient = HarnessClient()
        let viewModel = LearnViewModel(harnessClient: harnessClient)

        harnessClient.connectionState = .connected
        harnessClient.lastVisualOutput = VisualOutput(
            sceneId: "grid_lock",
            density: 0.44,
            cohesion: 0.58,
            disruption: 0.25,
            thought: "routing_signal"
        )

        let resolvedFallback = await waitUntil(timeout: 1.0) {
            viewModel.stageSnapshot == nil &&
            viewModel.effectiveStageSnapshot?.sceneId == "grid_lock" &&
            viewModel.effectiveStageSnapshot?.thought == "routing_signal"
        }
        #expect(resolvedFallback)
        #expect(viewModel.stageFeedState != .standby)
    }

    @Test
    func steerNearestDescriptorMappingIsDeterministic() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let viewModel = SteerViewModel(appState: appState, harnessClient: harnessClient)

        #expect(viewModel.nearestDescriptorID(for: CGPoint(x: 0.50, y: 0.06)) == "dense")
        #expect(viewModel.nearestDescriptorID(for: CGPoint(x: 0.91, y: 0.50)) == "aberrant")
        #expect(viewModel.nearestDescriptorID(for: CGPoint(x: 0.10, y: 0.50)) == "drift")
    }

    @Test
    func steerHoldIntensityBounds() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let viewModel = SteerViewModel(appState: appState, harnessClient: harnessClient)

        #expect(viewModel.normalizedHoldIntensity(0) == 0)
        #expect(viewModel.normalizedHoldIntensity(0.6) > 0.45)
        #expect(viewModel.normalizedHoldIntensity(10) == 1)
    }

    @Test
    func steerCompareModeTransitionsAndChoiceProgression() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let viewModel = SteerViewModel(appState: appState, harnessClient: harnessClient)

        viewModel.enterCompareMode()
        #expect(viewModel.mode == .compare)
        #expect(!viewModel.comparePairs.isEmpty)

        let startIndex = viewModel.compareIndex
        viewModel.chooseCompare(.left)
        #expect(viewModel.compareIndex != startIndex || viewModel.comparePairs.count == 1)

        viewModel.exitCompareMode()
        #expect(viewModel.mode == .steer)
    }

    @Test
    func adaptiveTabRoutingByIntentAndPersistence() {
        let appState = TubCompanionAppState()
        appState.initializeSession()

        appState.chooseEntryIntent(.playLive)
        appState.persistSelectedTab(.learn)
        #expect(appState.initialTabSelection() == .learn)

        appState.chooseEntryIntent(.feedBank)
        #expect(appState.initialTabSelection() == .steer)
    }

    @Test
    func shellLayoutClassifierRespectsBreakpoints() {
        let metrics = ShellLayoutMetrics.default
        #expect(ShellLayoutClass.classify(width: 699, metrics: metrics) == .compact)
        #expect(ShellLayoutClass.classify(width: 700, metrics: metrics) == .regular)
        #expect(ShellLayoutClass.classify(width: 1023, metrics: metrics) == .regular)
        #expect(ShellLayoutClass.classify(width: 1024, metrics: metrics) == .wide)
    }

    @Test
    func shellLayoutPaneVisibilityTransitions() {
        let model = ShellLayoutModel(persistRegularInspectorVisibility: false)

        model.update(for: 680)
        #expect(model.layoutClass == .compact)
        #expect(!model.showsSecondaryPane)

        model.update(for: 900)
        #expect(model.layoutClass == .regular)
        #expect(!model.showsSecondaryPane)

        model.toggleInspectorPane()
        #expect(model.showsSecondaryPane)

        model.update(for: 1180)
        #expect(model.layoutClass == .wide)
        #expect(model.showsSecondaryPane)

        model.update(for: 680)
        #expect(model.layoutClass == .compact)
        #expect(!model.showsSecondaryPane)
    }

    @Test
    func steerAccessGatePrecedence() {
        let appState = TubCompanionAppState(debugBypassSteerLockOverride: false)
        appState.initializeSession()

        appState.syncHarnessState(.disconnected)
        #expect(appState.shouldPresentOverlay(for: .steer))
        #expect(!appState.shouldPresentSteerAccessOverlay)

        appState.syncHarnessState(.connected)
        #expect(!appState.shouldPresentOverlay(for: .steer))
        #expect(appState.shouldPresentSteerAccessOverlay)
    }

    @Test
    func steerChallengeProgressionUnlocks() async {
        let appState = TubCompanionAppState(debugBypassSteerLockOverride: false)
        appState.initializeSession()
        appState.syncHarnessState(.connected)
        appState.beginSteerChallenge()

        guard appState.steerHackRoundSpecs.count >= 3 else {
            Issue.record("Expected at least three steer challenge rounds.")
            return
        }

        #expect(appState.steerAccessState == .inChallenge)
        appState.recordSteerHackInput(didMatch: true, observedToken: "AA")
        #expect(appState.steerHackSession.roundIndex == 1)
        appState.recordSteerHackInput(didMatch: true, observedToken: "BB")
        #expect(appState.steerHackSession.roundIndex == 2)
        appState.recordSteerHackInput(didMatch: true, observedToken: "CC")

        #expect(appState.steerAccessState == .grantedAnimating)
        await wait(1.5)
        #expect(appState.steerAccessState == .unlocked)
    }

    @Test
    func steerChallengeFailureTriggersCooldown() {
        let appState = TubCompanionAppState(debugBypassSteerLockOverride: false)
        appState.initializeSession()
        appState.syncHarnessState(.connected)
        appState.beginSteerChallenge()

        appState.recordSteerHackInput(didMatch: false, observedToken: "AA")
        appState.recordSteerHackInput(didMatch: false, observedToken: "BB")
        appState.recordSteerHackInput(didMatch: false, observedToken: "CC")

        if case .cooldown(let until) = appState.steerAccessState {
            let remaining = until.timeIntervalSinceNow
            #expect(remaining > 4.0)
            #expect(remaining <= 5.2)
            appState.refreshSteerCooldownIfNeeded(now: until.addingTimeInterval(0.1))
            #expect(appState.steerAccessState == .locked)
        } else {
            Issue.record("Expected steer access cooldown state after three misses.")
        }
    }

    @Test
    func steerUnlockDoesNotPersistAcrossFreshState() async {
        let first = TubCompanionAppState(debugBypassSteerLockOverride: false)
        first.initializeSession()
        first.syncHarnessState(.connected)
        first.beginSteerChallenge()
        first.recordSteerHackInput(didMatch: true, observedToken: "AA")
        first.recordSteerHackInput(didMatch: true, observedToken: "BB")
        first.recordSteerHackInput(didMatch: true, observedToken: "CC")
        await wait(1.5)
        #expect(first.steerAccessState == .unlocked)

        let second = TubCompanionAppState(debugBypassSteerLockOverride: false)
        second.initializeSession()
        second.syncHarnessState(.connected)
        #expect(second.steerAccessState == .locked)
        #expect(second.shouldPresentSteerAccessOverlay)
    }

    @Test
    func steerDebugBypassUnlocksImmediately() {
        let appState = TubCompanionAppState(debugBypassSteerLockOverride: true)
        appState.initializeSession()
        appState.syncHarnessState(.connected)

        #expect(appState.steerAccessState == .unlocked)
        #expect(!appState.shouldPresentSteerAccessOverlay)
    }

    @Test
    func descriptorSourcePrefersServerSnapshotWithFallback() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let viewModel = SteerViewModel(appState: appState, harnessClient: harnessClient)

        #expect(viewModel.descriptorSourceLabel == "LOCAL")

        let snapshot = DescriptorSnapshotPayload(
            revision: 3,
            descriptors: [
                AudienceDescriptorState(
                    descriptorId: "void",
                    label: "VOID",
                    priority: 1.0,
                    isVisible: true,
                    systemStateId: nil
                ),
                AudienceDescriptorState(
                    descriptorId: "grain",
                    label: "GRAIN",
                    priority: 0.9,
                    isVisible: true,
                    systemStateId: nil
                )
            ]
        )

        viewModel.applyDescriptorSnapshotForTesting(snapshot)
        #expect(viewModel.descriptorSourceLabel == "SERVER")
        #expect(viewModel.descriptors.map(\.id).contains("void"))

        viewModel.applyDescriptorSnapshotForTesting(nil)
        #expect(viewModel.descriptorSourceLabel == "LOCAL")
        #expect(viewModel.descriptors.count >= 8)
    }

    @Test
    func settingsUnlockChallengeUsesInterruptionRoundFlow() async {
        let viewModel = SettingsPowerUnlockChallengeViewModel()
        viewModel.activate()

        #expect(viewModel.roundsTotal == 4)
        #expect(viewModel.state == .inChallenge)

        viewModel.submitMatchForTesting(true)
        #expect(viewModel.roundDisplay == 2)
        viewModel.submitMatchForTesting(true)
        #expect(viewModel.roundDisplay == 3)
        viewModel.submitMatchForTesting(true)
        #expect(viewModel.roundDisplay == 4)
        #expect(viewModel.interruptionActive)
        viewModel.resolveInterruptionForTesting()
        #expect(!viewModel.interruptionActive)
        #expect(viewModel.roundDisplay == 4)
        viewModel.submitMatchForTesting(true)

        #expect(viewModel.state == .grantedAnimating)
        await wait(1.2)
        #expect(viewModel.state == .unlocked)
    }

    @Test
    func settingsUnlockChallengeRoundTimeoutConsumesOneLife() async {
        let viewModel = SettingsPowerUnlockChallengeViewModel()
        viewModel.activate()

        #expect(viewModel.roundDisplay == 1)
        #expect(viewModel.livesRemaining == 3)

        viewModel.forceRoundTimeoutForTesting()

        #expect(viewModel.state == .inChallenge)
        #expect(viewModel.livesRemaining == 2)

        await wait(0.9)
        #expect(viewModel.state == .inChallenge)
        #expect(viewModel.roundDisplay == 1)
    }

    @Test
    func settingsUnlockChallengeInterruptionTimeoutConsumesOneLife() async {
        let viewModel = SettingsPowerUnlockChallengeViewModel()
        viewModel.activate()
        viewModel.submitMatchForTesting(true)
        viewModel.submitMatchForTesting(true)
        viewModel.submitMatchForTesting(true)

        #expect(viewModel.interruptionActive)
        #expect(viewModel.livesRemaining == 3)

        viewModel.forceInterruptionTimeoutForTesting()

        #expect(viewModel.state == .inChallenge)
        #expect(viewModel.livesRemaining == 2)

        await wait(0.9)
        #expect(viewModel.state == .inChallenge)
        #expect(viewModel.interruptionActive)
    }

    @Test
    func settingsOperatorVectorsExpireToNeutral() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.setVector(param: 0.8, thought: -0.4, audio: 0.6)
        #expect(!viewModel.operatorVector.isNeutral)

        viewModel.applyVectorDecayForTesting(now: Date().addingTimeInterval(3601))
        #expect(viewModel.operatorVector.isNeutral)
        #expect(viewModel.countdownDisplay == "NEUTRAL")
    }

    @Test
    func settingsNeutralNoopDoesNotArmVectorDecay() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.setVector(param: 0.005)

        #expect(viewModel.operatorVector.isNeutral)
        #expect(viewModel.countdownDisplay == "NEUTRAL")
    }

    @Test
    func settingsVectorEditDoesNotResetCountdownToFullTTL() async {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.setVector(param: 0.6)
        await wait(1.2)

        let before = hmsToSeconds(viewModel.countdownDisplay)
        #expect(before < 3600)

        viewModel.setVector(param: 0.7)
        let after = hmsToSeconds(viewModel.countdownDisplay)
        #expect(after <= before + 1)
    }

    @Test
    func settingsBeginPowerUnlockGateRoutesLockedVsUnlocked() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.beginPowerUnlockGate()
        #expect(viewModel.showPowerUnlockGate)
        #expect(!viewModel.showPowerLayerModal)

        viewModel.dismissPowerUnlockGate()
        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.beginPowerUnlockGate()
        #expect(!viewModel.showPowerUnlockGate)
        #expect(viewModel.showPowerLayerModal)
    }

    @Test
    func settingsUnlockSuccessOpensPowerLayerModalImmediately() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.beginPowerUnlockGate()
        #expect(viewModel.showPowerUnlockGate)
        viewModel.handlePowerUnlockSucceeded()
        #expect(!viewModel.showPowerUnlockGate)
        #expect(viewModel.showPowerLayerModal)
        #expect(viewModel.advancedAccessState == .unlocked)
    }

    @Test
    func settingsRemoteOperatorVectorAppliesWhenIdle() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.applyRemoteOperatorVector(
            OperatorVectorLiveState(
                sessionId: "session-remote",
                param: 0.42,
                thought: -0.36,
                audio: 0.2,
                ttlSeconds: 120,
                receivedAt: Date()
            )
        )

        #expect(abs(viewModel.operatorVector.param - 0.42) < 0.001)
        #expect(abs(viewModel.operatorVector.thought + 0.36) < 0.001)
        #expect(abs(viewModel.operatorVector.audio - 0.2) < 0.001)
        #expect(viewModel.lastVectorSourceSessionId == "session-remote")
        #expect(viewModel.countdownDisplay != "NEUTRAL")
    }

    @Test
    func settingsRemoteOperatorVectorQueuesDuringLocalEditAndAppliesOnRelease() {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let viewModel = SettingsViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor
        )

        viewModel.setPowerLayerUnlockedForTesting()
        viewModel.setVector(param: 0.1, thought: 0.1, audio: 0.1)
        let localParam = viewModel.operatorVector.param

        viewModel.beginVectorEdit()
        viewModel.applyRemoteOperatorVector(
            OperatorVectorLiveState(
                sessionId: "session-peer",
                param: -0.7,
                thought: 0.3,
                audio: -0.2,
                ttlSeconds: 90,
                receivedAt: Date()
            )
        )

        #expect(viewModel.pendingRemoteOperatorVector != nil)
        #expect(abs(viewModel.operatorVector.param - localParam) < 0.001)

        viewModel.endVectorEdit()
        #expect(viewModel.pendingRemoteOperatorVector == nil)
        #expect(abs(viewModel.operatorVector.param + 0.7) < 0.001)
        #expect(abs(viewModel.operatorVector.thought - 0.3) < 0.001)
    }

    @Test
    func harnessClientPublishesIncomingOperatorVectorEnvelope() async {
        let harnessClient = HarnessClient()
        harnessClient.injectEnvelopeForTesting(
            AudienceEnvelope(
                kind: .operatorVector,
                sessionId: "session-peer",
                operatorVector: OperatorVectorPayload(
                    paramVector: 0.33,
                    thoughtVector: -0.25,
                    audioVector: 0.15,
                    ttlSeconds: 120
                )
            )
        )

        let published = await waitUntil(timeout: 0.4) {
            harnessClient.lastOperatorVectorState != nil
        }
        #expect(published)
        #expect(harnessClient.lastOperatorVectorState?.sessionId == "session-peer")
        #expect(abs((harnessClient.lastOperatorVectorState?.param ?? 0) - 0.33) < 0.001)
    }

    @Test
    func settingsCommandVectorRailMappingDeterminism() {
        let width: CGFloat = 200
        #expect(abs(CommandVectorRailMath.normalizedValue(for: 0, width: width) + 1) < 0.0001)
        #expect(abs(CommandVectorRailMath.normalizedValue(for: width / 2, width: width) - 0) < 0.0001)
        #expect(abs(CommandVectorRailMath.normalizedValue(for: width, width: width) - 1) < 0.0001)

        #expect(abs(CommandVectorRailMath.xPosition(for: -1, width: width) - 0) < 0.0001)
        #expect(abs(CommandVectorRailMath.xPosition(for: 0, width: width) - (width / 2)) < 0.0001)
        #expect(abs(CommandVectorRailMath.xPosition(for: 1, width: width) - width) < 0.0001)
    }

    private func makeRig(captureLimit: TimeInterval = 10) -> (
        TubCompanionAppState,
        HarnessClient,
        ExternalAudioRouteMonitor,
        LooperEngine,
        PlayIntoTubViewModel
    ) {
        makeRig(captureLimit: captureLimit, haptics: RecordingHapticsClient(disableRecording: true))
    }

    private func makeRig(captureLimit: TimeInterval = 10, haptics: PlayDeckHapticsClient) -> (
        TubCompanionAppState,
        HarnessClient,
        ExternalAudioRouteMonitor,
        LooperEngine,
        PlayIntoTubViewModel
    ) {
        let appState = TubCompanionAppState()
        appState.initializeSession()
        appState.syncExternalAudioRoute(isActive: true, description: "Test Cable")

        let harnessClient = HarnessClient()
        let routeMonitor = ExternalAudioRouteMonitor()
        let engine = LooperEngine()
        let viewModel = PlayIntoTubViewModel(
            appState: appState,
            harnessClient: harnessClient,
            externalAudioRouteMonitor: routeMonitor,
            looperEngine: engine,
            haptics: haptics,
            captureLimitSeconds: captureLimit
        )
        return (appState, harnessClient, routeMonitor, engine, viewModel)
    }

    private func wait(_ seconds: TimeInterval) async {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func hmsToSeconds(_ value: String) -> Int {
        let parts = value.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let h = Int(parts[0]) ?? 0
        let m = Int(parts[1]) ?? 0
        let s = Int(parts[2]) ?? 0
        return (h * 3600) + (m * 60) + s
    }

    private func waitUntil(timeout: TimeInterval, step: TimeInterval = 0.02, condition: () -> Bool) async -> Bool {
        let timeoutDate = Date().addingTimeInterval(timeout)
        while Date() < timeoutDate {
            if condition() {
                return true
            }
            await wait(step)
        }
        return condition()
    }

}

private final class RecordingHapticsClient: PlayDeckHapticsClient {
    private let disableRecording: Bool
    private(set) var events: [PlayDeckHapticEvent] = []

    init(disableRecording: Bool = false) {
        self.disableRecording = disableRecording
    }

    func play(_ event: PlayDeckHapticEvent) {
        guard !disableRecording else { return }
        events.append(event)
    }
}

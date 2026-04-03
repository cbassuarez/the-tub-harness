//
//  PlayIntoTubViewModel.swift
//  TubCompanion
//
//  State + interaction model for Play Into TUB v2.
//  Keeps capture state machine and deck behavior out of SwiftUI view code.
//

import SwiftUI
import Combine
import UIKit

enum PlayDeckHapticEvent {
    case noteOn
    case quantizeTick
    case clipWarning
}

protocol PlayDeckHapticsClient {
    func play(_ event: PlayDeckHapticEvent)
}

final class SystemPlayDeckHapticsClient: PlayDeckHapticsClient {
    private let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    init() {
        impactGenerator.prepare()
        notificationGenerator.prepare()
    }

    func play(_ event: PlayDeckHapticEvent) {
        switch event {
        case .noteOn:
            impactGenerator.impactOccurred(intensity: 0.58)
        case .quantizeTick:
            impactGenerator.impactOccurred(intensity: 0.25)
        case .clipWarning:
            notificationGenerator.notificationOccurred(.warning)
        }
    }
}

enum PlayDeckConnectionState: Equatable {
    case ready
    case missingCable
    case missingSession
    case missingCableAndSession

    var isReady: Bool {
        self == .ready
    }

    var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .missingCable:
            return "Cable Required"
        case .missingSession:
            return "Session Missing"
        case .missingCableAndSession:
            return "Cable + Session Required"
        }
    }
}

enum CaptureState: Equatable {
    case idle
    case armed
    case recording
    case committing
    case playing
    case error(String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .armed:
            return "Armed"
        case .recording:
            return "Recording"
        case .committing:
            return "Committing"
        case .playing:
            return "Playing"
        case .error:
            return "Error"
        }
    }
}

struct ArmedPadState: Equatable {
    let padId: UUID
    let padIndex: Int

    var label: String {
        "Pad \(padIndex + 1)"
    }
}

struct PlayPadUIState: Identifiable {
    let id: UUID
    let padIndex: Int
    let title: String
    let modeLabel: String
    let playbackState: PlaybackState
    let isArmed: Bool
    let isMuted: Bool
    let level: Float
    let headProgress: Double
    let hasContent: Bool
    let durationLabel: String
}

enum SynthScale: String, CaseIterable, Identifiable {
    case minorPentatonic = "Minor Pent"
    case majorPentatonic = "Major Pent"
    case dorian = "Dorian"
    case chromatic = "Chromatic"

    var id: String { rawValue }

    private var intervals: [Int] {
        switch self {
        case .minorPentatonic:
            return [0, 3, 5, 7, 10]
        case .majorPentatonic:
            return [0, 2, 4, 7, 9]
        case .dorian:
            return [0, 2, 3, 5, 7, 9, 10]
        case .chromatic:
            return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        }
    }

    func midiNotes(baseKey: Int, octave: Int, count: Int) -> [Int] {
        let clampedBase = ((baseKey % 12) + 12) % 12
        let octaveBase = (octave + 1) * 12
        var notes: [Int] = []
        var step = 0
        while notes.count < max(1, count) {
            let interval = intervals[step % intervals.count]
            let octaveOffset = (step / intervals.count) * 12
            notes.append(octaveBase + clampedBase + interval + octaveOffset)
            step += 1
        }
        return notes
    }
}

enum PlayDeckTheme {
    static let graphite = Color.black
    static let panel = Color.black
    static let signal = Color.white.opacity(0.93)
    static let active = Color(UIColor(named: "GlyphGreen") ?? UIColor(red: 0, green: 1, blue: 0.255, alpha: 1))
    static let amber = Color(UIColor(named: "WarningYellow") ?? UIColor(red: 1, green: 0.745, blue: 0.04, alpha: 1))
    static let alert = Color(UIColor(named: "AberrationMagenta") ?? UIColor(red: 1, green: 0, blue: 0.431, alpha: 1))
    static let dimSignal = Color.white.opacity(0.54)
    static let line = Color.white.opacity(0.2)
}

final class PlayIntoTubViewModel: ObservableObject {
    @Published private(set) var connectionState: PlayDeckConnectionState = .missingCableAndSession
    @Published var captureState: CaptureState = .idle
    @Published var quantizeMode: QuantizeMode = .free
    @Published var recordSource: RecordSource = .cableInput
    @Published private(set) var armedPadState: ArmedPadState?
    @Published private(set) var padStates: [PlayPadUIState] = []
    @Published private(set) var captureElapsed: TimeInterval = 0
    @Published var bpm: Int = 120
    @Published var selectedKey: Int = 0
    @Published var selectedScale: SynthScale = .minorPentatonic
    @Published var selectedSynthScene: SynthScene = .reson
    @Published private(set) var pressedSynthNotes: Set<Int> = []
    @Published var queuedContributions: [AudienceAudioContribution] = []
    @Published var showQueueSheet = false
    @Published var pendingClearAllConfirmation = false
    @Published var pendingClearPad: PlayPadUIState?
    @Published private(set) var canUndoLastClear = false
    @Published private(set) var showSoftLevelWarning = false
    @Published private(set) var statusMessage = "Deck ready."

    let captureLimitSeconds: TimeInterval

    private let appState: TubCompanionAppState
    private let harnessClient: HarnessClient
    private let looperEngine: LooperEngine
    private let haptics: PlayDeckHapticsClient
    private let debugAllowCableBypassOverride: Bool?
    private var cancellables = Set<AnyCancellable>()
    private var captureTimer: Timer?
    private var enginePollTimer: Timer?
    private var captureStartedAt: Date?
    private var didWarnOnCurrentHotState = false
    private var lastSynthTickCounter = 0

    private let keyNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

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

    private var debugAllowsCableBypass: Bool {
        if let debugAllowCableBypassOverride {
            return debugAllowCableBypassOverride
        }
        // Debug default is ON so capture/synth are testable without cable hardware.
        return debugFlag("-DEBUG_ALLOW_SPEAKER_WITHOUT_CABLE", defaultValue: true)
            || debugFlag("-DEBUG_SKIP_ENTRY_GATE", defaultValue: true)
    }
    #else
    private var debugAllowsCableBypass: Bool { false }
    #endif

    init(
        appState: TubCompanionAppState,
        harnessClient: HarnessClient,
        externalAudioRouteMonitor _: ExternalAudioRouteMonitor,
        looperEngine: LooperEngine,
        haptics: PlayDeckHapticsClient? = nil,
        debugAllowCableBypassOverride: Bool? = nil,
        captureLimitSeconds: TimeInterval = 60
    ) {
        self.appState = appState
        self.harnessClient = harnessClient
        self.looperEngine = looperEngine
        self.haptics = haptics ?? SystemPlayDeckHapticsClient()
        self.debugAllowCableBypassOverride = debugAllowCableBypassOverride
        self.captureLimitSeconds = captureLimitSeconds
        self.bpm = looperEngine.bpm
        self.quantizeMode = looperEngine.quantizeMode
        self.selectedSynthScene = looperEngine.synthScene

        bindState()
        pullEngineStateSnapshot()
        startEnginePolling()
        updateConnectionState(cableReady: appState.isExternalAudioRouteActive, sessionId: appState.sessionId)
        if let firstPad = looperEngine.uiStateSnapshot().pads.first {
            armPad(firstPad.id)
        }
        refreshQueuedContributions()
    }

    deinit {
        captureTimer?.invalidate()
        enginePollTimer?.invalidate()
    }

    var keyPickerOptions: [(Int, String)] {
        keyNames.enumerated().map { ($0.offset, $0.element) }
    }

    var capturePathReady: Bool {
        connectionState.isReady || debugAllowsCableBypass
    }

    var shouldShowConnectionGateBanner: Bool {
        !connectionState.isReady && !debugAllowsCableBypass
    }

    var availableScales: [SynthScale] {
        SynthScale.allCases
    }

    var availableSynthScenes: [SynthScene] {
        SynthScene.allCases
    }

    var availableRecordSources: [RecordSource] {
        [.cableInput, .internalMix]
    }

    var synthNotes: [Int] {
        selectedScale.midiNotes(baseKey: selectedKey, octave: 3, count: 8)
    }

    func noteLabel(for midiNote: Int) -> String {
        let noteIndex = ((midiNote % 12) + 12) % 12
        let octave = (midiNote / 12) - 1
        return "\(keyNames[noteIndex])\(octave)"
    }

    func armPad(_ padId: UUID) {
        let index = padStates.firstIndex(where: { $0.id == padId })
            ?? looperEngine.uiStateSnapshot().pads.firstIndex(where: { $0.id == padId })
        guard let index else { return }
        armedPadState = ArmedPadState(padId: padId, padIndex: index)
        looperEngine.armPad(padId)
        if case .recording = captureState {
            return
        }
        captureState = .armed
        statusMessage = "\(armedPadState?.label ?? "Pad") armed."
    }

    func startCaptureHold() {
        guard capturePathReady else {
            captureState = .error("Cable route is required before capture.")
            statusMessage = "Connect TRS/USB-C cable to start capture."
            return
        }
        guard let armedPadState else {
            captureState = .error("Arm a pad before recording.")
            statusMessage = "Arm a pad before recording."
            return
        }
        guard captureState != .committing else { return }

        captureState = .recording
        captureElapsed = 0
        captureStartedAt = Date()
        startCaptureTimer()

        looperEngine.beginHoldRecord(into: armedPadState.padId, source: recordSource, quantize: quantizeMode)
        statusMessage = "Recording \(armedPadState.label.lowercased())."
    }

    func endCaptureHold() {
        guard case .recording = captureState else { return }
        commitCapture(autoStopped: false)
    }

    func cancelCapture() {
        if case .recording = captureState {
            looperEngine.endHoldRecord()
        }
        captureTimer?.invalidate()
        captureStartedAt = nil
        captureElapsed = 0
        captureState = .armed
        statusMessage = "Capture canceled."
    }

    func togglePadPlayback(_ padId: UUID) {
        looperEngine.playPad(padId)
    }

    func togglePadMute(_ padId: UUID) {
        guard let pad = padStates.first(where: { $0.id == padId }) else { return }
        looperEngine.setPadMuted(padId, isMuted: !pad.isMuted)
    }

    func requestClearPad(_ padId: UUID) {
        pendingClearPad = padStates.first(where: { $0.id == padId })
    }

    func confirmClearPad() {
        guard let pendingClearPad else { return }
        looperEngine.clearPad(pendingClearPad.id)
        if armedPadState?.padId == pendingClearPad.id {
            captureState = .idle
        }
        statusMessage = "Cleared \(pendingClearPad.title)."
        self.pendingClearPad = nil
    }

    func cancelClearPad() {
        pendingClearPad = nil
    }

    func requestClearAll() {
        pendingClearAllConfirmation = true
    }

    func confirmClearAll() {
        looperEngine.clearAll()
        pendingClearAllConfirmation = false
        captureState = .idle
        statusMessage = "Cleared all pads."
    }

    func cancelClearAll() {
        pendingClearAllConfirmation = false
    }

    func undoLastClear() {
        looperEngine.undoLastClear()
        statusMessage = "Restored last cleared pad."
    }

    func stopAll() {
        looperEngine.stopAllPads()
        if captureState != .committing {
            captureState = .idle
        }
        statusMessage = "Transport stopped."
    }

    func setQuantizeMode(_ mode: QuantizeMode) {
        quantizeMode = mode
        looperEngine.setQuantizeMode(mode)
        statusMessage = mode == .free ? "Free timing enabled." : "Bar quantize enabled."
    }

    func setBPM(_ nextBPM: Int) {
        let clamped = max(60, min(200, nextBPM))
        bpm = clamped
        looperEngine.setBPM(clamped)
    }

    func setRecordSource(_ source: RecordSource) {
        recordSource = source
        switch source {
        case .cableInput:
            statusMessage = "Capture source: cable/mic."
        case .internalMix:
            statusMessage = "Capture source: internal mix."
        }
    }

    func synthPadDown(note: Int) {
        pressedSynthNotes.insert(note)
        looperEngine.triggerSynth(note: note, isOn: true)
        haptics.play(.noteOn)
    }

    func synthPadUp(note: Int) {
        pressedSynthNotes.remove(note)
        looperEngine.triggerSynth(note: note, isOn: false)
        looperEngine.updateSynthGesture(.neutral)
    }

    func synthPadMoved(note: Int, x: Float, y: Float, pressure: Float) {
        looperEngine.updateSynthGesture(
            SynthGesture(note: note, x: x, y: y, pressure: pressure)
        )
    }

    func isSynthNotePressed(_ note: Int) -> Bool {
        pressedSynthNotes.contains(note)
    }

    func setSynthScene(_ scene: SynthScene) {
        selectedSynthScene = scene
        looperEngine.setSynthScene(scene)
        statusMessage = "Synth scene: \(scene.rawValue.uppercased())."
    }

    func refreshQueuedContributions() {
        harnessClient.fetchQueuedContributions { [weak self] items in
            DispatchQueue.main.async {
                self?.queuedContributions = items
            }
        }
    }

    private func bindState() {
        Publishers.CombineLatest(appState.$isExternalAudioRouteActive, appState.$sessionId)
            .receive(on: RunLoop.main)
            .sink { [weak self] cableReady, sessionId in
                self?.updateConnectionState(cableReady: cableReady, sessionId: sessionId)
            }
            .store(in: &cancellables)
    }

    private func startEnginePolling() {
        enginePollTimer?.invalidate()
        enginePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pullEngineStateSnapshot()
        }
        enginePollTimer?.tolerance = 0.01
    }

    private func pullEngineStateSnapshot() {
        let snapshot = looperEngine.uiStateSnapshot()
        rebuildPadStates(pads: snapshot.pads, progress: snapshot.padHeadProgress, levels: snapshot.padLevelMeters)
        evaluateSafety(levels: snapshot.padLevelMeters)
        bpm = snapshot.bpm
        quantizeMode = snapshot.quantizeMode
        selectedSynthScene = snapshot.synthScene
        canUndoLastClear = snapshot.canUndoLastClear

        if snapshot.synthQuantizeTickCounter > lastSynthTickCounter {
            haptics.play(.quantizeTick)
        }
        lastSynthTickCounter = snapshot.synthQuantizeTickCounter
    }

    private func updateConnectionState(cableReady: Bool, sessionId: String?) {
        if cableReady && sessionId != nil {
            connectionState = .ready
        } else if !cableReady && sessionId == nil {
            connectionState = .missingCableAndSession
        } else if !cableReady {
            connectionState = .missingCable
        } else {
            connectionState = .missingSession
        }

        looperEngine.setSynthEnabled(connectionState.isReady || debugAllowsCableBypass)
    }

    private func rebuildPadStates(pads: [LooperPad], progress: [UUID: Double], levels: [UUID: Float]) {
        padStates = pads.enumerated().map { index, pad in
            let head = progress[pad.id] ?? pad.headProgress
            let level = levels[pad.id] ?? pad.lastLevel
            return PlayPadUIState(
                id: pad.id,
                padIndex: index,
                title: "Pad \(index + 1)",
                modeLabel: pad.mode.displayName,
                playbackState: pad.playbackState,
                isArmed: armedPadState?.padId == pad.id,
                isMuted: pad.isMuted,
                level: level,
                headProgress: head,
                hasContent: pad.audioBuffer != nil,
                durationLabel: "\(Int(max(0, pad.duration.rounded())))s"
            )
        }
    }

    private func evaluateSafety(levels: [UUID: Float]) {
        let peak = levels.values.max() ?? 0
        showSoftLevelWarning = peak > 0.92
        if showSoftLevelWarning {
            statusMessage = "Input hot. Pull pad volume for headroom."
            if !didWarnOnCurrentHotState {
                haptics.play(.clipWarning)
            }
            didWarnOnCurrentHotState = true
        } else {
            didWarnOnCurrentHotState = false
        }
    }

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.handleCaptureTimerTick()
        }
        captureTimer?.tolerance = 0.01
    }

    private func handleCaptureTimerTick() {
        guard let captureStartedAt else {
            captureTimer?.invalidate()
            return
        }
        let elapsed = Date().timeIntervalSince(captureStartedAt)
        captureElapsed = min(captureLimitSeconds, elapsed)
        if elapsed >= captureLimitSeconds {
            captureTimer?.invalidate()
            commitCapture(autoStopped: true)
        }
    }

    private func commitCapture(autoStopped: Bool) {
        guard case .recording = captureState else { return }
        captureTimer?.invalidate()
        looperEngine.endHoldRecord()
        captureState = .committing
        if autoStopped {
            statusMessage = "Capture capped at \(Int(captureLimitSeconds))s."
        } else {
            statusMessage = "Committing capture."
        }

        if let sessionId = appState.sessionId {
            let contribution = AudienceAudioContribution(
                sessionId: sessionId,
                durationMs: max(1, Int(captureElapsed * 1000))
            )
            queuedContributions.insert(contribution, at: 0)
            harnessClient.uploadAudioContribution(contribution)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.captureState == .committing else { return }
            self.captureState = .playing
            self.captureElapsed = 0
            self.captureStartedAt = nil
            self.statusMessage = "Loop ready."
        }
    }
}

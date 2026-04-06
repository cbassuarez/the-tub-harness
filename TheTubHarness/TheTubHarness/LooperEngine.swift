//
//  LooperEngine.swift
//  TheTubHarness
//
//  4-track modular looper with frame-accurate sync, BPM-based timing,
//  and real-time mixing for the Play tab.
//

import Foundation
import AVFoundation
import Combine
import Accelerate
import AudioToolbox

// MARK: - Data Models

enum QuantizeMode: String, CaseIterable, Codable {
    case free
    case bar
}

enum RecordSource: String, CaseIterable, Codable {
    case cableInput
    case internalMix
}

enum SynthScene: String, CaseIterable, Codable, Identifiable {
    case reson
    case strike
    case drift

    var id: String { rawValue }
}

struct SynthGesture: Equatable {
    var note: Int
    var x: Float
    var y: Float
    var pressure: Float

    static let neutral = SynthGesture(note: -1, x: 0.5, y: 0.5, pressure: 0)

    var clamped: SynthGesture {
        SynthGesture(
            note: note,
            x: max(0, min(1, x)),
            y: max(0, min(1, y)),
            pressure: max(0, min(1, pressure))
        )
    }
}

struct LooperPad: Identifiable {
    let id: UUID
    var mode: PadMode
    var audioBuffer: AVAudioPCMBuffer?
    var playbackState: PlaybackState
    var currentFrame: Int64 = 0
    var volume: Float = 0.8
    var duration: TimeInterval
    var waveformPeaks: [Float] = []
    var isMuted: Bool = false
    var headProgress: Double = 0
    var headAnchorDate: Date?
    var pausedHeadProgress: Double = 0
    var lastLevel: Float = 0

    init(id: UUID = UUID(), mode: PadMode, duration: TimeInterval = 4.0) {
        self.id = id
        self.mode = mode
        self.duration = duration
        self.playbackState = .empty
    }
}

enum PadMode {
    case synth(instrument: String)
    case file(fileName: String, sourcePath: String)
    case mic(isRecording: Bool)
    case soundBank(contributionId: String, contributor: String)
    
    var displayName: String {
        switch self {
        case .synth: return "SYNTH"
        case .file(let name, _): return name
        case .mic: return "MIC"
        case .soundBank(_, let contributor): return contributor
        }
    }
}

enum PlaybackState {
    case empty
    case playing
    case paused
    case recording
}

struct LooperEngineUISnapshot {
    let pads: [LooperPad]
    let padHeadProgress: [UUID: Double]
    let padLevelMeters: [UUID: Float]
    let bpm: Int
    let quantizeMode: QuantizeMode
    let synthScene: SynthScene
    let canUndoLastClear: Bool
    let synthQuantizeTickCounter: Int
}

// MARK: - Looper Engine

final class LooperEngine: NSObject, ObservableObject {
    // MARK: State Properties
    var pads: [LooperPad]
    var bpm: Int = 120 { didSet { updateLoopDurations() } }
    var quantizeMode: QuantizeMode = .free
    var masterVolume: Float = 0.8
    var masterPeaks: [Float] = []
    var isPlaying: Bool = false
    private(set) var armedPadId: UUID?
    private(set) var recordingPadId: UUID?
    private(set) var padHeadProgress: [UUID: Double] = [:]
    private(set) var padLevelMeters: [UUID: Float] = [:]
    private(set) var activeSynthNotes: Set<Int> = []
    private(set) var activeSynthVoiceCount: Int = 0
    private(set) var synthScene: SynthScene = .reson
    private(set) var synthEnabled: Bool = true
    private(set) var synthGesture: SynthGesture = .neutral
    private(set) var synthQuantizeTickCounter: Int = 0
    private(set) var canUndoLastClear: Bool = false

    // MARK: Private Properties
    private let audioQueue = DispatchQueue(label: "tub.looper.audio", qos: .userInteractive)
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var padMixers: [UUID: AVAudioMixerNode] = [:]
    private var padPlayers: [UUID: AVAudioPlayerNode] = [:]
    private var synthInputMixer: AVAudioMixerNode?
    private var synthMixer: AVAudioMixerNode?
    private var synthSampler: AVAudioUnitSampler?
    private var synthExciterPlayer: AVAudioPlayerNode?
    private var synthDistortion: AVAudioUnitDistortion?
    private var synthReverb: AVAudioUnitReverb?
    private var synthDelay: AVAudioUnitDelay?
    private var synthExciterNoiseBuffer: AVAudioPCMBuffer?
    private var synthVoiceOrder: [Int] = []
    private var synthLastNote: Int = 48
    private var synthInputEnergy: Float = 0
    private var synthExciterGain: Float = 0.2
    private var synthBaseMixGain: Float = 0.8
    private var synthDuckingGain: Float = 1
    private var externalRouteActive: Bool = false
    private var pendingQuantizedSynthOns: [Int: DispatchWorkItem] = [:]
    private var pendingQuantizedSynthOffs: [Int: DispatchWorkItem] = [:]
    private var pendingRecordSources: [UUID: RecordSource] = [:]
    private var activeMicRecorder: AVAudioRecorder?
    private var activeMicRecordingURL: URL?
    private var activeRecordingStartDate: Date?
    private let maxHoldRecordDuration: TimeInterval = 60
    
    private var sampleRate: Double = 48_000
    private var framePosition: Int64 = 0
    private var loopFrameCount: Int64 = 0
    private let lock = NSLock()
    private var progressTimer: Timer?
    private var timelineStartDate = Date()

    // Master recording buffer
    private var masterRecordingBuffer: AVAudioPCMBuffer?
    private var recordingFramePosition: Int64 = 0
    private var pendingQuantizedRecordStart: DispatchWorkItem?
    private var pendingQuantizedRecordStop: DispatchWorkItem?
    private var currentRecordSource: RecordSource = .cableInput
    private var lastClearedPadSnapshot: LooperPad?

#if os(iOS)
    // iOS stability guard: AVAudioUnitSampler initialization has been
    // crashing on device/simulator in this target during graph start.
    // Keep pitched intent through gesture/exciter behavior for now.
    private let useSamplerVoiceLayer = false
#else
    private let useSamplerVoiceLayer = true
#endif
    
    // MARK: Initialization
    
    override init() {
        self.pads = (0..<4).map { _ in LooperPad(mode: .synth(instrument: "piano")) }
        super.init()
        setupAudioEngine()
        updateLoopDurations()
        setupProgressTimer()
    }

    deinit {
        progressTimer?.invalidate()
        pendingQuantizedRecordStart?.cancel()
        pendingQuantizedRecordStop?.cancel()
        for work in pendingQuantizedSynthOns.values {
            work.cancel()
        }
        for work in pendingQuantizedSynthOffs.values {
            work.cancel()
        }

        lock.lock()
        for player in padPlayers.values {
            player.stop()
        }
        activeMicRecorder?.stop()
        if let url = activeMicRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeMicRecorder = nil
        activeMicRecordingURL = nil
        synthExciterPlayer?.stop()
        audioEngine?.stop()
        lock.unlock()
    }
    
    // MARK: Setup
    
    private func setupAudioEngine() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            #if os(iOS)
            self.configureAudioSessionForOutput()
            #endif
            
            let engine = AVAudioEngine()
            self.audioEngine = engine
            self.sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            
            // Create master mixer
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: outputFormat)
            self.mixerNode = mixer
            
            // Create pad mixers and players
            for pad in self.pads {
                let padMixer = AVAudioMixerNode()
                let player = AVAudioPlayerNode()
                
                engine.attach(padMixer)
                engine.attach(player)
                
                engine.connect(player, to: padMixer, format: self.format)
                engine.connect(padMixer, to: mixer, format: self.format)
                
                self.padMixers[pad.id] = padMixer
                self.padPlayers[pad.id] = player
            }

            self.configureSynthGraph(engine: engine, outputFormat: outputFormat, masterMixer: mixer)
            self.applySynthSceneLocked(self.synthScene)
            
            do {
                try engine.start()
            } catch {
                print("❌ Audio engine start failed: \(error)")
            }
            self.applyEffectiveMasterVolumeLocked()
        }
    }

    private func ensureEngineRunningLocked() -> Bool {
        guard let engine = audioEngine else { return false }
        if engine.isRunning {
            return true
        }

        do {
            try engine.start()
            return engine.isRunning
        } catch {
            return false
        }
    }

#if os(iOS)
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

    private var debugAllowSpeakerWithoutCable: Bool {
        debugFlag("-DEBUG_ALLOW_SPEAKER_WITHOUT_CABLE", defaultValue: true)
    }
    #endif

    private func configureAudioSessionForOutput() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowAirPlay, .defaultToSpeaker]

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true, options: [])

            #if DEBUG
            if debugAllowSpeakerWithoutCable {
                let hasExternalRoute = session.currentRoute.outputs.contains {
                    $0.portType == .headphones || $0.portType == .lineOut || $0.portType == .usbAudio
                }
                try session.overrideOutputAudioPort(hasExternalRoute ? .none : .speaker)
            }
            #endif
        } catch {
            print("⚠️ Audio session configuration failed: \(error)")
        }
    }
    #endif
    
    private var format: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    private func startPlayerWhenReadyLocked(
        _ player: AVAudioPlayerNode,
        retriesRemaining: Int = 8,
        retryDelay: TimeInterval = 0.03
    ) {
        guard ensureEngineRunningLocked(), let engine = audioEngine else { return }
        if engine.outputNode.lastRenderTime != nil {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak player] in
            guard let self, let player else { return }
            self.audioQueue.async { [weak self, weak player] in
                guard let self, let player else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.startPlayerWhenReadyLocked(player, retriesRemaining: retriesRemaining - 1, retryDelay: retryDelay)
            }
        }
    }

    private func configureSynthGraph(engine: AVAudioEngine, outputFormat: AVAudioFormat, masterMixer: AVAudioMixerNode) {
        let inputMixer = AVAudioMixerNode()
        let synthMix = AVAudioMixerNode()
        let exciter = AVAudioPlayerNode()
        let distortion = AVAudioUnitDistortion()
        let reverb = AVAudioUnitReverb()
        let delay = AVAudioUnitDelay()
        let sampler = useSamplerVoiceLayer ? AVAudioUnitSampler() : nil

        for node in [inputMixer, synthMix, exciter, distortion, reverb, delay] {
            engine.attach(node)
        }
        if let sampler {
            engine.attach(sampler)
        }

        if let sampler {
            engine.connect(sampler, to: inputMixer, format: format)
        }
        engine.connect(exciter, to: inputMixer, format: format)
        engine.connect(inputMixer, to: distortion, format: format)
        engine.connect(distortion, to: reverb, format: format)
        engine.connect(reverb, to: delay, format: format)
        engine.connect(delay, to: synthMix, format: format)
        engine.connect(synthMix, to: masterMixer, format: outputFormat)

        synthInputMixer = inputMixer
        synthMixer = synthMix
        synthSampler = sampler
        synthExciterPlayer = exciter
        synthDistortion = distortion
        synthReverb = reverb
        synthDelay = delay
        synthMixer?.outputVolume = synthBaseMixGain

        synthExciterNoiseBuffer = makeNoiseBurstBuffer(duration: 0.09)
        if let sampler {
            configureSamplerInstrument(sampler)
        }
        configureCharacterBus(distortion: distortion, reverb: reverb, delay: delay)
    }

    private func configureSamplerInstrument(_ sampler: AVAudioUnitSampler) {
        let manifest: [(name: String, ext: String)] = [
            ("Mother 3", "sf2"),
            ("EarthBound", "sf2"),
            ("Mother_1_2_Game_Boy_Advanced_Soundfont", "sf2")
        ]

        for entry in manifest {
            if let url = Bundle.main.url(forResource: entry.name, withExtension: entry.ext, subdirectory: "Assets/Soundfonts") ??
                Bundle.main.url(forResource: entry.name, withExtension: entry.ext) {
                do {
                    try sampler.loadSoundBankInstrument(
                        at: url,
                        program: 0,
                        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                        bankLSB: 0
                    )
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func configureCharacterBus(
        distortion: AVAudioUnitDistortion,
        reverb: AVAudioUnitReverb,
        delay: AVAudioUnitDelay
    ) {
        distortion.loadFactoryPreset(.drumsBitBrush)
        distortion.preGain = -2
        distortion.wetDryMix = 18

        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 12

        delay.delayTime = 0.09
        delay.feedback = 8
        delay.lowPassCutoff = 5_500
        delay.wetDryMix = 8
    }

    private func makeNoiseBurstBuffer(duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(max(128, Int(sampleRate * duration)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let channels = Int(buffer.format.channelCount)
        let totalFrames = Int(frameCount)
        let decayCoefficient = 1 / Float(max(1, totalFrames))

        for channel in 0..<channels {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<totalFrames {
                let noise = Float.random(in: -1...1)
                let envelope = max(0, 1 - (Float(frame) * decayCoefficient))
                data[frame] = noise * envelope * 0.5
            }
        }

        return buffer
    }

    private func setupProgressTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.refreshPadProgressAndLevels()
            }
            self.progressTimer?.tolerance = 0.01
        }
    }

    private func refreshPadProgressAndLevels() {
        lock.lock()
        defer { lock.unlock() }

        var updatedPads = pads
        var progressMap = padHeadProgress
        var levelMap = padLevelMeters
        let now = Date()

        for index in updatedPads.indices {
            var pad = updatedPads[index]
            let duration = max(pad.duration, 0.001)

            switch pad.playbackState {
            case .playing:
                let anchor = pad.headAnchorDate ?? now
                let elapsed = now.timeIntervalSince(anchor)
                let normalized = elapsed.isFinite ? (elapsed / duration).truncatingRemainder(dividingBy: 1) : 0
                let clamped = max(0, min(1, normalized))
                pad.headProgress = clamped
                pad.pausedHeadProgress = clamped
            case .paused:
                pad.headProgress = max(0, min(1, pad.pausedHeadProgress))
            case .recording:
                if let anchor = pad.headAnchorDate {
                    let elapsed = now.timeIntervalSince(anchor)
                    let normalized = max(0, min(1, elapsed / duration))
                    pad.headProgress = normalized
                } else {
                    pad.headProgress = 0
                }
            case .empty:
                pad.headProgress = 0
                pad.pausedHeadProgress = 0
            }

            let level = estimateLevel(for: pad)
            pad.lastLevel = level
            progressMap[pad.id] = pad.headProgress
            levelMap[pad.id] = level
            updatedPads[index] = pad
        }

        let peakInputLevel = levelMap.values.max() ?? 0
        let recordingDuckTarget: Float = recordingPadId == nil ? 1 : 0.72
        synthInputEnergy = max(0, min(1, peakInputLevel))
        synthDuckingGain = (synthDuckingGain * 0.88) + (recordingDuckTarget * 0.12)
        updateSynthMixerVolumeLocked()

        pads = updatedPads
        padHeadProgress = progressMap
        padLevelMeters = levelMap
    }

    private func estimateLevel(for pad: LooperPad) -> Float {
        guard !pad.isMuted else { return 0 }
        guard !pad.waveformPeaks.isEmpty else {
            return pad.playbackState == .recording ? 0.55 : 0
        }

        let idx = min(
            max(Int(Double(pad.waveformPeaks.count - 1) * pad.headProgress), 0),
            max(pad.waveformPeaks.count - 1, 0)
        )
        let peak = pad.waveformPeaks[idx]
        return max(0, min(1, peak * pad.volume))
    }

    private func nextBarDelay() -> TimeInterval {
        let secondsPerBeat = 60.0 / Double(max(1, bpm))
        let secondsPerBar = secondsPerBeat * 4.0
        let elapsed = Date().timeIntervalSince(timelineStartDate)
        let remainder = elapsed.truncatingRemainder(dividingBy: secondsPerBar)
        let delay = remainder == 0 ? 0 : (secondsPerBar - remainder)
        return max(0, delay)
    }

    // MARK: Playback Control
    
    func play() {
        audioQueue.async { [weak self] in
            guard let self = self, let engine = self.audioEngine else { return }

            self.lock.lock()
            defer { self.lock.unlock() }
            
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    print("❌ Failed to start engine: \(error)")
                    return
                }
            }

            for (padId, player) in self.padPlayers {
                guard let index = self.pads.firstIndex(where: { $0.id == padId }) else { continue }
                if let buffer = self.pads[index].audioBuffer, !player.isPlaying {
                    self.scheduleLoopBuffer(buffer, for: padId, player: player)
                    self.startPlayerWhenReadyLocked(player)
                    self.pads[index].playbackState = .playing
                    let pausedProgress = self.pads[index].pausedHeadProgress
                    self.pads[index].headAnchorDate = Date().addingTimeInterval(-pausedProgress * max(self.pads[index].duration, 0.001))
                }
            }

            self.isPlaying = true
        }
    }
    
    func stop() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            for player in self.padPlayers.values {
                player.stop()
            }
            self.stopAllSynthNotesLocked()

            self.framePosition = 0
            self.isPlaying = false
            for index in self.pads.indices {
                switch self.pads[index].playbackState {
                case .empty:
                    break
                case .playing, .paused, .recording:
                    self.pads[index].playbackState = .paused
                    self.pads[index].pausedHeadProgress = 0
                    self.pads[index].headProgress = 0
                    self.pads[index].headAnchorDate = Date()
                }
            }
        }
    }
    
    func pause() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            for player in self.padPlayers.values {
                player.pause()
            }

            self.isPlaying = false
            for index in self.pads.indices {
                switch self.pads[index].playbackState {
                case .playing:
                    self.pads[index].playbackState = .paused
                    self.pads[index].pausedHeadProgress = self.pads[index].headProgress
                case .empty, .paused, .recording:
                    break
                }
            }
        }
    }
    
    // MARK: Pad Control
    
    func playPad(_ id: UUID) {
        audioQueue.async { [weak self] in
            guard let self = self, let player = self.padPlayers[id], let pad = self.pads.first(where: { $0.id == id }) else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            guard let buffer = pad.audioBuffer else { return }

            if player.isPlaying {
                player.pause()
                if let index = self.pads.firstIndex(where: { $0.id == id }) {
                    self.pads[index].playbackState = .paused
                    self.pads[index].pausedHeadProgress = self.pads[index].headProgress
                }
            } else {
                self.scheduleLoopBuffer(buffer, for: id, player: player)
                if self.ensureEngineRunningLocked() {
                    self.startPlayerWhenReadyLocked(player)
                }
                if let index = self.pads.firstIndex(where: { $0.id == id }) {
                    self.pads[index].playbackState = .playing
                    let pausedProgress = self.pads[index].pausedHeadProgress
                    self.pads[index].headAnchorDate = Date().addingTimeInterval(-pausedProgress * max(self.pads[index].duration, 0.001))
                }
            }
        }
    }
    
    func pausePad(_ id: UUID) {
        audioQueue.async { [weak self] in
            guard let self = self, let player = self.padPlayers[id] else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            if player.isPlaying {
                player.pause()
                if let index = self.pads.firstIndex(where: { $0.id == id }) {
                    self.pads[index].playbackState = .paused
                    self.pads[index].pausedHeadProgress = self.pads[index].headProgress
                }
            }
        }
    }
    
    func setPadVolume(_ id: UUID, volume: Float) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            if let index = self.pads.firstIndex(where: { $0.id == id }) {
                self.pads[index].volume = max(0, min(1, volume))
            }

            if let mixer = self.padMixers[id] {
                mixer.outputVolume = max(0, min(1, volume))
            }
        }
    }
    
    func setMasterVolume(_ volume: Float) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            self.masterVolume = max(0, min(1, volume))
            self.applyEffectiveMasterVolumeLocked()
        }
    }

    /// Mute all engine output when no external cable route is active.
    func setExternalRouteActive(_ active: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.externalRouteActive = active
            self.applyEffectiveMasterVolumeLocked()
        }
    }

    private func applyEffectiveMasterVolumeLocked() {
        let effective: Float = externalRouteActive ? masterVolume : 0
        mixerNode?.outputVolume = effective
    }
    
    func setBPM(_ bpm: Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.bpm = max(60, min(240, bpm))
        }
    }

    func setQuantizeMode(_ mode: QuantizeMode) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.quantizeMode = mode
        }
    }

    func setSynthScene(_ scene: SynthScene) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.applySynthSceneLocked(scene)
        }
    }

    func setSynthEnabled(_ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.synthEnabled = enabled
            if !enabled {
                self.stopAllSynthNotesLocked()
            }
            self.updateSynthMixerVolumeLocked()
        }
    }

    func updateSynthGesture(_ gesture: SynthGesture) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            let clamped = gesture.clamped
            self.synthGesture = clamped
            self.applyGestureToCharacterBusLocked(clamped)
        }
    }

    func armPad(_ id: UUID) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.armedPadId = id
        }
    }

    func setPadMuted(_ id: UUID, isMuted: Bool) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            guard let index = self.pads.firstIndex(where: { $0.id == id }) else { return }
            self.pads[index].isMuted = isMuted
            if let mixer = self.padMixers[id] {
                mixer.outputVolume = isMuted ? 0 : self.pads[index].volume
            }
        }
    }

    func clearPad(_ id: UUID) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            guard let index = self.pads.firstIndex(where: { $0.id == id }) else { return }
            self.lastClearedPadSnapshot = self.pads[index]
            self.canUndoLastClear = true

            self.pads[index].audioBuffer = nil
            self.pads[index].playbackState = .empty
            self.pads[index].currentFrame = 0
            self.pads[index].waveformPeaks = []
            self.pads[index].headProgress = 0
            self.pads[index].pausedHeadProgress = 0
            self.pads[index].headAnchorDate = nil
            self.pads[index].lastLevel = 0

            if let player = self.padPlayers[id] {
                player.stop()
            }
        }
    }

    func undoLastClear() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            guard let snapshot = self.lastClearedPadSnapshot,
                  let index = self.pads.firstIndex(where: { $0.id == snapshot.id }) else { return }

            self.pads[index] = snapshot
            self.lastClearedPadSnapshot = nil
            self.canUndoLastClear = false

            let shouldResumePlayback: Bool
            switch snapshot.playbackState {
            case .playing:
                shouldResumePlayback = true
            case .empty, .paused, .recording:
                shouldResumePlayback = false
            }

            if shouldResumePlayback,
               let player = self.padPlayers[snapshot.id],
               let buffer = snapshot.audioBuffer {
                self.scheduleLoopBuffer(buffer, for: snapshot.id, player: player)
                if !player.isPlaying {
                    self.startPlayerWhenReadyLocked(player)
                }
                self.isPlaying = true
            }
        }
    }

    func stopAllPads() {
        stop()
    }
    
    // MARK: File Loading
    
    func loadFile(url: URL, into padId: UUID) async -> Bool {
        return await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: false); return }
                
                do {
                    let audioFile = try AVAudioFile(forReading: url)
                    guard let format = audioFile.processingFormat.asSInt16NonInterleaved else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    // Read entire file
                    guard let frameCount = audioFile.length as Int64? else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    try audioFile.read(into: buffer)
                    
                    // Time-stretch to 4 bars at current BPM
                    let stretchedBuffer = self.timeStretch(buffer, to: self.loopFrameCount)
                    
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    
                    if let index = self.pads.firstIndex(where: { $0.id == padId }) {
                        var pad = self.pads[index]
                        pad.audioBuffer = stretchedBuffer
                        pad.playbackState = .playing
                        pad.duration = Double(stretchedBuffer.frameLength) / self.sampleRate
                        pad.waveformPeaks = self.extractPeaks(from: stretchedBuffer)
                        pad.headAnchorDate = Date()
                        pad.headProgress = 0
                        pad.pausedHeadProgress = 0
                        pad.isMuted = false
                        self.pads[index] = pad
                        
                        if let player = self.padPlayers[padId] {
                            self.scheduleLoopBuffer(stretchedBuffer, for: padId, player: player)
                            if !player.isPlaying, self.ensureEngineRunningLocked() {
                                self.startPlayerWhenReadyLocked(player)
                            }
                            self.isPlaying = true
                        }
                    }
                    
                    continuation.resume(returning: true)
                } catch {
                    print("❌ Failed to load file: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: Recording

    func beginHoldRecord(into padId: UUID, source: RecordSource = .cableInput, quantize: QuantizeMode? = nil) {
        let mode: QuantizeMode
        lock.lock()
        mode = quantize ?? quantizeMode
        currentRecordSource = source
        lock.unlock()
        armPad(padId)

        pendingQuantizedRecordStop?.cancel()
        pendingQuantizedRecordStop = nil

        if mode == .bar {
            pendingQuantizedRecordStart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.beginRecordingNow(into: padId)
            }
            pendingQuantizedRecordStart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + nextBarDelay(), execute: work)
        } else {
            beginRecordingNow(into: padId)
        }
    }

    func endHoldRecord() {
        if let pendingStart = pendingQuantizedRecordStart, !pendingStart.isCancelled {
            pendingStart.cancel()
            pendingQuantizedRecordStart = nil
            lock.lock()
            recordingPadId = nil
            lock.unlock()
            return
        }

        lock.lock()
        let pendingPadId = recordingPadId
        let mode = quantizeMode
        lock.unlock()

        guard let padId = pendingPadId else { return }
        if mode == .bar {
            pendingQuantizedRecordStop?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.stopRecordingNow(into: padId)
            }
            pendingQuantizedRecordStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + nextBarDelay(), execute: work)
        } else {
            stopRecordingNow(into: padId)
        }
    }

    private func beginRecordingNow(into padId: UUID) {
        let source: RecordSource
        lock.lock()
        recordingPadId = padId
        source = currentRecordSource
        activeRecordingStartDate = Date()
        lock.unlock()
        startRecording(into: padId, source: source)
    }

    private func stopRecordingNow(into padId: UUID) {
        stopRecording(into: padId)
        lock.lock()
        recordingPadId = nil
        lock.unlock()
    }

    func startRecording(into padId: UUID, source: RecordSource = .cableInput) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            self.pendingRecordSources[padId] = source
            self.currentRecordSource = source
            if source == .cableInput {
                self.startMicrophoneRecorderLocked()
                self.synthDuckingGain = 0.72
                self.updateSynthMixerVolumeLocked()
            } else {
                self.stopAndDiscardMicrophoneRecorderLocked()
            }
            
            if let index = self.pads.firstIndex(where: { $0.id == padId }) {
                var pad = self.pads[index]
                pad.playbackState = .recording
                pad.currentFrame = 0
                pad.headAnchorDate = Date()
                pad.headProgress = 0
                pad.pausedHeadProgress = 0
                switch source {
                case .cableInput:
                    pad.mode = .mic(isRecording: true)
                case .internalMix:
                    pad.mode = .synth(instrument: "internal")
                }
                pad.audioBuffer = nil
                pad.duration = self.maxHoldRecordDuration
                
                self.pads[index] = pad
            }
        }
    }
    
    func stopRecording(into padId: UUID) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            let source = self.pendingRecordSources.removeValue(forKey: padId) ?? self.currentRecordSource
            let now = Date()
            let startedAt = self.activeRecordingStartDate ?? now
            self.activeRecordingStartDate = nil
            let measuredDuration = max(0.08, min(self.maxHoldRecordDuration, now.timeIntervalSince(startedAt)))
            let targetFrameCount = max(1, Int64((measuredDuration * self.sampleRate).rounded()))
            self.synthDuckingGain = 1
            self.updateSynthMixerVolumeLocked()
            
            if let index = self.pads.firstIndex(where: { $0.id == padId }) {
                var pad = self.pads[index]
                if source == .internalMix {
                    pad.audioBuffer = self.renderInternalMixSnapshotBufferLocked(frameCount: targetFrameCount)
                } else {
                    pad.audioBuffer = self.consumeMicrophoneRecordingBufferLocked(maxFrameCount: targetFrameCount)
                        ?? self.makeSilentBufferLocked(frameCount: targetFrameCount)
                }
                pad.playbackState = pad.audioBuffer == nil ? .empty : .playing
                pad.waveformPeaks = pad.audioBuffer.map { self.extractPeaks(from: $0) } ?? []
                pad.headAnchorDate = Date()
                pad.pausedHeadProgress = 0
                pad.duration = pad.audioBuffer.map { Double($0.frameLength) / self.sampleRate } ?? measuredDuration
                if case .mic = pad.mode {
                    pad.mode = .mic(isRecording: false)
                }
                self.pads[index] = pad

                if let player = self.padPlayers[padId], let buffer = pad.audioBuffer {
                    self.scheduleLoopBuffer(buffer, for: padId, player: player)
                    if !player.isPlaying, self.ensureEngineRunningLocked() {
                        self.startPlayerWhenReadyLocked(player)
                    }
                    self.isPlaying = true
                } else {
                    self.isPlaying = self.pads.contains { pad in
                        if case .playing = pad.playbackState {
                            return true
                        }
                        return false
                    }
                }
            }
        }
    }

    func triggerSynth(note: Int, isOn: Bool) {
        let safeNote = max(0, min(127, note))

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            if self.quantizeMode == .bar {
                self.scheduleQuantizedSynthNoteLocked(note: safeNote, isOn: isOn)
            } else {
                self.applySynthNoteGateLocked(note: safeNote, isOn: isOn, shouldTickQuantize: false)
            }
        }
    }

    private func scheduleQuantizedSynthNoteLocked(note: Int, isOn: Bool) {
        if isOn {
            pendingQuantizedSynthOffs[note]?.cancel()
            pendingQuantizedSynthOffs[note] = nil
            pendingQuantizedSynthOns[note]?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.audioQueue.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    self.pendingQuantizedSynthOns[note] = nil
                    self.applySynthNoteGateLocked(note: note, isOn: true, shouldTickQuantize: true)
                }
            }
            pendingQuantizedSynthOns[note] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + nextBarDelay(), execute: work)
            return
        }

        if let pendingOn = pendingQuantizedSynthOns[note], !pendingOn.isCancelled {
            pendingOn.cancel()
            pendingQuantizedSynthOns[note] = nil
            return
        }

        pendingQuantizedSynthOffs[note]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.audioQueue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.pendingQuantizedSynthOffs[note] = nil
                self.applySynthNoteGateLocked(note: note, isOn: false, shouldTickQuantize: true)
            }
        }
        pendingQuantizedSynthOffs[note] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nextBarDelay(), execute: work)
    }

    private func applySynthNoteGateLocked(note: Int, isOn: Bool, shouldTickQuantize: Bool) {
        if isOn {
            startSynthNoteLocked(note: note)
        } else {
            stopSynthNoteLocked(note: note)
        }

        if shouldTickQuantize {
            synthQuantizeTickCounter += 1
        }
    }

    private func startSynthNoteLocked(note: Int) {
        guard synthEnabled else { return }

        synthLastNote = note
        if !activeSynthNotes.contains(note) {
            activeSynthNotes.insert(note)
            synthVoiceOrder.removeAll(where: { $0 == note })
            synthVoiceOrder.append(note)
        }

        let voiceCap = maxVoices(for: synthScene)
        while synthVoiceOrder.count > voiceCap {
            let oldest = synthVoiceOrder.removeFirst()
            activeSynthNotes.remove(oldest)
            synthSampler?.stopNote(UInt8(oldest), onChannel: 0)
        }

        let velocityFloat = 84 + (synthGesture.pressure * 36)
        let velocity = UInt8(max(1, min(127, Int(velocityFloat.rounded()))))
        synthSampler?.startNote(UInt8(note), withVelocity: velocity, onChannel: 0)
        triggerExciterBurstLocked(for: note)
        applyGestureToCharacterBusLocked(synthGesture)
        activeSynthVoiceCount = activeSynthNotes.count
    }

    private func stopSynthNoteLocked(note: Int) {
        pendingQuantizedSynthOns[note]?.cancel()
        pendingQuantizedSynthOns[note] = nil

        activeSynthNotes.remove(note)
        synthVoiceOrder.removeAll(where: { $0 == note })
        synthSampler?.stopNote(UInt8(note), onChannel: 0)
        activeSynthVoiceCount = activeSynthNotes.count
    }

    private func stopAllSynthNotesLocked() {
        for note in activeSynthNotes {
            synthSampler?.stopNote(UInt8(note), onChannel: 0)
        }
        activeSynthNotes.removeAll()
        synthVoiceOrder.removeAll()
        for work in pendingQuantizedSynthOns.values { work.cancel() }
        pendingQuantizedSynthOns.removeAll()
        for work in pendingQuantizedSynthOffs.values { work.cancel() }
        pendingQuantizedSynthOffs.removeAll()
        activeSynthVoiceCount = 0
    }

    private func maxVoices(for scene: SynthScene) -> Int {
        switch scene {
        case .reson:
            return 6
        case .strike:
            return 4
        case .drift:
            return 8
        }
    }

    private func applySynthSceneLocked(_ scene: SynthScene) {
        synthScene = scene

        switch scene {
        case .reson:
            synthBaseMixGain = 0.78
            synthExciterGain = 0.26
            synthDistortion?.preGain = -4
            synthDistortion?.wetDryMix = 14
            synthReverb?.wetDryMix = 13
            synthDelay?.delayTime = 0.08
            synthDelay?.feedback = 6
            synthDelay?.wetDryMix = 8
        case .strike:
            synthBaseMixGain = 0.86
            synthExciterGain = 0.34
            synthDistortion?.preGain = 4
            synthDistortion?.wetDryMix = 22
            synthReverb?.wetDryMix = 9
            synthDelay?.delayTime = 0.06
            synthDelay?.feedback = 5
            synthDelay?.wetDryMix = 5
        case .drift:
            synthBaseMixGain = 0.74
            synthExciterGain = 0.2
            synthDistortion?.preGain = -8
            synthDistortion?.wetDryMix = 10
            synthReverb?.wetDryMix = 24
            synthDelay?.delayTime = 0.12
            synthDelay?.feedback = 12
            synthDelay?.wetDryMix = 12
        }

        while synthVoiceOrder.count > maxVoices(for: scene) {
            let oldest = synthVoiceOrder.removeFirst()
            activeSynthNotes.remove(oldest)
            synthSampler?.stopNote(UInt8(oldest), onChannel: 0)
        }

        updateSynthMixerVolumeLocked()
        activeSynthVoiceCount = activeSynthNotes.count
    }

    private func applyGestureToCharacterBusLocked(_ gesture: SynthGesture) {
        let clamped = gesture.clamped
        let verticalBrightness = 1 - clamped.y
        let spread = clamped.x

        let preGainBase: Float
        switch synthScene {
        case .reson: preGainBase = -6
        case .strike: preGainBase = 2
        case .drift: preGainBase = -9
        }

        synthDistortion?.preGain = preGainBase + (spread * 10)
        synthDistortion?.wetDryMix = max(6, min(32, (synthDistortion?.wetDryMix ?? 12) * 0.7 + spread * 20))
        synthReverb?.wetDryMix = max(4, min(36, (synthReverb?.wetDryMix ?? 12) * 0.6 + (1 - verticalBrightness) * 28))
        synthDelay?.wetDryMix = max(3, min(22, 4 + spread * 14 + (1 - verticalBrightness) * 4))
    }

    private func updateSynthMixerVolumeLocked() {
        let enabledGain: Float = synthEnabled ? 1 : 0
        let sceneGain = synthBaseMixGain
        let gain = enabledGain * sceneGain * synthDuckingGain
        synthMixer?.outputVolume = max(0, min(1, gain))
    }

    private func triggerExciterBurstLocked(for note: Int) {
        guard let exciter = synthExciterPlayer, let burst = synthExciterNoiseBuffer else { return }
        guard ensureEngineRunningLocked() else { return }

        let noteNormalized = Float(note % 12) / 11
        let gestureBoost = 0.6 + (synthGesture.pressure * 0.8)
        let inputBoost = 0.35 + (synthInputEnergy * 0.65)
        exciter.volume = max(0.01, min(1, synthExciterGain * gestureBoost * inputBoost * (0.65 + noteNormalized * 0.35)))

        exciter.scheduleBuffer(burst, at: nil, options: [.interrupts], completionHandler: nil)
        if !exciter.isPlaying {
            startPlayerWhenReadyLocked(exciter)
        }
    }

    private func startMicrophoneRecorderLocked() {
        stopAndDiscardMicrophoneRecorderLocked()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tub-hold-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()
            guard recorder.record(forDuration: maxHoldRecordDuration) else { return }
            activeMicRecorder = recorder
            activeMicRecordingURL = url
        } catch {
            activeMicRecorder = nil
            activeMicRecordingURL = nil
        }
    }

    private func stopAndDiscardMicrophoneRecorderLocked() {
        activeMicRecorder?.stop()
        activeMicRecorder = nil
        if let url = activeMicRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeMicRecordingURL = nil
    }

    private func consumeMicrophoneRecordingBufferLocked(maxFrameCount: Int64) -> AVAudioPCMBuffer? {
        activeMicRecorder?.stop()
        activeMicRecorder = nil
        guard let url = activeMicRecordingURL else { return nil }
        activeMicRecordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let file = try AVAudioFile(forReading: url)
            let sourceFrames = max(1, Int64(file.length))
            guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sourceFrames)) else {
                return nil
            }
            try file.read(into: source, frameCount: AVAudioFrameCount(sourceFrames))
            source.frameLength = AVAudioFrameCount(sourceFrames)

            let sourceDuration = Double(sourceFrames) / max(file.processingFormat.sampleRate, 1)
            let targetFrames = max(1, min(maxFrameCount, Int64((sourceDuration * sampleRate).rounded())))
            guard let converted = convertBufferToEngineFormat(source, targetFrames: targetFrames) else { return nil }
            converted.frameLength = min(converted.frameLength, AVAudioFrameCount(targetFrames))
            return converted
        } catch {
            return nil
        }
    }

    private func renderInternalMixSnapshotBufferLocked(frameCount: Int64) -> AVAudioPCMBuffer? {
        let clampedFrames = max(1, frameCount)
        guard let snapshot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clampedFrames)) else {
            return nil
        }
        snapshot.frameLength = AVAudioFrameCount(clampedFrames)

        for pad in pads where pad.audioBuffer != nil && !pad.isMuted {
            if let buffer = pad.audioBuffer {
                mixAudioBuffer(buffer, into: snapshot, with: pad.volume)
            }
        }

        let notes = Array(activeSynthNotes)
        if !notes.isEmpty {
            mixSynthNotes(notes, into: snapshot, amplitude: 0.12)
        }
        return snapshot
    }

    private func makeSilentBufferLocked(frameCount: Int64) -> AVAudioPCMBuffer? {
        let clampedFrames = max(1, frameCount)
        guard let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clampedFrames)) else {
            return nil
        }
        silent.frameLength = AVAudioFrameCount(clampedFrames)
        if let channels = silent.floatChannelData {
            let channelCount = Int(silent.format.channelCount)
            let sampleCount = Int(clampedFrames)
            for channel in 0..<channelCount {
                channels[channel].assign(repeating: 0, count: sampleCount)
            }
        }
        return silent
    }

    private func convertBufferToEngineFormat(_ source: AVAudioPCMBuffer, targetFrames: Int64) -> AVAudioPCMBuffer? {
        let clampedFrames = max(1, targetFrames)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clampedFrames)) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            return timeStretch(source, to: clampedFrames)
        }

        var hasProvidedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return source
        }

        if conversionError != nil {
            return nil
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if Int64(converted.frameLength) == clampedFrames {
                return converted
            }
            return timeStretch(converted, to: clampedFrames)
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
    
    // MARK: Contribution Recording
    
    func recordContribution() async -> AVAudioPCMBuffer? {
        return await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: nil); return }
                
                self.lock.lock()
                defer { self.lock.unlock() }
                
                // Create master recording buffer (4 bars)
                guard let masterBuffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(self.loopFrameCount)) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Mix all active pads into master buffer
                for pad in self.pads where pad.audioBuffer != nil {
                    if let buffer = pad.audioBuffer {
                        self.mixAudioBuffer(buffer, into: masterBuffer, with: pad.volume)
                    }
                }
                let notes = Array(self.activeSynthNotes)
                if !notes.isEmpty {
                    self.mixSynthNotes(notes, into: masterBuffer, amplitude: 0.1)
                }
                
                continuation.resume(returning: masterBuffer)
            }
        }
    }
    
    // MARK: Utilities
    
    private func updateLoopDurations() {
        let samplesPerBeat = sampleRate * 60.0 / Double(bpm)
        loopFrameCount = Int64(samplesPerBeat * 16) // 4 bars = 16 beats
    }
    
    private func scheduleLoopBuffer(_ buffer: AVAudioPCMBuffer, for padId: UUID, player: AVAudioPlayerNode) {
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
    }
    
    private func timeStretch(_ buffer: AVAudioPCMBuffer, to targetFrames: Int64) -> AVAudioPCMBuffer {
        guard let sourceBuffer = buffer as AVAudioPCMBuffer? else { return buffer }
        
        let stretchedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(targetFrames)) ?? buffer
        
        if sourceBuffer.frameLength == 0 {
            return stretchedBuffer
        }
        
        let ratio = Float(targetFrames) / Float(sourceBuffer.frameLength)
        
        if ratio > 0.95 && ratio < 1.05 {
            // Close enough, no stretch needed
            stretchedBuffer.frameLength = min(AVAudioFrameCount(targetFrames), sourceBuffer.frameLength)
            memcpy(stretchedBuffer.mutableAudioBufferList.pointee.mBuffers.mData, 
                   sourceBuffer.audioBufferList.pointee.mBuffers.mData,
                   Int(stretchedBuffer.frameLength) * Int(format.channelCount) * MemoryLayout<Float>.size)
            return stretchedBuffer
        }
        
        // Simple linear interpolation for time-stretch
        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            guard let srcData = sourceBuffer.floatChannelData?[ch],
                  let dstData = stretchedBuffer.floatChannelData?[ch] else { continue }
            
            for i in 0..<Int(targetFrames) {
                let srcIndex = Float(i) / ratio
                let srcIndexInt = Int(srcIndex)
                let srcIndexFrac = srcIndex - Float(srcIndexInt)
                
                if srcIndexInt + 1 < sourceBuffer.frameLength {
                    let v0 = srcData[srcIndexInt]
                    let v1 = srcData[srcIndexInt + 1]
                    dstData[i] = v0 * (1 - srcIndexFrac) + v1 * srcIndexFrac
                } else if srcIndexInt < sourceBuffer.frameLength {
                    dstData[i] = srcData[srcIndexInt]
                }
            }
        }
        
        stretchedBuffer.frameLength = AVAudioFrameCount(targetFrames)
        return stretchedBuffer
    }
    
    private func mixAudioBuffer(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, with volume: Float) {
        let channelCount = Int(source.format.channelCount)
        let framesToMix = min(source.frameLength, destination.frameLength)
        
        for ch in 0..<channelCount {
            guard let srcData = source.floatChannelData?[ch],
                  let dstData = destination.floatChannelData?[ch] else { continue }
            
            // dst = dst + src * volume (scalar loop to avoid Accelerate signature issues)
            let n = Int(framesToMix)
            let vol = volume
            for i in 0..<n {
                dstData[i] = dstData[i] + srcData[i] * vol
            }
        }
    }

    private func mixSynthNotes(_ notes: [Int], into destination: AVAudioPCMBuffer, amplitude: Float) {
        guard !notes.isEmpty else { return }
        guard let left = destination.floatChannelData?[0] else { return }
        let right = destination.format.channelCount > 1 ? destination.floatChannelData?[1] : nil
        let frameCount = Int(destination.frameLength)
        let gainPerVoice = amplitude / Float(notes.count)

        for note in notes {
            let frequency = 440 * pow(2, Float(note - 69) / 12)
            let phaseStep = Float(2 * Double.pi) * frequency / Float(max(sampleRate, 1))
            var phase: Float = 0

            for frame in 0..<frameCount {
                let envelope = max(0, 1 - (Float(frame) / Float(max(1, frameCount))))
                let sample = (sinf(phase) + 0.24 * sinf(phase * 2.01)) * gainPerVoice * envelope
                left[frame] += sample
                right?[frame] += sample
                phase += phaseStep
                if phase > Float.pi * 2 {
                    phase -= Float.pi * 2
                }
            }
        }
    }
    
    private func extractPeaks(from buffer: AVAudioPCMBuffer, bucketCount: Int = 64) -> [Float] {
        let channelCount = Int(buffer.format.channelCount)
        let framesToAnalyze = buffer.frameLength
        let bucketSize = Int(framesToAnalyze) / bucketCount
        
        guard bucketSize > 0 else { return Array(repeating: 0, count: bucketCount) }
        
        var peaks = [Float](repeating: 0, count: bucketCount)
        
        for ch in 0..<channelCount {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            
            for bucket in 0..<bucketCount {
                let startFrame = bucket * bucketSize
                let endFrame = min((bucket + 1) * bucketSize, Int(framesToAnalyze))
                
                var peak: Float = 0
                let length = vDSP_Length(endFrame - startFrame)
                vDSP_maxv(data.advanced(by: startFrame), 1, &peak, length)
                
                peaks[bucket] = max(peaks[bucket], peak)
            }
        }
        
        return peaks
    }
    
    func clearAll() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            defer { self.lock.unlock() }
            
            for i in 0..<self.pads.count {
                var pad = self.pads[i]
                pad.audioBuffer = nil
                pad.playbackState = .empty
                pad.currentFrame = 0
                pad.waveformPeaks = []
                pad.isMuted = false
                pad.headProgress = 0
                pad.pausedHeadProgress = 0
                pad.headAnchorDate = nil
                pad.lastLevel = 0
                self.pads[i] = pad

                if let player = self.padPlayers[pad.id] {
                    player.stop()
                }
            }
            self.lastClearedPadSnapshot = nil
            self.canUndoLastClear = false
            self.stopAllSynthNotesLocked()
            self.stopAndDiscardMicrophoneRecorderLocked()
            self.activeRecordingStartDate = nil
            self.recordingPadId = nil
        }
    }

    func uiStateSnapshot() -> LooperEngineUISnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LooperEngineUISnapshot(
            pads: pads,
            padHeadProgress: padHeadProgress,
            padLevelMeters: padLevelMeters,
            bpm: bpm,
            quantizeMode: quantizeMode,
            synthScene: synthScene,
            canUndoLastClear: canUndoLastClear,
            synthQuantizeTickCounter: synthQuantizeTickCounter
        )
    }

    func refreshPadMetricsForTesting() {
        refreshPadProgressAndLevels()
    }

    func setTimelineAnchorForTesting(_ anchor: Date) {
        timelineStartDate = anchor
    }

    func synthMacroSnapshotForTesting() -> (scene: SynthScene, gesture: SynthGesture, enabled: Bool, activeVoices: Int) {
        (
            scene: synthScene,
            gesture: synthGesture,
            enabled: synthEnabled,
            activeVoices: activeSynthVoiceCount
        )
    }

}

// MARK: - Helper Extensions

extension AVAudioFormat {
    var asSInt16NonInterleaved: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: self.channelCount, interleaved: false)
    }
}

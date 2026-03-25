//
//  AudioEngineController.swift
//  TheTubHarness
//
//  Input-driven master graph with safety rails for modes 0/1/2/3/4/5/6/7/8/9.
//

import Foundation
import AVFoundation
import simd
import Combine

struct InputAudioAlignment {
    let hostTime: UInt64
    let sampleIndex: Int64
}

struct InputAudioRecordingSummary {
    let outputURL: URL
    let sampleRate: Double
    let channels: Int
    let fileFormat: String
    let droppedBuffers: Int
    let alignment: InputAudioAlignment?
}

private final class AudioRecorder {
    private let outputURL: URL
    private let streamFormat: AVAudioFormat
    private let fileFormat: String
    private let maxPendingBuffers: Int
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let writerQueue = DispatchQueue(label: "tub.audio.record.writer", qos: .utility)

    private var audioFile: AVAudioFile?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var running: Bool = false
    private var writerGroup: DispatchGroup?
    private var droppedBuffers: Int = 0
    private var dropFlag: Bool = false
    private var firstAlignment: InputAudioAlignment?
    private var alignmentPublished: Bool = false

    var onAlignment: ((InputAudioAlignment) -> Void)?

    init(outputURL: URL, streamFormat: AVAudioFormat, fileFormat: String, maxPendingBuffers: Int = 64) {
        self.outputURL = outputURL
        self.streamFormat = streamFormat
        self.fileFormat = fileFormat.lowercased() == "wav" ? "wav" : "caf"
        self.maxPendingBuffers = max(8, maxPendingBuffers)
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let fm = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: streamFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        pendingBuffers.removeAll(keepingCapacity: true)
        droppedBuffers = 0
        dropFlag = false
        firstAlignment = nil
        alignmentPublished = false
        running = true

        let group = DispatchGroup()
        writerGroup = group
        group.enter()
        writerQueue.async { [weak self] in
            defer { group.leave() }
            self?.writerLoop()
        }
    }

    func append(buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        var shouldDrop = false
        lock.lock()
        if !running || pendingBuffers.count >= maxPendingBuffers {
            droppedBuffers += 1
            dropFlag = true
            shouldDrop = true
        } else if firstAlignment == nil {
            let host = (time?.isHostTimeValid == true) ? (time?.hostTime ?? 0) : 0
            let sample = (time?.isSampleTimeValid == true) ? (time?.sampleTime ?? 0) : 0
            firstAlignment = InputAudioAlignment(hostTime: host, sampleIndex: sample)
        }
        lock.unlock()
        if shouldDrop { return }

        guard let copy = Self.copyPCMBuffer(buffer) else { return }

        var alignmentToPublish: InputAudioAlignment?
        lock.lock()
        if !running || pendingBuffers.count >= maxPendingBuffers {
            droppedBuffers += 1
            dropFlag = true
            lock.unlock()
            return
        }
        if let firstAlignment, !alignmentPublished {
            alignmentPublished = true
            alignmentToPublish = firstAlignment
        }
        pendingBuffers.append(copy)
        lock.unlock()

        if let alignmentToPublish, let onAlignment {
            writerQueue.async {
                onAlignment(alignmentToPublish)
            }
        }
        semaphore.signal()
    }

    func stop() -> InputAudioRecordingSummary? {
        lock.lock()
        guard running else {
            lock.unlock()
            return nil
        }
        running = false
        let group = writerGroup
        lock.unlock()

        semaphore.signal()
        group?.wait()

        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        writerGroup = nil
        return InputAudioRecordingSummary(
            outputURL: outputURL,
            sampleRate: streamFormat.sampleRate,
            channels: Int(streamFormat.channelCount),
            fileFormat: fileFormat,
            droppedBuffers: droppedBuffers,
            alignment: firstAlignment
        )
    }

    func consumeDropFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let out = dropFlag
        dropFlag = false
        return out
    }

    private func writerLoop() {
        while true {
            semaphore.wait()

            let nextBuffer: AVAudioPCMBuffer?
            lock.lock()
            if !pendingBuffers.isEmpty {
                nextBuffer = pendingBuffers.removeFirst()
            } else {
                nextBuffer = nil
            }
            let shouldStop = !running && pendingBuffers.isEmpty
            let file = audioFile
            lock.unlock()

            if let nextBuffer, let file {
                do {
                    try file.write(from: nextBuffer)
                } catch {
                    // Keep recorder best-effort and non-fatal.
                }
            }

            if shouldStop {
                break
            }
        }
    }

    private static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copied = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copied.frameLength = source.frameLength

        guard let srcChannels = source.floatChannelData, let dstChannels = copied.floatChannelData else {
            return nil
        }
        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)
        for ch in 0..<channelCount {
            dstChannels[ch].update(from: srcChannels[ch], count: frameCount)
        }
        return copied
    }
}

private final class ReplayAudioInput {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let onBuffer: (AVAudioPCMBuffer, AVAudioTime?) -> Void
    private var audioFile: AVAudioFile?
    private var seekOffsetSeconds: Double = 0

    init(engine: AVAudioEngine, onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime?) -> Void) {
        self.engine = engine
        self.onBuffer = onBuffer
    }

    var isPlaying: Bool { player.isPlaying }

    var sampleRate: Double {
        audioFile?.processingFormat.sampleRate ?? 48_000
    }

    var channels: Int {
        Int(audioFile?.processingFormat.channelCount ?? 1)
    }

    var currentTimeSeconds: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return seekOffsetSeconds
        }
        return seekOffsetSeconds + (Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    var currentSamplePosition: Int64 {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            if let file = audioFile {
                return Int64(seekOffsetSeconds * file.processingFormat.sampleRate)
            }
            return 0
        }
        return Int64(seekOffsetSeconds * playerTime.sampleRate) + playerTime.sampleTime
    }

    func prepare(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        attachNodesIfNeeded()
        mixer.outputVolume = 0

        engine.disconnectNodeOutput(player)
        engine.disconnectNodeInput(mixer)
        engine.disconnectNodeOutput(mixer)
        engine.connect(player, to: mixer, format: file.processingFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: file.processingFormat)

        player.removeTap(onBus: 0)
        player.installTap(onBus: 0, bufferSize: 1024, format: file.processingFormat) { [weak self] buffer, time in
            self?.onBuffer(buffer, time)
        }

        audioFile = file
        try scheduleAndPlay(fromSeconds: 0)
    }

    func seek(to seconds: Double) throws {
        try scheduleAndPlay(fromSeconds: max(0, seconds))
    }

    func stop() {
        player.stop()
        player.removeTap(onBus: 0)
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeInput(mixer)
        engine.disconnectNodeOutput(mixer)
    }

    private func scheduleAndPlay(fromSeconds seconds: Double) throws {
        guard let file = audioFile else {
            throw NSError(
                domain: "ReplayAudioInput",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "replay audio file missing"]
            )
        }
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let startFrame = AVAudioFramePosition(max(0, min(Double(totalFrames), seconds * sampleRate)))
        let framesToPlay = max(0, totalFrames - startFrame)

        player.stop()
        if framesToPlay > 0 {
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(framesToPlay),
                at: nil
            )
            seekOffsetSeconds = Double(startFrame) / sampleRate
            player.play()
        } else {
            seekOffsetSeconds = Double(totalFrames) / sampleRate
        }
    }

    private func attachNodesIfNeeded() {
        if player.engine == nil {
            engine.attach(player)
        }
        if mixer.engine == nil {
            engine.attach(mixer)
        }
    }
}

final class AudioEngineController: ObservableObject {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let renderState = MasterRenderState()
    private var preferredInputUID: String?
    private var recorder: AudioRecorder?
    private var replayInput: ReplayAudioInput?
    private var inputSource: FrameInputSource = .live

    @Published var isAudioRunning: Bool = false
    @Published var audioError: String?

    var onInputRecordingAlignment: ((InputAudioAlignment) -> Void)?

    func start() {
        if isAudioRunning { return }

        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = max(8_000.0, outFormat.sampleRate)
        let outputChannels = Int(max(1, outFormat.channelCount))
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: outFormat.channelCount == 0 ? 2 : outFormat.channelCount)!
        renderState.configure(sampleRate: Float(sampleRate), outputChannels: outputChannels)

        if let sourceNode {
            engine.disconnectNodeInput(sourceNode)
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }

        let src = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.renderState.render(frameCount: frameCount, audioBufferList: audioBufferList)
            return noErr
        }
        self.sourceNode = src
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: renderFormat)

        configureLiveInputTap()

        do {
            try engine.start()
            isAudioRunning = true
            audioError = nil
        } catch {
            isAudioRunning = false
            audioError = "engine start error: \(error)"
        }
    }

    func stop() {
        if !isAudioRunning { return }
        _ = stopInputRecording()
        stopReplayInput(restoreLiveInput: false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isAudioRunning = false
        inputSource = .live
    }

    func selectInputDevice(uid: String) {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preferredInputUID = uid
        renderState.noteInputRoute(uid: uid)
        if isAudioRunning {
            stop()
            start()
        }
    }

    func apply(control: AudioControl) {
        renderState.apply(control: control)
        setReverbTarget(
            presetId: control.reverb.presetId,
            wet: control.reverb.wet,
            decay: control.reverb.decay,
            preDelay: control.reverb.preDelay,
            damping: control.reverb.damping,
            xfadeMs: control.reverb.xfadeMs
        )
    }

    func setReverbTarget(
        presetId: String,
        wet: Double,
        decay: Double,
        preDelay: Double,
        damping: Double,
        xfadeMs: Double
    ) {
        renderState.setReverbTarget(
            ReverbTarget(
                presetId: presetId,
                wet: wet,
                decay: decay,
                preDelay: preDelay,
                damping: damping,
                xfadeMs: xfadeMs
            )
        )
    }

    func snapshotSafetyInterventions() -> [String] {
        var interventions = renderState.snapshotInterventions()
        if recorder?.consumeDropFlag() == true {
            interventions.append("audio_record_drop")
        }
        return interventions
    }

    func currentInputSource() -> FrameInputSource {
        inputSource
    }

    func currentInputCaptureInfo() -> (sampleRate: Double, channels: Int, format: String) {
        if inputSource == .replayFile, let replayInput {
            return (sampleRate: replayInput.sampleRate, channels: replayInput.channels, format: "caf")
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        return (sampleRate: format.sampleRate, channels: Int(format.channelCount), format: "caf")
    }

    func startInputRecording(to url: URL, fileFormat: String = "caf") throws -> (sampleRate: Double, channels: Int, format: String) {
        guard isAudioRunning else {
            throw NSError(domain: "AudioEngineController", code: 20, userInfo: [NSLocalizedDescriptionKey: "audio engine is not running"])
        }
        guard inputSource == .live else {
            throw NSError(domain: "AudioEngineController", code: 21, userInfo: [NSLocalizedDescriptionKey: "input recording only supports live input source"])
        }
        _ = stopInputRecording()

        let format = engine.inputNode.outputFormat(forBus: 0)
        let recorder = AudioRecorder(outputURL: url, streamFormat: format, fileFormat: fileFormat)
        recorder.onAlignment = { [weak self] alignment in
            self?.onInputRecordingAlignment?(alignment)
        }
        try recorder.start()
        self.recorder = recorder
        return (sampleRate: format.sampleRate, channels: Int(format.channelCount), format: fileFormat.lowercased() == "wav" ? "wav" : "caf")
    }

    @discardableResult
    func stopInputRecording() -> InputAudioRecordingSummary? {
        defer { recorder = nil }
        return recorder?.stop()
    }

    func startReplayInput(from audioURL: URL) throws {
        if !isAudioRunning {
            start()
        }
        _ = stopInputRecording()

        inputSource = .replayFile
        engine.inputNode.removeTap(onBus: 0)

        if replayInput == nil {
            replayInput = ReplayAudioInput(engine: engine) { [weak self] buffer, _ in
                self?.renderState.ingestInput(buffer: buffer)
            }
        }
        try replayInput?.prepare(url: audioURL)
    }

    func enableSilentReplayInputFallback() {
        if !isAudioRunning {
            start()
        }
        _ = stopInputRecording()
        replayInput?.stop()
        engine.inputNode.removeTap(onBus: 0)
        inputSource = .replayFile
    }

    func stopReplayInput(restoreLiveInput: Bool = true) {
        replayInput?.stop()
        if restoreLiveInput {
            inputSource = .live
            if isAudioRunning {
                configureLiveInputTap()
            }
        }
    }

    func replayCurrentTimeSeconds() -> Double {
        replayInput?.currentTimeSeconds ?? 0
    }

    func replayCurrentSamplePosition() -> Int64 {
        replayInput?.currentSamplePosition ?? 0
    }

    func seekReplayInput(to seconds: Double) throws {
        guard let replayInput else {
            throw NSError(domain: "AudioEngineController", code: 22, userInfo: [NSLocalizedDescriptionKey: "replay input not active"])
        }
        try replayInput.seek(to: seconds)
    }

    var isReplayInputActive: Bool {
        inputSource == .replayFile && (replayInput?.isPlaying ?? false)
    }

    private func configureLiveInputTap() {
        inputSource = .live
        let input = engine.inputNode
        if let preferredInputUID, !preferredInputUID.isEmpty {
            do {
                try CoreAudioInputCatalog.setCurrentInputDevice(on: input, uid: preferredInputUID)
            } catch {
                audioError = "input select failed: \(error.localizedDescription)"
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            audioError = "no input channels available"
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.renderState.ingestInput(buffer: buffer)
            self?.recorder?.append(buffer: buffer, time: time)
        }
    }
}

struct GridSpatializer {
    static let channelCoords: [SIMD2<Float>] = [
        SIMD2<Float>(-1, 1),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(1, 1),
        SIMD2<Float>(-1, -1),
        SIMD2<Float>(0, -1),
        SIMD2<Float>(1, -1),
    ]

    static func normalizedPointGains(x: Float, y: Float, spread: Float) -> [Float] {
        var out = [Float](repeating: 0, count: 6)
        fillNormalizedPointGains(x: x, y: y, spread: spread, into: &out)
        return out
    }

    static func fillNormalizedPointGains(x: Float, y: Float, spread: Float, into out: inout [Float]) {
        if out.count < 6 {
            out = Array(repeating: 0, count: 6)
        }
        let spreadT = max(0.05, min(1.0, spread))
        let sharpness = 1.0 + (1.25 * (1.0 - spreadT))
        var sum: Float = 0
        for ch in 0..<6 {
            let dx = x - channelCoords[ch].x
            let dy = y - channelCoords[ch].y
            let dist2 = (dx * dx) + (dy * dy)
            let gain = 1.0 / powf(0.12 + dist2, sharpness)
            out[ch] = gain
            sum += gain
        }

        let norm = sum > 1e-6 ? 1.0 / sum : 1.0 / 6.0
        for ch in 0..<6 {
            out[ch] *= norm
        }
    }

    static func downmixStereo(from6 ch: [Float]) -> (left: Float, right: Float) {
        let l = (ch[0] + 0.75 * ch[1] + 0.30 * ch[2] + ch[3] + 0.75 * ch[4] + 0.30 * ch[5]) / 2.55
        let r = (0.30 * ch[0] + 0.75 * ch[1] + ch[2] + 0.30 * ch[3] + 0.75 * ch[4] + ch[5]) / 2.55
        return (l, r)
    }
}

struct ReverbCrossfadeRamp {
    private(set) var mixA: Float = 1
    private(set) var mixB: Float = 0
    private(set) var remainingSamples: Int = 0
    private var step: Float = 0

    mutating func begin(fromAtoB: Bool, samples: Int) {
        remainingSamples = max(1, samples)
        if fromAtoB {
            mixA = 1
            mixB = 0
            step = 1.0 / Float(remainingSamples)
        } else {
            mixA = 0
            mixB = 1
            step = -1.0 / Float(remainingSamples)
        }
    }

    mutating func advance() {
        guard remainingSamples > 0 else { return }
        mixB = min(max(mixB + step, 0), 1)
        mixA = 1 - mixB
        remainingSamples -= 1
    }
}

struct CPUGuardAction {
    let voiceLimit: Int
    let densityScale: Float
    let wetScale: Float
    let active: Bool

    static let normal = CPUGuardAction(voiceLimit: 24, densityScale: 1.0, wetScale: 1.0, active: false)
    static let throttled = CPUGuardAction(voiceLimit: 8, densityScale: 0.65, wetScale: 0.72, active: true)
}

struct CPUGuard {
    private var overloadCount: Int = 0
    private var cooldownBlocks: Int = 0
    private(set) var currentAction: CPUGuardAction = .normal

    mutating func note(renderTimeNs: UInt64, budgetNs: UInt64) {
        if renderTimeNs > (budgetNs * 8 / 10) {
            overloadCount += 1
        } else {
            overloadCount = max(0, overloadCount - 1)
        }

        if overloadCount >= 3 {
            currentAction = .throttled
            cooldownBlocks = 140
            overloadCount = 0
        } else if cooldownBlocks > 0 {
            cooldownBlocks -= 1
            if cooldownBlocks == 0 {
                currentAction = .normal
            }
        }
    }
}

struct SafetyInterventions: OptionSet {
    let rawValue: Int

    static let limiterHit = SafetyInterventions(rawValue: 1 << 0)
    static let densityCap = SafetyInterventions(rawValue: 1 << 1)
    static let voiceCap = SafetyInterventions(rawValue: 1 << 2)
    static let cpuGuard = SafetyInterventions(rawValue: 1 << 3)
    static let feedbackGuard = SafetyInterventions(rawValue: 1 << 4)
    static let resetVoices = SafetyInterventions(rawValue: 1 << 5)

    func names() -> [String] {
        var out: [String] = []
        if contains(.limiterHit) { out.append("limiter_hit") }
        if contains(.densityCap) { out.append("density_cap") }
        if contains(.voiceCap) { out.append("voice_cap") }
        if contains(.cpuGuard) { out.append("cpu_guard") }
        if contains(.feedbackGuard) { out.append("feedback_guard") }
        if contains(.resetVoices) { out.append("reset_voices") }
        return out
    }
}

private struct FeedbackAction {
    let wetScale: Float
    let levelScale: Float
    let active: Bool
}

private struct FeedbackDetector {
    mutating func process(_ sample: Float, sampleRate: Float) -> FeedbackAction {
        _ = sample
        _ = sampleRate
        // TODO(the-tub): add narrowband peak persistence detector -> auto-notch + temporary attenuation.
        return FeedbackAction(wetScale: 1.0, levelScale: 1.0, active: false)
    }
}

private struct GrainVoice {
    var active: Bool = false
    var position: Float = 0
    var age: Int = 0
    var length: Int = 0
    var gain: Float = 0.0

    mutating func reset(position: Float, length: Int, gain: Float) {
        self.active = true
        self.position = position
        self.age = 0
        self.length = max(1, length)
        self.gain = gain
    }
}

private struct Mode4GestureVoice {
    var active: Bool = false
    var source: Int = 0 // 0 = sample table, 1 = resynth
    var index: Int = 0
    var position: Float = 0
    var increment: Float = 1
    var age: Int = 0
    var length: Int = 0
    var gain: Float = 0
    var panX: Float = 0
    var panY: Float = 0

    mutating func reset(source: Int, index: Int, length: Int, gain: Float, panX: Float, panY: Float, increment: Float) {
        self.active = true
        self.source = source
        self.index = index
        self.position = 0
        self.increment = increment
        self.age = 0
        self.length = max(1, length)
        self.gain = gain
        self.panX = panX
        self.panY = panY
    }
}

private struct ResonVoice {
    var active: Bool = false
    var midiNote: Int = 60
    var freqHz: Float = 261.63
    var phase: Float = 0
    var age: Int = 0
    var sustainSamples: Int = 0
    var releaseSamples: Int = 0
    var velocity: Float = 0.7
    var panPhase: Float = 0
    var panSpeed: Float = 0
    var panRadius: Float = 0.5
    var panOffset: Float = 0

    mutating func reset(
        midiNote: Int,
        freqHz: Float,
        sustainSamples: Int,
        releaseSamples: Int,
        velocity: Float,
        panPhase: Float,
        panSpeed: Float,
        panRadius: Float,
        panOffset: Float
    ) {
        self.active = true
        self.midiNote = midiNote
        self.freqHz = max(30, min(4_000, freqHz))
        self.phase = 0
        self.age = 0
        self.sustainSamples = max(1, sustainSamples)
        self.releaseSamples = max(1, releaseSamples)
        self.velocity = max(0, min(1, velocity))
        self.panPhase = panPhase
        self.panSpeed = panSpeed
        self.panRadius = max(0.05, min(1.0, panRadius))
        self.panOffset = panOffset
    }
}

private struct ResonInstrument {
    let id: String
    let wavetable: [Float]
    let gain: Float
    let brightness: Float
    let polyphonyHint: Int

    static func fallback(id: String) -> ResonInstrument {
        let tableCount = 2_048
        var table = [Float](repeating: 0, count: tableCount)
        for i in 0..<tableCount {
            let ph = 2.0 * Float.pi * Float(i) / Float(tableCount)
            table[i] = (sinf(ph) * 0.72) + (sinf(ph * 2.0) * 0.18) + (sinf(ph * 3.0) * 0.10)
        }
        return ResonInstrument(id: id, wavetable: table, gain: 1.0, brightness: 0.5, polyphonyHint: 8)
    }
}

private struct SimpleVerb {
    private var sampleRate: Float = 48_000
    private var buffer: [Float] = Array(repeating: 0, count: 350_000)
    private var preDelayBuffer: [Float] = Array(repeating: 0, count: 16_384)
    private var index: Int = 0
    private var preIndex: Int = 0
    private var delaySamples: Int = 9_600
    private var preDelaySamples: Int = 256
    private var feedback: Float = 0.55
    private var damp: Float = 0.45
    private var lpState: Float = 0

    mutating func configure(sampleRate: Float) {
        self.sampleRate = max(8_000, sampleRate)
        let maxDelay = Int(self.sampleRate * 6.5)
        if buffer.count != maxDelay {
            buffer = Array(repeating: 0, count: maxDelay)
            index = 0
        }
        let maxPre = Int(self.sampleRate * 0.25)
        if preDelayBuffer.count != maxPre {
            preDelayBuffer = Array(repeating: 0, count: maxPre)
            preIndex = 0
        }
    }

    mutating func setTarget(presetId: String, decay: Float, preDelay: Float, damping: Float) {
        let preset = ReverbPreset.forId(presetId)
        let targetDelay = Int(sampleRate * (preset.baseDelaySec + 0.32 * decay))
        delaySamples = min(max(targetDelay, 256), max(512, buffer.count - 1))
        preDelaySamples = min(max(Int(sampleRate * (0.001 + 0.120 * preDelay)), 1), max(1, preDelayBuffer.count - 1))
        damp = min(max(0.08 + 0.88 * damping, 0.08), 0.98)
        feedback = min(max(0.35 + 0.57 * decay * preset.decayShape, 0.25), 0.93)
    }

    mutating func process(_ input: Float) -> Float {
        preDelayBuffer[preIndex] = input
        var preRead = preIndex - preDelaySamples
        if preRead < 0 { preRead += preDelayBuffer.count }
        let predelayed = preDelayBuffer[preRead]
        preIndex += 1
        if preIndex >= preDelayBuffer.count { preIndex = 0 }

        var delayRead = index - delaySamples
        if delayRead < 0 { delayRead += buffer.count }
        let delayed = buffer[delayRead]
        lpState += damp * (delayed - lpState)
        let out = lpState
        buffer[index] = predelayed + (out * feedback)
        index += 1
        if index >= buffer.count { index = 0 }
        return out
    }
}

private struct ReverbPreset {
    let baseDelaySec: Float
    let decayShape: Float

    static func forId(_ id: String) -> ReverbPreset {
        let lower = id.lowercased()
        if lower.contains("plate") || lower.contains("dark") {
            return ReverbPreset(baseDelaySec: 0.070, decayShape: 0.90)
        }
        if lower.contains("space") || lower.contains("field") {
            return ReverbPreset(baseDelaySec: 0.115, decayShape: 1.00)
        }
        if lower.contains("fracture") {
            return ReverbPreset(baseDelaySec: 0.045, decayShape: 0.70)
        }
        return ReverbPreset(baseDelaySec: 0.055, decayShape: 0.82)
    }
}

private struct DualReverbCore {
    private var a = SimpleVerb()
    private var b = SimpleVerb()
    private var sampleRate: Float = 48_000
    private var aIsPrimary: Bool = true
    private var ramp = ReverbCrossfadeRamp()
    private(set) var wet: Float = 0.12

    mutating func configure(sampleRate: Float) {
        self.sampleRate = max(8_000, sampleRate)
        a.configure(sampleRate: self.sampleRate)
        b.configure(sampleRate: self.sampleRate)
    }

    mutating func setTarget(_ target: ReverbTarget) {
        var t = target
        t.clampRails()
        wet = Float(t.wet)
        let xfadeSamples = Int((t.xfadeMs / 1000.0) * Double(sampleRate))
        if aIsPrimary {
            b.setTarget(
                presetId: t.presetId,
                decay: Float(t.decay),
                preDelay: Float(t.preDelay),
                damping: Float(t.damping)
            )
            ramp.begin(fromAtoB: true, samples: xfadeSamples)
            aIsPrimary = false
        } else {
            a.setTarget(
                presetId: t.presetId,
                decay: Float(t.decay),
                preDelay: Float(t.preDelay),
                damping: Float(t.damping)
            )
            ramp.begin(fromAtoB: false, samples: xfadeSamples)
            aIsPrimary = true
        }
    }

    mutating func process(_ send: Float) -> Float {
        let outA = a.process(send)
        let outB = b.process(send)
        let mixed = (outA * ramp.mixA) + (outB * ramp.mixB)
        ramp.advance()
        return mixed * wet
    }

    func debugMix() -> (Float, Float) {
        (ramp.mixA, ramp.mixB)
    }
}

private final class MasterRenderState {
    private let ringLock = NSLock()
    private let stateLock = NSLock()

    private var sampleRate: Float = 48_000
    private var outputChannels: Int = 2
    private var controlTarget = AudioControl()
    private var controlCurrent = AudioControl()
    private var reverb = DualReverbCore()

    private var inputRing: [Float] = Array(repeating: 0, count: 262_144)
    private var ringWrite: Int = 0
    private var ringRead: Int = 0
    private var inputScratch: [Float] = Array(repeating: 0, count: 4_096)

    private var motionPhase: Float = 0
    private var bandMotionPhase: Float = 0

    private var hpPrevX: Float = 0
    private var hpPrevY: Float = 0
    private var hpAlpha: Float = 0.987

    private var limiterGain: Float = 1.0
    private let limiterCeiling: Float = 0.8912509 // -1 dBFS

    private var modeFade: Float = 1.0
    private var modeFadeStep: Float = 0.0

    private var mainGains = [Float](repeating: 1.0 / 6.0, count: 6)
    private var lowGains = [Float](repeating: 1.0 / 6.0, count: 6)
    private var midGains = [Float](repeating: 1.0 / 6.0, count: 6)
    private var highGains = [Float](repeating: 1.0 / 6.0, count: 6)
    private var targetGains = [Float](repeating: 1.0 / 6.0, count: 6)
    private let gainSlew: Float = 0.016

    private var granBuffer = [Float](repeating: 0, count: 262_144)
    private var granWrite: Int = 0
    private var granReadHead: Float = 0
    private var freezeSamplesRemaining: Int = 0
    private var grainSpawnCounter: Int = 0
    private var grainRng: UInt64 = 0x9E3779B97F4A7C15
    private var grains = Array(repeating: GrainVoice(), count: 24)

    private var resonY1 = [Float](repeating: 0, count: 6)
    private var resonY2 = [Float](repeating: 0, count: 6)
    private var downsampleCounter: Int = 0
    private var downsampleHold: Float = 0

    private var lowLP: Float = 0
    private var highHP: Float = 0
    private var highPrevX: Float = 0

    private var wetClampY: Float = 0

    // Mode 1 repeat engine state.
    private var mode1Buffer = [Float](repeating: 0, count: 196_608) // ~4s @48k
    private var mode1Write: Int = 0
    private var mode1PrevInput: Float = 0
    private var mode1Env: Float = 0
    private var mode1PendingTrigger: Bool = false
    private var mode1RepeatActive: Bool = false
    private var mode1RepeatStart: Int = 0
    private var mode1RepeatLength: Int = 0
    private var mode1RepeatPos: Int = 0
    private var mode1SliceLength: Int = 0
    private var mode1SlicePos: Int = 0
    private var mode1RepeatSamplesRemaining: Int = 0
    private var mode1ContinuousRepeatSamples: Int = 0
    private var mode1CooldownSamples: Int = 0
    private var mode1BoundaryStep: Int = -1
    private var mode1PatternStep: Int = 0
    private var mode1SpatialX: Float = 0
    private var mode1SpatialY: Float = 0

    // Mode 4 clean + gesture state.
    private var mode4Voices = Array(repeating: Mode4GestureVoice(), count: 3)
    private var mode4LastTriggerSamplesAgo: Int = 100_000
    private var mode4SessionId: String = "session_boot"
    private var mode4RouteUID: String = "default"
    private var mode4RouteChangedAtMs: Int = 0
    private var mode4LastSessionResetMs: Int = 0
    private var mode4MemoryDecay: Float = 1
    private var mode4SampleTables: [[Float]] = Array(repeating: Array(repeating: 0, count: 2048), count: 6)
    private var mode4SampleTableIds: [String] = []
    private var mode4ActiveVoices: Int = 0
    private var mode4PrevInput: Float = 0

    // Modes 5/6 resonifier state.
    private var resonVoices = Array(repeating: ResonVoice(), count: 8)
    private var resonInstrumentCache: [String: ResonInstrument] = [:]
    private var resonCurrentInstrument: ResonInstrument = ResonInstrument.fallback(id: "inst_A")
    private var resonSwapInstrument: ResonInstrument = ResonInstrument.fallback(id: "inst_A")
    private var resonSwapMix: Float = 1.0
    private var resonSwapStep: Float = 0.0
    private var resonSwapRemaining: Int = 0
    private var resonRootMidi: Int = 60
    private var resonChordIntervals: [Int] = [0, 3, 7, 10]
    private var resonMotif: [Int] = []
    private var resonMotifStep: Int = 0
    private var resonPrevInput: Float = 0
    private var resonPitchPrevInput: Float = 0
    private var resonEnv: Float = 0
    private var resonZeroCrossCount: Int = 0
    private var resonLastCross: Int = 0
    private var resonPitchHz: Float = 220
    private var resonPitchConf: Float = 0
    private var resonNoteAccumulator: Float = 0
    private var resonDebugCounter: Int = 0

    // Mode 7 frequency bucket swap.
    private var mode7CrossFreqs: [Float] = [90, 170, 320, 620, 1_200, 2_300, 4_200]
    private var mode7LPStates = [Float](repeating: 0, count: 7)
    private var mode7BandScratch = [Float](repeating: 0, count: 8)
    private var mode7MappedScratch = [Float](repeating: 0, count: 8)
    private var mode7MatrixCurrent = [Float](repeating: 0, count: 64)
    private var mode7MatrixTarget = [Float](repeating: 0, count: 64)
    private var mode7MappingIdCurrent: String = "swap_pairs"
    private var mode7MorphPhase: Float = 1
    private var mode7LoudnessNorm: Float = 1
    private var mode7HfClampY: Float = 0
    private var mode7BeatStep: Int = -1

    // Gesture-aware mode switching.
    private var pendingControl: AudioControl?
    private var pendingSwitchSamples: Int = 0
    private var transitionSafetySamples: Int = 0
    private var transitionSafetyScale: Float = 1.0

    private var sampleCounter: Int64 = 0

    private var cpuGuard = CPUGuard()
    private var cpuAction: CPUGuardAction = .normal
    private var feedbackDetector = FeedbackDetector()
    private var feedbackWetScale: Float = 1
    private var feedbackLevelScale: Float = 1
    private var lastInterventions: SafetyInterventions = []

    func configure(sampleRate: Float, outputChannels: Int) {
        stateLock.withLock {
            self.sampleRate = max(8_000, sampleRate)
            self.outputChannels = max(1, outputChannels)
            self.hpAlpha = hpfAlpha(fc: 100.0, sampleRate: self.sampleRate)
            self.reverb.configure(sampleRate: self.sampleRate)
            self.reverb.setTarget(controlCurrent.reverb)
            seedMode4Tables()
            preloadResonifierDefaults()
            setMode7TargetMatrix(mappingId: "swap_pairs", bias: 0.5, varianceAmt: 0.2, seed: 7)
            mode7MatrixCurrent = mode7MatrixTarget
            mode4SessionId = "session_\(Int(Date().timeIntervalSince1970))"
        }
    }

    func apply(control: AudioControl) {
        stateLock.withLock {
            var clamped = control
            clamped.reverb.clampRails()
            clamped.mode = max(0, min(10, clamped.mode))
            clamped.level = min(max(clamped.level, 0), 1)
            clamped.dryLevel = min(max(clamped.dryLevel, 0), 1)
            if clamped.mode == 7 {
                clamped.wetLevel = min(max(clamped.wetLevel, 0.75), 1.0)
            } else {
                clamped.wetLevel = min(max(clamped.wetLevel, 0), 0.60)
            }

            if clamped.mode != controlTarget.mode {
                pendingControl = clamped
                pendingSwitchSamples = pendingGestureSamples(outgoingMode: controlTarget.mode)
            } else {
                controlTarget = clamped
            }

            if clamped.mode == 7 {
                setMode7TargetMatrix(
                    mappingId: clamped.mappingId,
                    bias: Float(clamped.bias),
                    varianceAmt: Float(clamped.varianceAmt),
                    seed: clamped.variantSeed
                )
            }
            if clamped.mode == 4 {
                updateMode4SessionDecay()
            }
            if clamped.mode == 5 || clamped.mode == 6 {
                prepareResonifierTargets(control: clamped)
            }

            reverb.setTarget(clamped.reverb)
        }
    }

    func setReverbTarget(_ target: ReverbTarget) {
        stateLock.withLock {
            var clamped = target
            clamped.clampRails()
            controlTarget.reverb = clamped
            reverb.setTarget(clamped)
        }
    }

    func snapshotInterventions() -> [String] {
        stateLock.withLock {
            var out = lastInterventions.names()
            if controlCurrent.mode == 1 {
                out.append("mode1_grid_div:\(controlCurrent.gridDiv)")
                out.append("mode1_repeat_style:\(controlCurrent.repeatStyleId)")
            } else if controlCurrent.mode == 4 {
                out.append("performer_session_id:\(mode4SessionId)")
                out.append("mode4_gesture_type:\(controlCurrent.gestureTypeId)")
            } else if controlCurrent.mode == 5 || controlCurrent.mode == 6 {
                out.append("mode\(controlCurrent.mode)_inst:\(controlCurrent.midiInstId)")
                out.append("mode\(controlCurrent.mode)_chord:\(controlCurrent.chordSetId)")
                out.append("mode\(controlCurrent.mode)_voices:\(resonVoices.filter { $0.active }.count)")
            } else if controlCurrent.mode == 7 {
                out.append("mode7_mapping_id:\(controlCurrent.mappingId)")
                out.append("mode7_wet:\(String(format: "%.3f", controlCurrent.wetLevel))")
            }
            return out
        }
    }

    func noteInputRoute(uid: String) {
        stateLock.withLock {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            if mode4RouteUID != uid {
                mode4RouteUID = uid
                mode4RouteChangedAtMs = now
            }
            updateMode4SessionDecay(nowMs: now)
        }
    }

    private func updateMode4SessionDecay(nowMs: Int? = nil) {
        let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
        let routePersistMs = now - mode4RouteChangedAtMs
        let sinceLastResetMs = now - mode4LastSessionResetMs
        if mode4RouteChangedAtMs > 0, routePersistMs > 2_000, sinceLastResetMs > 10_000 {
            mode4SessionId = "session_\(mode4RouteUID)_\(now / 1000)"
            mode4LastSessionResetMs = now
            mode4MemoryDecay = 1.0
        }

        if mode4LastSessionResetMs == 0 {
            mode4LastSessionResetMs = now
        }
        let ageMin = Float(max(0, now - mode4LastSessionResetMs)) / 60_000.0
        mode4MemoryDecay = max(0.35, 1.0 - (ageMin / 18.0))
    }

    private func pendingGestureSamples(outgoingMode: Int) -> Int {
        switch outgoingMode {
        case 1:
            if mode1RepeatActive {
                let remainingInSlice = max(0, mode1SliceLength - mode1SlicePos)
                return min(max(remainingInSlice, Int(sampleRate * 0.08)), Int(sampleRate * 0.60))
            }
            return Int(sampleRate * 0.06)
        case 4:
            if mode4ActiveVoices > 0 {
                var maxRemaining = 0
                for v in mode4Voices where v.active {
                    maxRemaining = max(maxRemaining, max(0, v.length - v.age))
                }
                return min(max(maxRemaining, Int(sampleRate * 0.10)), Int(sampleRate * 0.50))
            }
            return Int(sampleRate * 0.08)
        case 5, 6:
            var maxRemaining = 0
            for v in resonVoices where v.active {
                let left = (v.sustainSamples + v.releaseSamples) - v.age
                maxRemaining = max(maxRemaining, max(0, left))
            }
            if maxRemaining > 0 {
                return min(max(maxRemaining, Int(sampleRate * 0.08)), Int(sampleRate * 0.45))
            }
            return Int(sampleRate * 0.07)
        case 7:
            return Int(sampleRate * 0.18)
        default:
            return Int(sampleRate * 0.05)
        }
    }

    private func handlePendingModeSwitch() {
        if pendingSwitchSamples > 0 {
            pendingSwitchSamples -= 1
            return
        }
        guard let next = pendingControl else { return }
        pendingControl = nil

        let outgoing = controlCurrent.mode
        controlTarget = next
        modeFade = 0.0
        let fadeSec: Float
        switch outgoing {
        case 4, 7:
            fadeSec = 0.22
        case 1:
            fadeSec = 0.14
        default:
            fadeSec = 0.08
        }
        modeFadeStep = 1.0 / max(1.0, sampleRate * fadeSec)
        transitionSafetySamples = Int(sampleRate * fadeSec)
        transitionSafetyScale = 0.86
    }

    func ingestInput(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        ringLock.lock()
        let cap = inputRing.count
        var write = ringWrite
        var read = ringRead
        for i in 0..<frames {
            var mono: Float = 0
            if channels == 1 {
                mono = channelData[0][i]
            } else {
                for ch in 0..<channels {
                    mono += channelData[ch][i]
                }
                mono /= Float(channels)
            }
            inputRing[write] = mono
            write += 1
            if write >= cap { write = 0 }
            if write == read {
                read += 1
                if read >= cap { read = 0 }
            }
        }
        ringWrite = write
        ringRead = read
        ringLock.unlock()
    }

    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let frames = Int(frameCount)
        guard frames > 0 else { return }

        if inputScratch.count < frames {
            inputScratch = Array(repeating: 0, count: max(frames, inputScratch.count * 2))
        }
        copyInputFrames(into: &inputScratch, frames: frames)

        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !abl.isEmpty else { return }
        let outChannelCount = min(outputChannels, abl.count)
        var outPtrs: [UnsafeMutablePointer<Float>] = []
        outPtrs.reserveCapacity(outChannelCount)
        for ch in 0..<outChannelCount {
            guard let mData = abl[ch].mData else { continue }
            outPtrs.append(mData.assumingMemoryBound(to: Float.self))
        }
        guard !outPtrs.isEmpty else { return }

        stateLock.withLock {
            // Default control-stream smoothing: 500 ms ramp.
            let controlSlew: Float = max(0.000_001, min(1.0, 1.0 / max(1.0, sampleRate * 0.5)))
            var interventions: SafetyInterventions = []
            let activeCpu = cpuAction
            if activeCpu.active {
                interventions.insert(.cpuGuard)
                interventions.insert(.densityCap)
            }

            for n in 0..<frames {
                handlePendingModeSwitch()
                smoothControl(slew: controlSlew)
                if modeFade < 1.0 {
                    modeFade = min(1.0, modeFade + modeFadeStep)
                }
                if transitionSafetySamples > 0 {
                    transitionSafetySamples -= 1
                    transitionSafetyScale += (0.86 - transitionSafetyScale) * 0.0025
                } else {
                    transitionSafetyScale += (1.0 - transitionSafetyScale) * 0.0025
                }

                let input = inputScratch[n]
                let hp = processInputHPF(input)
                let fb = feedbackDetector.process(hp, sampleRate: sampleRate)
                if fb.active {
                    interventions.insert(.feedbackGuard)
                }
                feedbackWetScale = fb.wetScale
                feedbackLevelScale = fb.levelScale

                var ch0: Float = 0
                var ch1: Float = 0
                var ch2: Float = 0
                var ch3: Float = 0
                var ch4: Float = 0
                var ch5: Float = 0

                let mode = controlCurrent.mode
                var dryMono: Float = 0
                var fxMono: Float = 0
                var reverbSend: Float = 0

                switch mode {
                case 1:
                    let repeatOut = processMode1(input: hp, interventions: &interventions)
                    dryMono = hp * Float(controlCurrent.dryLevel)
                    fxMono = repeatOut * Float(controlCurrent.wetLevel)
                    reverbSend = (dryMono * 0.08) + (fxMono * 0.20)
                    placeMode1Object(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 2:
                    let gran = processGranulator(input: hp, cpuAction: activeCpu, interventions: &interventions)
                    dryMono = hp * Float(controlCurrent.dryLevel)
                    fxMono = gran * Float(controlCurrent.wetLevel)
                    reverbSend = (dryMono * 0.12) + (fxMono * 0.48)
                    placeMainObject(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: Float(controlCurrent.motionRadius),
                        mode: mode,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 3:
                    let reson = processResonator(input: hp)
                    var wet = processBitReduction(input: reson * 0.72)
                    wet = processWetHFClamp(input: wet)
                    dryMono = hp * Float(max(controlCurrent.dryLevel, 0.55))
                    fxMono = wet * Float(min(controlCurrent.wetLevel, 0.30))
                    reverbSend = (fxMono * 0.18) + (dryMono * 0.06)
                    placeMainObject(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: Float(controlCurrent.motionRadius),
                        mode: mode,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 4:
                    processMode4(
                        input: hp,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )

                case 5:
                    processResonifier(
                        input: hp,
                        mode: 5,
                        cpuAction: activeCpu,
                        interventions: &interventions,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )

                case 6:
                    processResonifier(
                        input: hp,
                        mode: 6,
                        cpuAction: activeCpu,
                        interventions: &interventions,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )
                    let dry = hp * Float(max(0.40, controlCurrent.dryLevel))
                    ch1 += dry * 0.5
                    ch4 += dry * 0.5
                    reverbSend += dry * 0.10

                case 7:
                    let swapped = processMode7(input: hp)
                    dryMono = hp * Float(controlCurrent.dryLevel)
                    fxMono = swapped * Float(controlCurrent.wetLevel)
                    reverbSend = fxMono * 0.08
                    placeMainObject(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: Float(max(0.20, controlCurrent.motionRadius)),
                        mode: mode,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 8:
                    dryMono = hp * Float(controlCurrent.dryLevel)
                    reverbSend = dryMono * 0.32
                    placeMainObject(
                        sample: dryMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: Float(controlCurrent.motionRadius),
                        mode: mode,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 9:
                    processMode9(
                        input: hp,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )

                default:
                    dryMono = hp * Float(controlCurrent.dryLevel)
                    reverbSend = dryMono * 0.20
                    placeMainObject(
                        sample: dryMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: 0.20,
                        mode: 0,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )
                }

                var reverbWet = reverb.process(reverbSend) * activeCpu.wetScale * feedbackWetScale
                if controlCurrent.mode == 3 {
                    reverbWet = processWetHFClamp(input: reverbWet)
                }
                let diffuse = reverbWet * 0.408
                ch0 += diffuse
                ch1 += diffuse
                ch2 += diffuse
                ch3 += diffuse
                ch4 += diffuse
                ch5 += diffuse

                let master = Float(controlCurrent.level) * modeFade * feedbackLevelScale * transitionSafetyScale
                ch0 *= master; ch1 *= master; ch2 *= master
                ch3 *= master; ch4 *= master; ch5 *= master

                var peak = max6(abs(ch0), abs(ch1), abs(ch2), abs(ch3), abs(ch4), abs(ch5))
                if peak > limiterCeiling {
                    let target = limiterCeiling / (peak + 1e-6)
                    limiterGain = min(limiterGain, target)
                    interventions.insert(.limiterHit)
                } else {
                    limiterGain += (1.0 - limiterGain) * 0.0015
                }

                ch0 *= limiterGain; ch1 *= limiterGain; ch2 *= limiterGain
                ch3 *= limiterGain; ch4 *= limiterGain; ch5 *= limiterGain

                ch0 = hardClip(ch0); ch1 = hardClip(ch1); ch2 = hardClip(ch2)
                ch3 = hardClip(ch3); ch4 = hardClip(ch4); ch5 = hardClip(ch5)

                if outPtrs.count >= 6 {
                    outPtrs[0][n] = ch0
                    outPtrs[1][n] = ch1
                    outPtrs[2][n] = ch2
                    outPtrs[3][n] = ch3
                    outPtrs[4][n] = ch4
                    outPtrs[5][n] = ch5
                    if outPtrs.count > 6 {
                        for ch in 6..<outPtrs.count {
                            outPtrs[ch][n] = 0
                        }
                    }
                } else if outPtrs.count == 2 {
                    let stereo = GridSpatializer.downmixStereo(from6: [ch0, ch1, ch2, ch3, ch4, ch5])
                    outPtrs[0][n] = stereo.left
                    outPtrs[1][n] = stereo.right
                } else {
                    let mono = (ch0 + ch1 + ch2 + ch3 + ch4 + ch5) / 6.0
                    outPtrs[0][n] = mono
                }

                peak = 0
                sampleCounter += 1
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - startNs
            let budgetNs = UInt64(Double(frames) / Double(sampleRate) * 1_000_000_000.0)
            cpuGuard.note(renderTimeNs: elapsed, budgetNs: max(1, budgetNs))
            cpuAction = cpuGuard.currentAction
            if cpuAction.active {
                interventions.insert(.cpuGuard)
            }
            lastInterventions = interventions
        }
    }

    private func copyInputFrames(into out: inout [Float], frames: Int) {
        ringLock.lock()
        let cap = inputRing.count
        var read = ringRead
        let write = ringWrite
        for i in 0..<frames {
            if read == write {
                out[i] = 0
            } else {
                out[i] = inputRing[read]
                read += 1
                if read >= cap { read = 0 }
            }
        }
        ringRead = read
        ringLock.unlock()
    }

    private func smoothControl(slew: Float) {
        controlCurrent.level += Double(slew) * (controlTarget.level - controlCurrent.level)
        controlCurrent.dryLevel += Double(slew) * (controlTarget.dryLevel - controlCurrent.dryLevel)
        controlCurrent.wetLevel += Double(slew) * (controlTarget.wetLevel - controlCurrent.wetLevel)
        controlCurrent.spread += Double(slew) * (controlTarget.spread - controlCurrent.spread)
        controlCurrent.motionSpeed += Double(slew) * (controlTarget.motionSpeed - controlCurrent.motionSpeed)
        controlCurrent.motionRadius += Double(slew) * (controlTarget.motionRadius - controlCurrent.motionRadius)
        controlCurrent.grainSize += Double(slew) * (controlTarget.grainSize - controlCurrent.grainSize)
        controlCurrent.grainDensity += Double(slew) * (controlTarget.grainDensity - controlCurrent.grainDensity)
        controlCurrent.scanRate += Double(slew) * (controlTarget.scanRate - controlCurrent.scanRate)
        controlCurrent.scanJumpProb += Double(slew) * (controlTarget.scanJumpProb - controlCurrent.scanJumpProb)
        controlCurrent.freezeProb += Double(slew) * (controlTarget.freezeProb - controlCurrent.freezeProb)
        controlCurrent.freezeLenSec += Double(slew) * (controlTarget.freezeLenSec - controlCurrent.freezeLenSec)
        controlCurrent.repeatProb += Double(slew) * (controlTarget.repeatProb - controlCurrent.repeatProb)
        controlCurrent.thresholdBias += Double(slew) * (controlTarget.thresholdBias - controlCurrent.thresholdBias)
        controlCurrent.windowNorm += Double(slew) * (controlTarget.windowNorm - controlCurrent.windowNorm)
        controlCurrent.stutterLenNorm += Double(slew) * (controlTarget.stutterLenNorm - controlCurrent.stutterLenNorm)
        controlCurrent.gateSharpness += Double(slew) * (controlTarget.gateSharpness - controlCurrent.gateSharpness)
        controlCurrent.motionIntensity += Double(slew) * (controlTarget.motionIntensity - controlCurrent.motionIntensity)
        controlCurrent.exciteAmount += Double(slew) * (controlTarget.exciteAmount - controlCurrent.exciteAmount)
        controlCurrent.resonance += Double(slew) * (controlTarget.resonance - controlCurrent.resonance)
        controlCurrent.drive += Double(slew) * (controlTarget.drive - controlCurrent.drive)
        controlCurrent.bitDepth += Double(slew) * (controlTarget.bitDepth - controlCurrent.bitDepth)
        controlCurrent.downsample += Double(slew) * (controlTarget.downsample - controlCurrent.downsample)
        controlCurrent.bandLowLevel += Double(slew) * (controlTarget.bandLowLevel - controlCurrent.bandLowLevel)
        controlCurrent.bandMidLevel += Double(slew) * (controlTarget.bandMidLevel - controlCurrent.bandMidLevel)
        controlCurrent.bandHighLevel += Double(slew) * (controlTarget.bandHighLevel - controlCurrent.bandHighLevel)
        controlCurrent.bandMotionSpeed += Double(slew) * (controlTarget.bandMotionSpeed - controlCurrent.bandMotionSpeed)
        controlCurrent.gestureRate += Double(slew) * (controlTarget.gestureRate - controlCurrent.gestureRate)
        controlCurrent.interruptiveness += Double(slew) * (controlTarget.interruptiveness - controlCurrent.interruptiveness)
        controlCurrent.callResponseBias += Double(slew) * (controlTarget.callResponseBias - controlCurrent.callResponseBias)
        controlCurrent.memoryWeight += Double(slew) * (controlTarget.memoryWeight - controlCurrent.memoryWeight)
        controlCurrent.similarityTarget += Double(slew) * (controlTarget.similarityTarget - controlCurrent.similarityTarget)
        controlCurrent.gestureLevel += Double(slew) * (controlTarget.gestureLevel - controlCurrent.gestureLevel)
        controlCurrent.noteRate += Double(slew) * (controlTarget.noteRate - controlCurrent.noteRate)
        controlCurrent.voiceCap += Double(slew) * (controlTarget.voiceCap - controlCurrent.voiceCap)
        controlCurrent.velocityBias += Double(slew) * (controlTarget.velocityBias - controlCurrent.velocityBias)
        controlCurrent.pitchFollow += Double(slew) * (controlTarget.pitchFollow - controlCurrent.pitchFollow)
        controlCurrent.inharmonicity += Double(slew) * (controlTarget.inharmonicity - controlCurrent.inharmonicity)
        controlCurrent.morphRate += Double(slew) * (controlTarget.morphRate - controlCurrent.morphRate)
        controlCurrent.swapCrossfade += Double(slew) * (controlTarget.swapCrossfade - controlCurrent.swapCrossfade)
        controlCurrent.sharpness += Double(slew) * (controlTarget.sharpness - controlCurrent.sharpness)
        controlCurrent.bias += Double(slew) * (controlTarget.bias - controlCurrent.bias)
        controlCurrent.varianceAmt += Double(slew) * (controlTarget.varianceAmt - controlCurrent.varianceAmt)
        controlCurrent.mode = controlTarget.mode
        controlCurrent.resonatorTuningProfileId = controlTarget.resonatorTuningProfileId
        controlCurrent.spatialMotion = controlTarget.spatialMotion
        controlCurrent.hfClampWetPath = controlTarget.hfClampWetPath
        controlCurrent.gridDiv = controlTarget.gridDiv
        controlCurrent.repeatStyleId = controlTarget.repeatStyleId
        controlCurrent.bankId = controlTarget.bankId
        controlCurrent.categoryId = controlTarget.categoryId
        controlCurrent.gestureTypeId = controlTarget.gestureTypeId
        controlCurrent.midiInstId = controlTarget.midiInstId
        controlCurrent.chordSetId = controlTarget.chordSetId
        controlCurrent.motifId = controlTarget.motifId
        controlCurrent.articulationId = controlTarget.articulationId
        controlCurrent.resetVoices = controlTarget.resetVoices
        controlCurrent.mappingId = controlTarget.mappingId
        controlCurrent.variantSeed = controlTarget.variantSeed
        controlCurrent.mappingFamily = controlTarget.mappingFamily
    }

    private func processInputHPF(_ input: Float) -> Float {
        let y = hpAlpha * (hpPrevY + input - hpPrevX)
        hpPrevX = input
        hpPrevY = y
        return y
    }

    private func seedMode4Tables() {
        let ids = ManifestCatalog.shared.banks["samples_A"]?.assets.map(\.id) ?? ["s000", "s001", "s002", "s003"]
        mode4SampleTableIds = Array(ids.prefix(mode4SampleTables.count))
        while mode4SampleTableIds.count < mode4SampleTables.count {
            mode4SampleTableIds.append("s\(String(format: "%03d", mode4SampleTableIds.count))")
        }

        for i in 0..<mode4SampleTables.count {
            let seed = stableSeed(for: mode4SampleTableIds[i])
            var x = seed
            for n in 0..<mode4SampleTables[i].count {
                x = x &* 2862933555777941757 &+ 3037000493
                let r = Float((x >> 33) & 0xFFFF) / Float(0xFFFF)
                let ph = 2.0 * Float.pi * Float(n) / Float(mode4SampleTables[i].count)
                let tone = sinf(ph * (1.0 + Float((i % 3) + 1)))
                let overtone = sinf(ph * (2.0 + Float((i % 5) + 1))) * 0.35
                let noise = (r - 0.5) * 0.18
                mode4SampleTables[i][n] = (tone * 0.65) + overtone + noise
            }
        }
    }

    private func stableSeed(for text: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        return h
    }

    private func mode1GridSamples() -> Int {
        if controlCurrent.gridDiv == "1/16" {
            return max(64, Int(sampleRate * 0.25))
        }
        return max(64, Int(sampleRate * 0.5))
    }

    private func startMode1Repeat(gridSamples: Int) {
        let windowSec = 0.5 + 1.5 * Float(controlCurrent.windowNorm)
        var windowSamples = Int(windowSec * sampleRate)
        windowSamples = max(gridSamples, min(windowSamples, Int(2.0 * sampleRate)))
        windowSamples = max(gridSamples, (windowSamples / gridSamples) * gridSamples)

        let start = mode1Write - windowSamples
        mode1RepeatStart = start >= 0 ? start : (start + mode1Buffer.count)
        mode1RepeatLength = max(gridSamples, windowSamples)
        mode1RepeatPos = 0

        let baseSlice = Int((0.05 + 0.35 * Float(controlCurrent.stutterLenNorm)) * sampleRate)
        let minSlice = max(32, gridSamples / 2)
        mode1SliceLength = max(minSlice, min(mode1RepeatLength, (baseSlice / minSlice) * minSlice))
        if mode1SliceLength <= 0 {
            mode1SliceLength = minSlice
        }
        mode1SlicePos = 0

        mode1RepeatSamplesRemaining = Int((0.8 + 5.2 * Float(controlCurrent.repeatProb)) * sampleRate)
        mode1RepeatActive = true
    }

    private func updateMode1Spatial(step: Int) {
        let intensity = Float(controlCurrent.motionIntensity)
        let radius = max(0.20, min(0.95, Float(controlCurrent.motionRadius) * (0.55 + 0.55 * intensity)))
        let t = Float(step)

        switch controlCurrent.spatialMotion {
        case .orbitPulse:
            let pulse = 0.60 + 0.40 * sinf(t * 0.45)
            mode1SpatialX = radius * pulse * cosf(t * 0.32)
            mode1SpatialY = radius * pulse * sinf(t * 0.32)
        case .jumpCut:
            let sx = sinf(t * 12.9898 + 78.233)
            let sy = sinf(t * 93.9898 + 12.345)
            mode1SpatialX = radius * max(-1, min(1, sx))
            mode1SpatialY = radius * max(-1, min(1, sy))
        case .clusterRotate:
            let centers: [SIMD2<Float>] = [
                SIMD2<Float>(-0.65, 0.40),
                SIMD2<Float>(0.55, 0.35),
                SIMD2<Float>(0.0, -0.60),
            ]
            let c = centers[Int(abs(step)) % centers.count]
            let wobble = 0.16 * intensity
            mode1SpatialX = c.x + wobble * cosf(t * 0.9)
            mode1SpatialY = c.y + wobble * sinf(t * 1.1)
        case .static:
            mode1SpatialX = 0
            mode1SpatialY = 0
        case .drift, .orbit, .fragment:
            mode1SpatialX = radius * cosf(t * 0.30)
            mode1SpatialY = radius * sinf(t * 0.30)
        }
    }

    private func processMode1(input: Float, interventions: inout SafetyInterventions) -> Float {
        mode1Buffer[mode1Write] = input
        mode1Write += 1
        if mode1Write >= mode1Buffer.count { mode1Write = 0 }

        let delta = abs(input - mode1PrevInput)
        mode1PrevInput = input
        mode1Env += 0.004 * (abs(input) - mode1Env)

        if mode1CooldownSamples > 0 {
            mode1CooldownSamples -= 1
        }

        let gridSamples = mode1GridSamples()
        let step = Int(sampleCounter / Int64(max(1, gridSamples)))
        if step != mode1BoundaryStep {
            mode1BoundaryStep = step
            mode1PatternStep += 1
            updateMode1Spatial(step: mode1PatternStep)
            if mode1PendingTrigger, mode1CooldownSamples <= 0 {
                startMode1Repeat(gridSamples: gridSamples)
                mode1PendingTrigger = false
            }
        }

        let threshold = 0.008 + (0.060 * Float(controlCurrent.thresholdBias)) + (0.040 * Float(controlCurrent.gateSharpness))
        let loudEnough = mode1Env > (0.02 + 0.10 * Float(controlCurrent.thresholdBias))
        if loudEnough, delta > threshold, mode1CooldownSamples <= 0 {
            let triggerProb = Float(controlCurrent.repeatProb) * (0.30 + 0.60 * Float(controlCurrent.gateSharpness))
            if randomUnit() < triggerProb * 0.06 {
                mode1PendingTrigger = true
            }
        }

        var wet: Float = 0
        if mode1RepeatActive, mode1RepeatLength > 0 {
            let idx = (mode1RepeatStart + mode1RepeatPos) % mode1Buffer.count
            let raw = mode1Buffer[idx]
            let phase = Float(mode1SlicePos) / Float(max(1, mode1SliceLength))
            let edge = sinf(Float.pi * phase)
            wet = raw * edge

            mode1SlicePos += 1
            mode1RepeatPos += 1
            mode1RepeatSamplesRemaining -= 1
            mode1ContinuousRepeatSamples += 1

            if mode1SlicePos >= mode1SliceLength {
                mode1SlicePos = 0
                if controlCurrent.repeatStyleId == "stutter_b" {
                    let jump = max(1, gridSamples / 2)
                    mode1RepeatPos = (mode1RepeatPos + jump) % mode1RepeatLength
                }
            }
            if mode1RepeatPos >= mode1RepeatLength {
                mode1RepeatPos = 0
            }

            if mode1ContinuousRepeatSamples > Int(sampleRate * 6.0) {
                mode1RepeatActive = false
                mode1ContinuousRepeatSamples = 0
                mode1CooldownSamples = Int(sampleRate * 2.0)
                interventions.insert(.densityCap)
            }

            if mode1RepeatSamplesRemaining <= 0 {
                mode1RepeatActive = false
                mode1ContinuousRepeatSamples = 0
                mode1CooldownSamples = Int(sampleRate * 0.9)
            }
        } else {
            mode1ContinuousRepeatSamples = max(0, mode1ContinuousRepeatSamples - 1)
        }

        return tanhf(wet * 1.4)
    }

    private func placeMode1Object(
        sample: Float,
        spread: Float,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float
    ) {
        let s = max(0.08, min(1.0, spread))
        GridSpatializer.fillNormalizedPointGains(x: mode1SpatialX, y: mode1SpatialY, spread: s, into: &targetGains)
        smoothGains(current: &mainGains, target: targetGains)
        applyGains(sample, gains: mainGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)
    }

    private func spawnMode4Voice(input: Float) {
        let maxVoices = max(1, min(3, Int(1 + floor(controlCurrent.interruptiveness * 2.0))))
        if mode4ActiveVoices >= maxVoices { return }

        guard let slot = mode4Voices.firstIndex(where: { !$0.active }) else { return }
        let tableCount = max(1, mode4SampleTables.count)
        let sim = Float(controlCurrent.similarityTarget)
        let mem = max(0.35, mode4MemoryDecay)
        var idx = Int(round(sim * Float(tableCount - 1)))
        if controlCurrent.callResponseBias < 0.5 {
            idx = (tableCount - 1) - idx
        }
        idx = max(0, min(tableCount - 1, idx))

        let useResynth = randomUnit() > Float(controlCurrent.callResponseBias)
        let source = useResynth ? 1 : 0
        let baseLen = Int((0.12 + 0.40 * Float(controlCurrent.gestureRate)) * sampleRate)
        let len = max(Int(sampleRate * 0.06), min(Int(sampleRate * 0.75), baseLen))
        let gain = (0.20 + 0.70 * Float(controlCurrent.gestureLevel)) * mem
        let panX = (randomUnit() * 2.0 - 1.0) * 0.75
        let panY = (randomUnit() * 2.0 - 1.0) * 0.60
        let inc: Float = useResynth ? (0.5 + 4.0 * max(0.02, abs(input))) : (0.7 + 0.8 * randomUnit())
        mode4Voices[slot].reset(source: source, index: idx, length: len, gain: gain, panX: panX, panY: panY, increment: inc)
        mode4LastTriggerSamplesAgo = 0
    }

    private func processMode4(
        input: Float,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float,
        reverbSend: inout Float
    ) {
        mode4LastTriggerSamplesAgo += 1
        let clean = input * Float(max(0.45, controlCurrent.dryLevel))
        placeMainObject(
            sample: clean,
            spread: Float(min(0.45, controlCurrent.spread)),
            motionSpeed: Float(0.12 + 0.30 * controlCurrent.motionSpeed),
            radius: Float(0.18 + 0.20 * controlCurrent.motionRadius),
            mode: 4,
            &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
        )

        reverbSend = clean * 0.10

        let onsetMetric = abs(input - mode4PrevInput)
        mode4PrevInput = input
        let minGap = Int((0.08 + 0.30 * (1.0 - controlCurrent.interruptiveness)) * Double(sampleRate))
        if mode4LastTriggerSamplesAgo > minGap {
            let triggerProb = Float(controlCurrent.gestureRate) * 0.035
            if onsetMetric > (0.012 + 0.05 * Float(controlCurrent.interruptiveness)), randomUnit() < triggerProb {
                spawnMode4Voice(input: input)
            } else if randomUnit() < triggerProb * 0.1 {
                spawnMode4Voice(input: input * 0.5)
            }
        }

        mode4ActiveVoices = 0
        for i in 0..<mode4Voices.count where mode4Voices[i].active {
            mode4ActiveVoices += 1
            let t = Float(mode4Voices[i].age) / Float(max(1, mode4Voices[i].length))
            let env = sinf(Float.pi * min(max(t, 0), 1))
            var voiceSample: Float = 0
            if mode4Voices[i].source == 0 {
                let table = mode4SampleTables[mode4Voices[i].index % mode4SampleTables.count]
                let idx = Int(mode4Voices[i].position) % table.count
                voiceSample = table[idx]
            } else {
                let ph = mode4Voices[i].position * 0.012
                voiceSample = (sinf(ph) * 0.7) + (sinf(ph * 1.7) * 0.3)
            }

            let g = env * mode4Voices[i].gain
            let voiceOut = voiceSample * g
            GridSpatializer.fillNormalizedPointGains(
                x: mode4Voices[i].panX,
                y: mode4Voices[i].panY,
                spread: max(0.30, min(0.95, Float(controlCurrent.spread) + 0.12)),
                into: &targetGains
            )
            applyGains(voiceOut, gains: targetGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)
            reverbSend += voiceOut * 0.12

            mode4Voices[i].position += mode4Voices[i].increment
            mode4Voices[i].age += 1
            if mode4Voices[i].age >= mode4Voices[i].length {
                mode4Voices[i].active = false
            }
        }
    }

    private func preloadResonifierDefaults() {
        let defaults = ["inst_A", "inst_B", "inst_C", "inst_D", "inst_E"]
        for id in defaults {
            let _ = cachedResonInstrument(id: id)
        }
        resonCurrentInstrument = cachedResonInstrument(id: "inst_A")
        resonSwapInstrument = resonCurrentInstrument
    }

    private func prepareResonifierTargets(control: AudioControl) {
        let instrumentId = control.midiInstId
        let incomingInstrument = cachedResonInstrument(id: instrumentId)
        if incomingInstrument.id != resonCurrentInstrument.id {
            resonSwapInstrument = incomingInstrument
            resonSwapMix = 1.0
            let swapSec = 0.25 + (0.50 * Float(control.inharmonicity))
            resonSwapRemaining = max(1, Int(sampleRate * swapSec))
            resonSwapStep = -1.0 / Float(resonSwapRemaining)
        }

        let chordEntry = ManifestCatalog.shared.chords[control.chordSetId]
        let intervals = chordEntry?.intervals ?? [0, 3, 7, 10]
        resonChordIntervals = intervals.isEmpty ? [0, 3, 7, 10] : intervals
        resonRootMidi = chordRootMidi(for: control.chordSetId, keyHint: chordEntry?.key)

        if let motifId = control.motifId, let motif = ManifestCatalog.shared.motifs[motifId] {
            resonMotif = motif.notes
        } else {
            resonMotif = []
        }

        if ProcessInfo.processInfo.environment["TUB_DEBUG_RESONIFIER"] == "1" {
            print("[audio] resonifier mode=\(control.mode) inst=\(instrumentId) chord=\(control.chordSetId) voices=\(Int(1 + floor(control.voiceCap * 7.0)))")
        }
    }

    private func cachedResonInstrument(id: String) -> ResonInstrument {
        if let cached = resonInstrumentCache[id] {
            return cached
        }
        let entry = ManifestCatalog.shared.instruments[id]
        let built = buildResonInstrument(id: id, entry: entry)
        resonInstrumentCache[id] = built
        return built
    }

    private func buildResonInstrument(id: String, entry: InstrumentManifestEntry?) -> ResonInstrument {
        let fallback = ResonInstrument.fallback(id: id)
        guard let entry else { return fallback }

        let tableCount = 2_048
        var table = [Float](repeating: 0, count: tableCount)
        let hash = stableSeed(for: id + (entry.samplePackPath ?? "") + (entry.soundfontPath ?? "") + (entry.samplerPresetRef ?? ""))
        let brightness = max(0.05, min(0.95, 0.25 + (Float((hash >> 8) & 0xFF) / 255.0) * 0.7))
        let gain = powf(10.0, Float((entry.gainDb ?? 0.0) / 20.0))
        let polyphony = max(1, min(16, entry.polyphonyHint ?? entry.polyphony ?? 8))

        let h2 = 0.10 + (0.35 * brightness)
        let h3 = 0.05 + (0.25 * brightness)
        let h4 = 0.02 + (0.15 * brightness)
        let phaseJitter = Float((hash & 0x3FF)) / 1024.0 * Float.pi * 2.0

        for i in 0..<tableCount {
            let ph = 2.0 * Float.pi * Float(i) / Float(tableCount)
            let fundamental = sinf(ph + phaseJitter * 0.05)
            let second = sinf(ph * 2.0 + phaseJitter * 0.21) * h2
            let third = sinf(ph * 3.0 + phaseJitter * 0.37) * h3
            let fourth = sinf(ph * 4.0 + phaseJitter * 0.49) * h4
            table[i] = (fundamental * (0.85 - 0.35 * brightness)) + second + third + fourth
        }
        return ResonInstrument(id: id, wavetable: table, gain: gain, brightness: brightness, polyphonyHint: polyphony)
    }

    private func chordRootMidi(for chordSetId: String, keyHint: String?) -> Int {
        let source = (keyHint ?? chordSetId).lowercased()
        let map: [String: Int] = [
            "c": 60, "c#": 61, "db": 61, "d": 62, "d#": 63, "eb": 63, "e": 64, "f": 65,
            "f#": 66, "gb": 66, "g": 67, "g#": 68, "ab": 68, "a": 69, "a#": 70, "bb": 70, "b": 71,
        ]
        for (name, midi) in map {
            if source.contains(name) {
                return midi
            }
        }
        return 60
    }

    private func updateResonPitchTracker(_ input: Float) {
        resonZeroCrossCount += 1
        if resonPitchPrevInput <= 0, input > 0 {
            let interval = resonZeroCrossCount
            resonZeroCrossCount = 0
            let minI = Int(sampleRate / 800.0)
            let maxI = Int(sampleRate / 70.0)
            if interval >= minI, interval <= maxI {
                let hz = sampleRate / Float(interval)
                let jitter = abs(Float(interval - resonLastCross))
                let confTarget = max(0, min(1, 1.0 - (jitter / max(1, Float(interval)))))
                resonPitchHz += 0.22 * (hz - resonPitchHz)
                resonPitchConf += 0.20 * (confTarget - resonPitchConf)
                resonLastCross = interval
            } else {
                resonPitchConf *= 0.92
            }
        } else {
            resonPitchConf *= 0.999
        }
        resonPitchPrevInput = input
    }

    private func nearestChordMidi(targetMidi: Int, rootMidi: Int, intervals: [Int]) -> Int {
        let safeIntervals = intervals.isEmpty ? [0, 3, 7, 10] : intervals
        var best = rootMidi
        var bestDist = Int.max
        for octave in -2...3 {
            for interval in safeIntervals {
                let candidate = rootMidi + (octave * 12) + interval
                let dist = abs(candidate - targetMidi)
                if dist < bestDist {
                    bestDist = dist
                    best = candidate
                }
            }
        }
        return max(24, min(96, best))
    }

    private func renderResonInstrumentSample(_ instrument: ResonInstrument, phase: Float, inharmonicity: Float) -> Float {
        let table = instrument.wavetable
        guard !table.isEmpty else { return 0 }
        let size = table.count
        let p = phase - floorf(phase)
        let fIndex = p * Float(size)
        let i0 = Int(fIndex) % size
        let i1 = (i0 + 1) % size
        let frac = fIndex - Float(i0)
        let base = table[i0] + frac * (table[i1] - table[i0])
        let extra = sinf((phase * 2.0 * Float.pi * (2.0 + 0.12 * inharmonicity))) * (0.08 * inharmonicity)
        return (base + extra) * instrument.gain
    }

    private func releaseAllResonVoices(fast: Bool) {
        let release = fast ? max(1, Int(sampleRate * 0.03)) : max(1, Int(sampleRate * 0.08))
        for i in 0..<resonVoices.count where resonVoices[i].active {
            resonVoices[i].sustainSamples = min(resonVoices[i].sustainSamples, resonVoices[i].age + 1)
            resonVoices[i].releaseSamples = min(resonVoices[i].releaseSamples, release)
        }
    }

    private func processResonifier(
        input: Float,
        mode: Int,
        cpuAction: CPUGuardAction,
        interventions: inout SafetyInterventions,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float,
        reverbSend: inout Float
    ) {
        if controlCurrent.resetVoices {
            releaseAllResonVoices(fast: true)
            controlCurrent.resetVoices = false
            controlTarget.resetVoices = false
            interventions.insert(.resetVoices)
        }

        if resonSwapRemaining > 0 {
            resonSwapMix = max(0, min(1, resonSwapMix + resonSwapStep))
            resonSwapRemaining -= 1
            if resonSwapRemaining <= 0 {
                resonCurrentInstrument = resonSwapInstrument
                resonSwapMix = 1.0
                resonSwapStep = 0
            }
        }

        updateResonPitchTracker(input)

        resonEnv += 0.004 * (abs(input) - resonEnv)
        let onset = abs(input - resonPrevInput)
        resonPrevInput = input

        let modeVoiceMax = mode == 5 ? 8 : 3
        let requestedVoiceCap: Int
        if mode == 5 {
            requestedVoiceCap = Int(2 + floor(controlCurrent.voiceCap * 6.0))
        } else {
            requestedVoiceCap = Int(1 + floor(controlCurrent.voiceCap * 2.0))
        }
        let effectiveVoiceCap = max(1, min(modeVoiceMax, min(requestedVoiceCap, cpuAction.voiceLimit)))
        if effectiveVoiceCap < requestedVoiceCap {
            interventions.insert(.voiceCap)
        }

        let maxNoteRate: Float = mode == 5 ? 12.0 : 6.0
        let noteRateNorm = Float(controlCurrent.noteRate)
        let noteRateHz: Float = (0.15 + (0.85 * noteRateNorm)) * maxNoteRate
        resonNoteAccumulator += noteRateHz / sampleRate
        let onsetGate = 0.008 + (0.060 * (1.0 - Float(controlCurrent.velocityBias)))
        let eligible = onset > onsetGate || resonEnv > (0.012 + 0.030 * noteRateNorm)
        if eligible && resonNoteAccumulator >= 1.0 {
            resonNoteAccumulator -= floorf(resonNoteAccumulator)
            let openSlot = resonVoices.firstIndex(where: { !$0.active })
            let slot = openSlot ?? resonVoices.indices.min(by: { resonVoices[$0].age > resonVoices[$1].age })
            if let slot {
                if openSlot == nil {
                    interventions.insert(.voiceCap)
                }
                var midiBase = 52 + Int(resonEnv * 24.0)
                if resonPitchConf > 0.35 && controlCurrent.pitchFollow > 0.20 {
                    let follow = Float(controlCurrent.pitchFollow)
                    let detectedMidi = 69.0 + (12.0 * log2(max(30.0, resonPitchHz) / 440.0))
                    let blended = Float(midiBase) * (1.0 - follow) + detectedMidi * follow
                    midiBase = Int(blended.rounded())
                }
                let chordMidi = nearestChordMidi(targetMidi: midiBase, rootMidi: resonRootMidi, intervals: resonChordIntervals)
                var finalMidi = chordMidi
                if !resonMotif.isEmpty {
                    finalMidi += resonMotif[resonMotifStep % resonMotif.count]
                    resonMotifStep = (resonMotifStep + 1) % max(1, resonMotif.count)
                }
                let freqHz = 440.0 * powf(2.0, Float(finalMidi - 69) / 12.0)
                let minLenMs: Float = 60
                let maxLenMs: Float = mode == 5 ? 1_500 : 1_200
                var lenMs = minLenMs + (maxLenMs - minLenMs) * (0.15 + 0.75 * (1.0 - Float(controlCurrent.noteRate)))
                let articulation = controlCurrent.articulationId.lowercased()
                if articulation.contains("short") {
                    lenMs *= 0.55
                } else if articulation.contains("legato") {
                    lenMs *= 1.20
                }
                lenMs = min(maxLenMs, max(minLenMs, lenMs))
                let sustain = max(1, Int((lenMs / 1000.0) * sampleRate))
                let release = max(1, Int((mode == 5 ? 0.11 : 0.09) * sampleRate))
                let velocity = max(0.12, min(1.0, 0.22 + (resonEnv * 2.2 * Float(controlCurrent.velocityBias))))
                let panSpeed = (0.0004 + Float(controlCurrent.motionSpeed) * 0.0024) * (0.8 + 0.4 * randomUnit())
                let panRadius = max(0.20, min(1.0, Float(controlCurrent.spread) * (mode == 5 ? 0.95 : 0.80)))
                resonVoices[slot].reset(
                    midiNote: finalMidi,
                    freqHz: freqHz,
                    sustainSamples: sustain,
                    releaseSamples: release,
                    velocity: velocity,
                    panPhase: randomUnit() * Float.pi * 2.0,
                    panSpeed: panSpeed,
                    panRadius: panRadius,
                    panOffset: randomUnit() * Float.pi * 2.0
                )
            }
        }

        var activeCount = 0
        for i in 0..<resonVoices.count where resonVoices[i].active {
            activeCount += 1
            if activeCount > effectiveVoiceCap {
                resonVoices[i].sustainSamples = min(resonVoices[i].sustainSamples, resonVoices[i].age)
                resonVoices[i].releaseSamples = min(resonVoices[i].releaseSamples, max(1, Int(sampleRate * 0.05)))
                interventions.insert(.voiceCap)
            }

            let phase = resonVoices[i].phase
            let inh = Float(controlCurrent.inharmonicity)
            let currentSample = renderResonInstrumentSample(resonCurrentInstrument, phase: phase, inharmonicity: inh)
            let swapSample = renderResonInstrumentSample(resonSwapInstrument, phase: phase, inharmonicity: inh)
            let instSample = (currentSample * resonSwapMix) + (swapSample * (1.0 - resonSwapMix))

            let attack = max(1, Int(sampleRate * 0.005))
            let env: Float
            if resonVoices[i].age < attack {
                env = Float(resonVoices[i].age) / Float(attack)
            } else if resonVoices[i].age < resonVoices[i].sustainSamples {
                env = 1.0
            } else {
                let relAge = resonVoices[i].age - resonVoices[i].sustainSamples
                env = max(0, 1.0 - (Float(relAge) / Float(max(1, resonVoices[i].releaseSamples))))
            }

            let voiceOut = instSample * env * resonVoices[i].velocity
            resonVoices[i].panPhase += resonVoices[i].panSpeed
            let x = resonVoices[i].panRadius * cosf(resonVoices[i].panPhase + resonVoices[i].panOffset)
            let y = resonVoices[i].panRadius * sinf((resonVoices[i].panPhase * 0.85) + resonVoices[i].panOffset * 0.6)
            GridSpatializer.fillNormalizedPointGains(
                x: x,
                y: y,
                spread: max(0.25, min(1.0, Float(controlCurrent.spread))),
                into: &targetGains
            )
            applyGains(voiceOut * Float(controlCurrent.wetLevel), gains: targetGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)
            reverbSend += voiceOut * (mode == 5 ? 0.18 : 0.12)

            resonVoices[i].phase += resonVoices[i].freqHz / sampleRate
            resonVoices[i].phase -= floorf(resonVoices[i].phase)
            resonVoices[i].age += 1
            if env <= 0.0001 || resonVoices[i].age > (resonVoices[i].sustainSamples + resonVoices[i].releaseSamples) {
                resonVoices[i].active = false
            }
        }

        resonDebugCounter += 1
    }

    private func mode7MappedDest(_ src: Int, mappingId: String) -> Int {
        switch mappingId {
        case "invert_diagonal":
            return 7 - src
        case "octave_flip":
            return (src + 4) % 8
        default:
            return (src ^ 1) % 8
        }
    }

    private func mode7Noise(seed: Int, src: Int, dst: Int) -> Float {
        let x = Float((seed &* 31) ^ (src &* 131) ^ (dst &* 521))
        let n = sinf(x * 12.9898 + 78.233) * 43758.5453
        return n - floorf(n)
    }

    private func setMode7TargetMatrix(mappingId: String, bias: Float, varianceAmt: Float, seed: Int) {
        let mId = mappingId.isEmpty ? "swap_pairs" : mappingId
        mode7MappingIdCurrent = mId
        let clampedBias = max(0, min(1, bias))
        let varAmt = max(0, min(1, varianceAmt))
        for src in 0..<8 {
            var rowSum: Float = 0
            let p = mode7MappedDest(src, mappingId: mId)
            let s = (p + 1) % 8
            for dst in 0..<8 {
                var w: Float = 0
                if dst == p {
                    w = 0.70 + 0.22 * clampedBias
                } else if dst == s {
                    w = 0.14 + 0.10 * (1.0 - clampedBias)
                } else {
                    w = 0.01 * varAmt * mode7Noise(seed: seed, src: src, dst: dst)
                }
                mode7MatrixTarget[src * 8 + dst] = w
                rowSum += w
            }
            let norm = rowSum > 1e-6 ? 1.0 / rowSum : 1.0
            for dst in 0..<8 {
                mode7MatrixTarget[src * 8 + dst] *= norm
            }
        }
        mode7MorphPhase = 0
    }

    private func processMode7(input: Float) -> Float {
        // Build 8 bands from cascaded low-pass outputs.
        for i in 0..<mode7CrossFreqs.count {
            let a = onePoleAlpha(cutoffHz: mode7CrossFreqs[i], sampleRate: sampleRate)
            mode7LPStates[i] += a * (input - mode7LPStates[i])
        }
        mode7BandScratch[0] = mode7LPStates[0]
        for i in 1..<7 {
            mode7BandScratch[i] = mode7LPStates[i] - mode7LPStates[i - 1]
        }
        mode7BandScratch[7] = input - mode7LPStates[6]

        // Matrix-space morph.
        let morph = 0.00003 + (0.0018 * Float(controlCurrent.morphRate))
        for i in 0..<64 {
            mode7MatrixCurrent[i] += morph * (mode7MatrixTarget[i] - mode7MatrixCurrent[i])
        }

        for dst in 0..<8 {
            var acc: Float = 0
            for src in 0..<8 {
                acc += mode7BandScratch[src] * mode7MatrixCurrent[src * 8 + dst]
            }
            mode7MappedScratch[dst] = acc
        }

        let bias = Float(controlCurrent.bias)
        var wet: Float = 0
        for i in 0..<8 {
            let bandPos = Float(i) / 7.0
            let weight = 0.55 + (0.70 * ((1.0 - bias) * (1.0 - bandPos) + bias * bandPos))
            wet += mode7MappedScratch[i] * weight
        }

        let targetNorm = min(1.8, max(0.35, 0.22 / max(0.02, abs(wet))))
        mode7LoudnessNorm += 0.0015 * (targetNorm - mode7LoudnessNorm)
        wet *= mode7LoudnessNorm

        let cutoff = 2_200.0 + 6_000.0 * (1.0 - Float(controlCurrent.sharpness) * 0.65)
        let alpha = onePoleAlpha(cutoffHz: cutoff, sampleRate: sampleRate)
        mode7HfClampY += alpha * (wet - mode7HfClampY)
        return mode7HfClampY
    }

    private func processGranulator(input: Float, cpuAction: CPUGuardAction, interventions: inout SafetyInterventions) -> Float {
        granBuffer[granWrite] = input
        granWrite += 1
        if granWrite >= granBuffer.count { granWrite = 0 }

        let density = Float(controlCurrent.grainDensity) * cpuAction.densityScale
        if cpuAction.active {
            interventions.insert(.densityCap)
        }

        let spawnRateHz = 2.0 + density * 45.0
        let interval = max(1, Int(sampleRate / spawnRateHz))
        if grainSpawnCounter <= 0 {
            let voiceLimit = min(grains.count, cpuAction.voiceLimit)
            var spawned = false
            for i in 0..<voiceLimit where !grains[i].active {
                let lenMs = 18.0 + 190.0 * Float(controlCurrent.grainSize)
                let len = max(16, Int((lenMs / 1000.0) * sampleRate))
                let offset = randomUnit() * min(Float(granBuffer.count - 1), sampleRate * 0.65)
                var position = Float(granWrite) - offset
                while position < 0 { position += Float(granBuffer.count) }
                grains[i].reset(position: position, length: len, gain: 0.45 + 0.45 * randomUnit())
                spawned = true
                break
            }
            if !spawned && cpuAction.active {
                interventions.insert(.voiceCap)
            }
            grainSpawnCounter = interval
        } else {
            grainSpawnCounter -= 1
        }

        if freezeSamplesRemaining > 0 {
            freezeSamplesRemaining -= 1
        } else {
            if randomUnit() < Float(controlCurrent.freezeProb) * 0.0025 {
                let freezeLen = max(0.05, min(6.0, Float(controlCurrent.freezeLenSec)))
                freezeSamplesRemaining = Int(freezeLen * sampleRate)
            } else {
                let step = 0.20 + 2.8 * Float(controlCurrent.scanRate)
                granReadHead += step
                if randomUnit() < Float(controlCurrent.scanJumpProb) * 0.0015 {
                    granReadHead += (randomUnit() - 0.5) * sampleRate * 0.25
                }
                while granReadHead < 0 { granReadHead += Float(granBuffer.count) }
                while granReadHead >= Float(granBuffer.count) { granReadHead -= Float(granBuffer.count) }
            }
        }

        var out: Float = 0
        for i in 0..<grains.count where grains[i].active {
            let idx = Int(grains[i].position) % granBuffer.count
            let sample = granBuffer[idx]
            let t = Float(grains[i].age) / Float(max(1, grains[i].length))
            let env = 0.5 - 0.5 * cosf(2.0 * .pi * min(max(t, 0), 1))
            out += sample * env * grains[i].gain

            grains[i].position += 1.0
            if grains[i].position >= Float(granBuffer.count) {
                grains[i].position -= Float(granBuffer.count)
            }
            grains[i].age += 1
            if grains[i].age >= grains[i].length {
                grains[i].active = false
            }
        }
        return out * 0.6
    }

    private func processResonator(input: Float) -> Float {
        let excite = input * Float(controlCurrent.exciteAmount)
        let resonance = 0.78 + 0.20 * Float(controlCurrent.resonance)
        let profile = resonatorProfileFreqs(controlCurrent.resonatorTuningProfileId)

        var sum: Float = 0
        for i in 0..<profile.count {
            let w = 2.0 * Float.pi * profile[i] / sampleRate
            let a = 2.0 * resonance * cosf(w)
            let b = resonance * resonance
            let y = excite + a * resonY1[i] - b * resonY2[i]
            resonY2[i] = resonY1[i]
            resonY1[i] = y
            sum += y
        }
        let profileCount = Float(max(1, profile.count))
        let normalized = sum / profileCount
        let driveGain = 1.0 + 1.35 * Float(controlCurrent.drive)
        let driven = tanhf(normalized * driveGain)
        return driven * (0.80 + 0.20 * Float(controlCurrent.resonance))
    }

    private func processBitReduction(input: Float) -> Float {
        let bitDepthControl = Float(controlCurrent.bitDepth)
        let bits = max(8, min(24, Int((8.0 + (bitDepthControl * 8.0)).rounded())))
        let bitDepthNorm = (Float(bits) - 8.0) / 16.0
        let quantLevels = Float(1 << bits)
        let q = roundf(input * quantLevels) / quantLevels

        let downNorm = Float(controlCurrent.downsample)
        let holdN = max(1, Int(1 + downNorm * 4.0))
        if downsampleCounter <= 0 {
            downsampleHold = q
            downsampleCounter = holdN
        } else {
            downsampleCounter -= 1
        }
        let crushMix = min(0.45, 0.10 + 0.55 * downNorm + 0.30 * (1.0 - bitDepthNorm))
        return input * (1.0 - crushMix) + downsampleHold * crushMix
    }

    private func processWetHFClamp(input: Float) -> Float {
        let cutoff = 3_000.0 + (7_000.0 * Float(1.0 - controlCurrent.resonance * 0.7))
        let alpha = onePoleAlpha(cutoffHz: Float(cutoff), sampleRate: sampleRate)
        wetClampY += alpha * (input - wetClampY)
        return wetClampY
    }

    private func processMode9(
        input: Float,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float,
        reverbSend: inout Float
    ) {
        let lowA = onePoleAlpha(cutoffHz: 220, sampleRate: sampleRate)
        lowLP += lowA * (input - lowLP)
        let highA = hpfAlpha(fc: 1_900, sampleRate: sampleRate)
        highHP = highA * (highHP + input - highPrevX)
        highPrevX = input
        let mid = input - lowLP - highHP

        let lowBand = lowLP * Float(controlCurrent.bandLowLevel)
        let midBand = mid * Float(controlCurrent.bandMidLevel)
        let highBand = highHP * Float(controlCurrent.bandHighLevel)

        let spread = Float(controlCurrent.spread)
        let speed = Float(controlCurrent.bandMotionSpeed)
        bandMotionPhase += (speed * 0.00055) + 0.00005

        let lx = -0.65 + 0.25 * sinf(bandMotionPhase * 0.7)
        let ly = -0.55 + 0.22 * cosf(bandMotionPhase * 0.6)
        GridSpatializer.fillNormalizedPointGains(x: lx, y: ly, spread: max(0.65, spread), into: &targetGains)
        smoothGains(current: &lowGains, target: targetGains)
        applyGains(lowBand, gains: lowGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)

        let mx = 0.20 * sinf(bandMotionPhase * 0.9)
        let my = 0.20 * cosf(bandMotionPhase * 0.8)
        GridSpatializer.fillNormalizedPointGains(x: mx, y: my, spread: max(0.72, spread), into: &targetGains)
        smoothGains(current: &midGains, target: targetGains)
        applyGains(midBand, gains: midGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)

        let hx = 0.65 + 0.30 * cosf(bandMotionPhase * 1.3)
        let hy = 0.55 + 0.25 * sinf(bandMotionPhase * 1.6)
        GridSpatializer.fillNormalizedPointGains(x: hx, y: hy, spread: max(0.80, spread), into: &targetGains)
        smoothGains(current: &highGains, target: targetGains)
        applyGains(highBand, gains: highGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)

        reverbSend = (0.18 * lowBand) + (0.20 * midBand) + (0.22 * highBand)
    }

    private func placeMainObject(
        sample: Float,
        spread: Float,
        motionSpeed: Float,
        radius: Float,
        mode: Int,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float
    ) {
        let r = max(0.05, min(1.0, radius))
        let s = max(0.05, min(1.0, spread))
        motionPhase += (0.00020 + 0.0012 * max(0, motionSpeed))

        let pos: SIMD2<Float>
        switch controlCurrent.spatialMotion {
        case .static:
            pos = SIMD2<Float>(0, 0)
        case .drift:
            pos = SIMD2<Float>(
                r * 0.55 * sinf(motionPhase * 0.35),
                r * 0.35 * cosf(motionPhase * 0.22)
            )
        case .orbit:
            pos = SIMD2<Float>(r * cosf(motionPhase), r * sinf(motionPhase))
        case .fragment:
            pos = SIMD2<Float>(
                r * sinf(motionPhase * 1.8) * cosf(motionPhase * 0.7),
                r * cosf(motionPhase * 2.3)
            )
        case .orbitPulse:
            let pulse = 0.65 + 0.35 * sinf(motionPhase * 0.8)
            pos = SIMD2<Float>(r * pulse * cosf(motionPhase), r * pulse * sinf(motionPhase))
        case .jumpCut:
            let x = sinf(motionPhase * 6.7 + 2.1)
            let y = cosf(motionPhase * 5.9 + 1.2)
            pos = SIMD2<Float>(r * x, r * y)
        case .clusterRotate:
            let c = SIMD2<Float>(0.45 * cosf(motionPhase * 0.6), 0.45 * sinf(motionPhase * 0.6))
            pos = SIMD2<Float>(c.x + 0.22 * cosf(motionPhase * 2.1), c.y + 0.22 * sinf(motionPhase * 2.1))
        }

        GridSpatializer.fillNormalizedPointGains(x: pos.x, y: pos.y, spread: s, into: &targetGains)
        smoothGains(current: &mainGains, target: targetGains)
        applyGains(sample, gains: mainGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)

        if mode == 0 {
            // keep mode 0 minimally moving by damping accumulated phase.
            motionPhase *= 0.9995
        }
    }

    private func applyGains(
        _ sample: Float,
        gains: [Float],
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float
    ) {
        ch0 += sample * gains[0]
        ch1 += sample * gains[1]
        ch2 += sample * gains[2]
        ch3 += sample * gains[3]
        ch4 += sample * gains[4]
        ch5 += sample * gains[5]
    }

    private func smoothGains(current: inout [Float], target: [Float]) {
        for i in 0..<6 {
            current[i] += gainSlew * (target[i] - current[i])
        }
    }

    private func resonatorProfileFreqs(_ id: String) -> [Float] {
        let lower = id.lowercased()
        if lower.contains("metal") {
            return [210, 310, 470, 820, 1_270, 1_960]
        }
        if lower.contains("body") {
            return [110, 190, 320, 620, 910, 1_430]
        }
        return [140, 260, 430, 680, 1_040, 1_620]
    }

    private func randomUnit() -> Float {
        grainRng &+= 0x9E3779B97F4A7C15
        var z = grainRng
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(Double(z & 0xFFFF_FFFF) / Double(UInt32.max))
    }

    private func hardClip(_ x: Float) -> Float {
        max(-0.98, min(0.98, x))
    }

    private func max6(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ e: Float, _ f: Float) -> Float {
        max(max(max(a, b), max(c, d)), max(e, f))
    }

    private func onePoleAlpha(cutoffHz: Float, sampleRate: Float) -> Float {
        let c = max(10, min(cutoffHz, sampleRate * 0.45))
        let x = expf(-2.0 * .pi * c / max(8_000, sampleRate))
        return 1.0 - x
    }

    private func hpfAlpha(fc: Float, sampleRate: Float) -> Float {
        let c = max(10, min(fc, sampleRate * 0.45))
        let rc = 1.0 / (2.0 * .pi * c)
        let dt = 1.0 / max(8_000, sampleRate)
        return rc / (rc + dt)
    }
}

private extension NSLock {
    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

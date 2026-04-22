//
//  AudioEngineController.swift
//  TheTubHarness
//
//  Input-driven master graph with safety rails for modes 0/1/2/3/4/5/6/7/8/9.
//

import Foundation
import AVFoundation
import AudioToolbox
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
    private let destinationMixer: AVAudioMixerNode
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let onBuffer: (AVAudioPCMBuffer, AVAudioTime?) -> Void
    private var audioFile: AVAudioFile?
    private var seekOffsetSeconds: Double = 0

    init(engine: AVAudioEngine, destinationMixer: AVAudioMixerNode, onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime?) -> Void) {
        self.engine = engine
        self.destinationMixer = destinationMixer
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
        engine.connect(mixer, to: destinationMixer, format: file.processingFormat)

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

struct OutputRouteInfo: Equatable {
    var outputUID: String
    var outputName: String
    var hardwareChannels: Int
    var activeMode: OutputRouteMode
    var routeLocked: Bool
    var warning: String?
    var mappingSummary: String
}

struct OutputRenderDiagnostics: Equatable {
    var driverCallbackActive: Bool = false
    var driverCallbackCount: UInt64 = 0
    var callbackActive: Bool = false
    var frameCount: Int = 0
    var bufferCount: Int = 0
    var slotCount: Int = 0
    var configuredHardwareChannels: Int = 0
    var preRoutePeak: Float = 0
    var postRoutePeak: Float = 0
}

struct SirenTrackClip: Equatable {
    let id: String
    let sampleRate: Float
    let samples: [Float]
}

private struct OutputRenderDiagnosticsSnapshot {
    var callbackCounter: UInt64 = 0
    var frameCount: Int = 0
    var bufferCount: Int = 0
    var slotCount: Int = 0
    var configuredHardwareChannels: Int = 0
    var preRoutePeak: Float = 0
    var postRoutePeak: Float = 0
}

nonisolated private final class CoreAudioLiveOutputDriver {
    typealias RenderBlock = (AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> Void
    typealias InputBlock = (Int, UnsafePointer<AudioBufferList>) -> Void

    private var audioUnit: AudioUnit?
    private var renderBlock: RenderBlock?
    private var inputBlock: InputBlock?
    private var inputCaptureBuffer: AVAudioPCMBuffer?
    private var inputCaptureChannelCount: Int = 0
    private var inputSampleRate: Double = 48_000
    private let callbackLock = NSLock()
    private var callbackCounter: UInt64 = 0
    private var lastFrameCount: Int = 0

    deinit {
        stop()
    }

    func start(
        outputUID: String,
        sampleRate: Double,
        channels: Int,
        inputBlock: InputBlock? = nil,
        renderBlock: @escaping RenderBlock
    ) throws {
        stop()
        guard !outputUID.isEmpty, let resolvedDeviceID = CoreAudioOutputCatalog.deviceID(forUID: outputUID) else {
            throw NSError(domain: "AudioOutputDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output device not found"])
        }

        self.renderBlock = renderBlock
        self.inputBlock = inputBlock
        self.inputSampleRate = sampleRate
        self.inputCaptureChannelCount = inputBlock == nil ? 0 : max(1, CoreAudioInputCatalog.inputChannels(forUID: outputUID) ?? channels)
        if let inputBlock {
            let captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(inputCaptureChannelCount),
                interleaved: false
            )
            guard let captureFormat,
                  let captureBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 4096) else {
                self.inputBlock = nil
                throw NSError(domain: "AudioOutputDriver", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate input capture buffer for shared device"])
            }
            self.inputCaptureBuffer = captureBuffer
            self.inputBlock = inputBlock
        }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            stop()
            throw NSError(domain: "AudioOutputDriver", code: 2, userInfo: [NSLocalizedDescriptionKey: "HAL output component unavailable"])
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create HAL output unit (OSStatus \(status))"])
        }
        audioUnit = unit

        var enableOutput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to enable HAL output (OSStatus \(status))"])
        }

        if inputBlock != nil {
            var enableInput: UInt32 = 1
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else {
                stop()
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to enable HAL input (OSStatus \(status))"])
            }
        }

        var selectedDevice = resolvedDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to bind HAL device (OSStatus \(status))"])
        }

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &outputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to set HAL output format (OSStatus \(status))"])
        }

        if inputBlock != nil {
            var inputFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(inputCaptureChannelCount),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &inputFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else {
                stop()
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to set HAL input format (OSStatus \(status))"])
            }
        }

        var callback = AURenderCallbackStruct(
            inputProc: coreAudioLiveOutputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to install HAL render callback (OSStatus \(status))"])
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to initialize HAL output unit (OSStatus \(status))"])
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to start HAL output unit (OSStatus \(status))"])
        }
    }

    func stop() {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        self.audioUnit = nil
        inputBlock = nil
        renderBlock = nil
        inputCaptureBuffer = nil
        inputCaptureChannelCount = 0
        callbackLock.lock()
        callbackCounter = 0
        lastFrameCount = 0
        callbackLock.unlock()
    }

    func callbackSnapshot() -> (count: UInt64, frameCount: Int) {
        callbackLock.lock()
        let snapshot = (callbackCounter, lastFrameCount)
        callbackLock.unlock()
        return snapshot
    }

    fileprivate func render(
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first else { return noErr }
        let bytesPerFrame = max(Int(MemoryLayout<Float>.size), Int(MemoryLayout<Float>.size) * max(1, Int(first.mNumberChannels)))
        let derivedFrameCount = Int(first.mDataByteSize) / max(1, bytesPerFrame)
        let frames = max(Int(frameCount), derivedFrameCount)
        guard frames > 0 else { return noErr }
        callbackLock.lock()
        callbackCounter &+= 1
        lastFrameCount = frames
        callbackLock.unlock()

        if let inputBlock,
           let audioUnit,
           let inputCaptureBuffer,
           inputCaptureChannelCount > 0,
           frames <= inputCaptureBuffer.frameCapacity {
            inputCaptureBuffer.frameLength = AVAudioFrameCount(frames)
            var actionFlags = AudioUnitRenderActionFlags()
            let status = AudioUnitRender(
                audioUnit,
                &actionFlags,
                timeStamp,
                1,
                UInt32(frames),
                inputCaptureBuffer.mutableAudioBufferList
            )
            if status == noErr {
                inputBlock(frames, UnsafePointer(inputCaptureBuffer.mutableAudioBufferList))
            }
        }

        renderBlock?(AVAudioFrameCount(frames), ioData)
        return noErr
    }
}

nonisolated private let coreAudioLiveOutputRenderCallback: AURenderCallback = { inRefCon, _, inTimeStamp, _, inNumberFrames, ioData in
    let driver = Unmanaged<CoreAudioLiveOutputDriver>.fromOpaque(inRefCon).takeUnretainedValue()
    return driver.render(timeStamp: inTimeStamp, frameCount: inNumberFrames, ioData: ioData)
}

final class AudioEngineController: ObservableObject {
    private static let preferredHardwareSampleRate: Double = 44_100
    private static let callbackActivityHoldNs: UInt64 = 1_000_000_000

    private let engine = AVAudioEngine()
    private let outputMixer = AVAudioMixerNode()
    private let liveOutputDriver = CoreAudioLiveOutputDriver()
    private let deviceRefreshQueue = DispatchQueue(label: "tub.audio.output.devices", qos: .userInitiated)
    private var sourceNode: AVAudioSourceNode?
    private let renderState = MasterRenderState()
    private var preferredInputUID: String?
    private var preferredOutputUID: String?
    private var outputProfilesByUID: [String: OutputRoutingProfile] = [:]
    private var inputProfilesByUID: [String: InputRoutingProfile] = [:]
    private var activeOutputRoute = OutputRouteInfo(
        outputUID: "",
        outputName: "System Default",
        hardwareChannels: 2,
        activeMode: .stereoFallback,
        routeLocked: false,
        warning: "output_uninitialized",
        mappingSummary: "1->1,2->2,3->1,4->2,5->1,6->2"
    )
    private var activeInputRoute = InputRouteInfo(
        inputUID: "",
        inputName: "System Default",
        inputChannels: 0,
        activeCount: 0,
        activeSummary: "none",
        warning: "input_route_uninitialized"
    )
    private var recorder: AudioRecorder?
    private var replayInput: ReplayAudioInput?
    private var inputSource: FrameInputSource = .live
    private var replayRestoreLiveInputOnStop: Bool = false
    private let liveInputInfoLock = NSLock()
    private var liveInputSampleRate: Double = 48_000
    private var liveInputChannels: Int = 1
    private var usesEngineLiveInputTap: Bool = false

    @Published var isAudioRunning: Bool = false
    @Published var audioError: String?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedOutputUID: String = ""
    @Published private(set) var activeOutputName: String = "System Default"
    @Published private(set) var activeOutputChannels: Int = 2
    @Published private(set) var outputRouteMode: OutputRouteMode = .stereoFallback
    @Published private(set) var outputRouteWarning: String?
    @Published private(set) var outputRouteLocked: Bool = false
    @Published private(set) var isOutputTestRunning: Bool = false
    @Published private(set) var outputHardwareLevels: [Float] = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
    @Published private(set) var outputProfile: OutputRoutingProfile = OutputRoutingProfile.defaultProfile(for: "default", hardwareChannels: 2)
    @Published private(set) var outputRenderDiagnostics: OutputRenderDiagnostics = OutputRenderDiagnostics()
    @Published private(set) var inputRouteWarning: String?
    @Published private(set) var inputRouteProfile: InputRoutingProfile = InputRoutingProfile.defaultProfile(for: "default", inputChannels: 1)
    @Published private(set) var sirenStatus: SirenSongStatus = .bypass
    @Published private(set) var sirenPlaylistReady: Bool = false
    @Published private(set) var sirenTrackCount: Int = 0
    @Published private(set) var externalLiveInputGainTarget: Double = 1.0

    private var outputMeterPollTimer: DispatchSourceTimer?
    private var outputRefreshGeneration: UInt64 = 0
    private static let performanceFrontPairTrimDb: Double = -5.0

    var onInputRecordingAlignment: ((InputAudioAlignment) -> Void)?
    var onLiveInputBufferCaptured: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?

    init() {
        let store = OutputRoutingPersistence.loadState()
        preferredOutputUID = store.selectedOutputUID
        outputProfilesByUID = store.profilesByUID

        let inputStore = InputRoutingPersistence.loadState()
        preferredInputUID = inputStore.selectedInputUID
        inputProfilesByUID = inputStore.profilesByUID
        engine.attach(outputMixer)
        refreshOutputDevices()
        refreshInputRouteState()
        startOutputMeterPolling()
    }

    deinit {
        outputMeterPollTimer?.cancel()
        liveOutputDriver.stop()
    }

    func start(useEngineLiveInputTap: Bool = false) {
        start(useLiveInputSource: true, useEngineLiveInputTap: useEngineLiveInputTap)
    }

    func startReplayEngineIfNeeded() {
        if isAudioRunning {
            inputSource = .replayFile
            return
        }
        start(useLiveInputSource: false, useEngineLiveInputTap: false)
    }

    private func start(useLiveInputSource: Bool, useEngineLiveInputTap: Bool) {
        if isAudioRunning { return }

        let targetUID = preferredOutputUID ?? CoreAudioOutputCatalog.defaultOutputUID() ?? ""
        var bindSucceeded = true
        if !useLiveInputSource && !targetUID.isEmpty {
            do {
                try CoreAudioOutputCatalog.setCurrentOutputDevice(on: engine.outputNode, uid: targetUID)
            } catch {
                bindSucceeded = false
                audioError = "output select failed: \(error.localizedDescription)"
            }
        }

        let activeUID = !targetUID.isEmpty ? targetUID : (CoreAudioOutputCatalog.defaultOutputUID() ?? "")
        let activeName = CoreAudioOutputCatalog.deviceName(forUID: activeUID) ?? CoreAudioOutputCatalog.defaultOutputName() ?? "System Default"
        let catalogChannels = max(1, CoreAudioOutputCatalog.outputChannels(forUID: activeUID) ?? CoreAudioOutputCatalog.defaultOutputChannelCount())
        let sampleRateEnforcement = CoreAudioOutputCatalog.enforceNominalSampleRate(
            forUID: activeUID,
            preferred: Self.preferredHardwareSampleRate
        )
        let sampleRate = max(
            8_000,
            CoreAudioOutputCatalog.nominalSampleRate(forUID: activeUID)
                ?? sampleRateEnforcement.actual
                ?? Self.preferredHardwareSampleRate
        )
        let outputChannels = max(1, catalogChannels)

        var profile = profileForOutputUID(activeUID, hardwareChannels: outputChannels)
        profile.sanitize(for: outputChannels)
        outputProfilesByUID[activeUID] = profile
        let routeDecision = OutputRoutePlanner.decide(
            preferredMode: profile.preferredMode,
            hardwareChannels: outputChannels,
            bindSucceeded: bindSucceeded
        )
        let effectiveWarning = mergedOutputRouteWarning(routeWarning: routeDecision.warning, sampleRate: sampleRate)

        renderState.configure(sampleRate: Float(sampleRate), outputChannels: outputChannels)
        renderState.setOutputRouting(
            profile: profile,
            hardwareChannels: outputChannels,
            activeMode: routeDecision.mode,
            outputUID: activeUID,
            outputName: activeName,
            warning: effectiveWarning
        )
        let routeInfo = OutputRouteInfo(
            outputUID: activeUID,
            outputName: activeName,
            hardwareChannels: outputChannels,
            activeMode: routeDecision.mode,
            routeLocked: routeDecision.locked,
            warning: effectiveWarning,
            mappingSummary: profile.mappingSummary()
        )
        activeOutputRoute = routeInfo

        inputSource = useLiveInputSource ? .live : .replayFile
        if useLiveInputSource {
            usesEngineLiveInputTap = false
            let renderState = self.renderState
            do {
                try liveOutputDriver.start(
                    outputUID: activeUID,
                    sampleRate: sampleRate,
                    channels: outputChannels,
                    inputBlock: nil
                ) { frameCount, audioBufferList in
                    renderState.render(frameCount: frameCount, audioBufferList: audioBufferList)
                }
                isAudioRunning = true
                audioError = nil
            } catch {
                liveOutputDriver.stop()
                let fallbackStarted = startEngineOutputGraph(
                    outputUID: activeUID,
                    sampleRate: sampleRate,
                    outputChannels: outputChannels,
                    useEngineLiveInputTap: useEngineLiveInputTap
                )
                if !fallbackStarted {
                    isAudioRunning = false
                    audioError = "output driver start error: \(error.localizedDescription). \(audioError ?? "fallback unavailable")"
                }
            }
        } else {
            _ = startEngineOutputGraph(
                outputUID: activeUID,
                sampleRate: sampleRate,
                outputChannels: outputChannels,
                useEngineLiveInputTap: useEngineLiveInputTap
            )
        }

        preferredOutputUID = activeUID.isEmpty ? preferredOutputUID : activeUID
        persistOutputRoutingStore()
        DispatchQueue.main.async {
            self.selectedOutputUID = activeUID
            self.activeOutputName = activeName
            self.activeOutputChannels = outputChannels
            self.outputRouteMode = routeDecision.mode
            self.outputRouteLocked = routeDecision.locked
            self.outputRouteWarning = effectiveWarning
            self.outputProfile = profile
            self.outputDevices = CoreAudioOutputCatalog.listOutputDevices()
        }
    }

    @discardableResult
    private func startEngineOutputGraph(
        outputUID: String,
        sampleRate: Double,
        outputChannels: Int,
        useEngineLiveInputTap: Bool
    ) -> Bool {
        liveOutputDriver.stop()
        if let sourceNode {
            engine.disconnectNodeInput(sourceNode)
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }

        if !outputUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try CoreAudioOutputCatalog.setCurrentOutputDevice(on: engine.outputNode, uid: outputUID)
            } catch {
                audioError = "output select failed: \(error.localizedDescription)"
            }
        }

        guard let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(outputChannels),
            interleaved: false
        ) else {
            isAudioRunning = false
            audioError = "engine start error: could not create render format (\(outputChannels)ch @ \(Int(sampleRate)) Hz)"
            return false
        }

        let src = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.renderState.render(frameCount: frameCount, audioBufferList: audioBufferList)
            return noErr
        }
        self.sourceNode = src
        engine.attach(src)
        engine.disconnectNodeInput(outputMixer)
        engine.disconnectNodeOutput(outputMixer)
        engine.connect(src, to: outputMixer, format: renderFormat)
        engine.connect(outputMixer, to: engine.outputNode, format: renderFormat)
        outputMixer.outputVolume = 1.0

        self.usesEngineLiveInputTap = useEngineLiveInputTap
        if useEngineLiveInputTap {
            configureLiveInputTap()
        }

        do {
            engine.prepare()
            try engine.start()
            isAudioRunning = true
            audioError = nil
            return true
        } catch {
            isAudioRunning = false
            audioError = "engine start error: \(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        if !isAudioRunning { return }
        _ = stopInputRecording()
        stopReplayInput(restoreLiveInput: false)
        stopOutputTest()
        liveOutputDriver.stop()
        if usesEngineLiveInputTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        isAudioRunning = false
        inputSource = .live
        usesEngineLiveInputTap = false
    }

    func selectInputDevice(uid: String) {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preferredInputUID = uid
        renderState.noteInputRoute(uid: uid)
        applyInputRouteForUID(uid, overrideChannelCount: nil)
        persistInputRoutingStore()
    }

    func refreshInputRouting() {
        refreshInputRouteState()
    }

    func setInputChannelActive(channelIndex index: Int, active: Bool) {
        let uid = preferredInputUID ?? CoreAudioInputCatalog.defaultInputUID() ?? ""
        guard !uid.isEmpty else { return }
        let channels = max(0, CoreAudioInputCatalog.inputChannels(forUID: uid) ?? activeInputRoute.inputChannels)
        guard index >= 0, index < channels else { return }

        var profile = profileForInputUID(uid, inputChannels: channels)
        if index == InputRoutingProfile.primaryChannelIndex {
            profile.activeChannels[index] = true
        } else {
            profile.activeChannels[index] = active
        }
        let warning = profile.sanitize(for: channels)
        inputProfilesByUID[uid] = profile
        applyInputRoutingToRender(profile: profile, uid: uid, name: CoreAudioInputCatalog.deviceName(forUID: uid) ?? CoreAudioInputCatalog.defaultInputName() ?? "System Default", channelCount: channels, warning: warning)
        persistInputRoutingStore()
    }

    func updateInputChannelGain(channelIndex index: Int, gainDb: Double) {
        let uid = preferredInputUID ?? CoreAudioInputCatalog.defaultInputUID() ?? ""
        guard !uid.isEmpty else { return }
        let channels = max(0, CoreAudioInputCatalog.inputChannels(forUID: uid) ?? activeInputRoute.inputChannels)
        guard index >= 0, index < channels else { return }

        var profile = profileForInputUID(uid, inputChannels: channels)
        if index >= profile.channelGainDb.count {
            profile.channelGainDb.append(contentsOf: Array(repeating: 0, count: index - profile.channelGainDb.count + 1))
        }
        profile.channelGainDb[index] = gainDb
        let warning = profile.sanitize(for: channels)
        inputProfilesByUID[uid] = profile
        applyInputRoutingToRender(
            profile: profile,
            uid: uid,
            name: CoreAudioInputCatalog.deviceName(forUID: uid) ?? CoreAudioInputCatalog.defaultInputName() ?? "System Default",
            channelCount: channels,
            warning: warning
        )
        persistInputRoutingStore()
    }

    func resetInputRouteProfileToDefault() {
        let uid = preferredInputUID ?? CoreAudioInputCatalog.defaultInputUID() ?? ""
        guard !uid.isEmpty else { return }
        let channels = max(0, CoreAudioInputCatalog.inputChannels(forUID: uid) ?? activeInputRoute.inputChannels)
        var profile = InputRoutingProfile.defaultProfile(for: uid, inputChannels: channels)
        let warning = profile.sanitize(for: channels)
        inputProfilesByUID[uid] = profile
        applyInputRoutingToRender(profile: profile, uid: uid, name: CoreAudioInputCatalog.deviceName(forUID: uid) ?? CoreAudioInputCatalog.defaultInputName() ?? "System Default", channelCount: channels, warning: warning)
        persistInputRoutingStore()
    }

    func currentInputRouteInfo() -> InputRouteInfo {
        activeInputRoute
    }

    func refreshOutputDevices() {
        outputRefreshGeneration &+= 1
        let refreshGeneration = outputRefreshGeneration

        deviceRefreshQueue.async { [weak self] in
            guard let self else { return }
            let devices = CoreAudioOutputCatalog.listOutputDevices()
            let defaultUID = CoreAudioOutputCatalog.defaultOutputUID()

            DispatchQueue.main.async {
                guard refreshGeneration == self.outputRefreshGeneration else { return }
                self.applyOutputDeviceRefresh(devices: devices, defaultUID: defaultUID)
            }
        }
    }

    func selectOutputDevice(uid: String) {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preferredOutputUID = uid
        refreshOutputDevices()
        if isAudioRunning {
            let useLiveInputTap = inputSource == .live
            let restartWithEngineTap = usesEngineLiveInputTap
            stop()
            start(useLiveInputSource: useLiveInputTap, useEngineLiveInputTap: restartWithEngineTap && useLiveInputTap)
        }
    }

    func setOutputRouteMode(_ mode: OutputRouteMode) {
        let uid = preferredOutputUID ?? selectedOutputUID
        guard !uid.isEmpty else { return }
        var profile = profileForOutputUID(uid, hardwareChannels: max(1, activeOutputChannels))
        profile.preferredMode = mode
        profile.sanitize(for: max(1, activeOutputChannels))
        outputProfilesByUID[uid] = profile
        outputProfile = profile
        persistOutputRoutingStore()
        applyOutputRoutingProfileToRender()
    }

    func resetOutputProfileToDefault() {
        let uid = preferredOutputUID ?? selectedOutputUID
        guard !uid.isEmpty else { return }
        let hw = max(1, activeOutputChannels)
        let profile = OutputRoutingProfile.defaultProfile(for: uid, hardwareChannels: hw)
        outputProfilesByUID[uid] = profile
        outputProfile = profile
        persistOutputRoutingStore()
        applyOutputRoutingProfileToRender()
    }

    /// Enforce a deterministic 6-channel house output profile for performance starts.
    /// This avoids stale persisted trims/mutes from previous machines or sessions.
    func applyDeterministicPerformanceOutputProfile() {
        let uid = preferredOutputUID ?? selectedOutputUID
        guard !uid.isEmpty else { return }
        let hw = max(1, activeOutputChannels)

        var profile = OutputRoutingProfile.defaultProfile(for: uid, hardwareChannels: hw)
        profile.preferredMode = .gallery6Locked
        profile.masterGainDb = min(OutputRoutingProfile.maxMasterGainDb, 3.0)
        for idx in profile.channels.indices {
            profile.channels[idx].hardwareOutput = idx + 1
            profile.channels[idx].gainDb = (idx < 2) ? Self.performanceFrontPairTrimDb : 0
            profile.channels[idx].delayMs = 0
            profile.channels[idx].polarityInverted = false
            profile.channels[idx].muted = false
            profile.channels[idx].solo = false
        }
        profile.sanitize(for: hw)

        outputProfilesByUID[uid] = profile
        outputProfile = profile
        persistOutputRoutingStore()
        applyOutputRoutingProfileToRender()
    }

    func updateOutputProfile(_ mutate: (inout OutputRoutingProfile) -> Void) {
        let uid = preferredOutputUID ?? selectedOutputUID
        guard !uid.isEmpty else { return }
        var profile = profileForOutputUID(uid, hardwareChannels: max(1, activeOutputChannels))
        mutate(&profile)
        profile.sanitize(for: max(1, activeOutputChannels))
        outputProfilesByUID[uid] = profile
        outputProfile = profile
        persistOutputRoutingStore()
        applyOutputRoutingProfileToRender()
    }

    func startOutputPinkNoiseTest(channel: Int?, scanAll: Bool) {
        let target = max(0, min(5, channel ?? 0))
        renderState.setOutputTest(
            active: true,
            channelIndex: target,
            scanAll: scanAll,
            levelDb: outputProfile.testLevelDb
        )
        DispatchQueue.main.async {
            self.isOutputTestRunning = true
        }
    }

    func stopOutputTest() {
        renderState.setOutputTest(active: false, channelIndex: 0, scanAll: false, levelDb: outputProfile.testLevelDb)
        DispatchQueue.main.async {
            self.isOutputTestRunning = false
        }
    }

    func currentOutputRouteInfo() -> OutputRouteInfo {
        activeOutputRoute
    }

    private static let sirenAllowedExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]

    // Known siren-song filenames. Bundled at TheTubHarness/Assets/SirenSong/ in source; Xcode's
    // synchronized folder refs flatten everything into Contents/Resources root, so we also
    // match these names directly at the bundle root.
    private static let sirenKnownStems: Set<String> = [
        "acharia", "trillion", "wet air pad", "xemf", "xither"
    ]

    fileprivate static func bundleSirenSongURLs() -> [URL] {
        guard let resourceRoot = Bundle.main.resourceURL else { return [] }
        let sirenRoot = resourceRoot.appendingPathComponent("Assets/SirenSong", isDirectory: true)
        var urls: [URL] = []

        if let direct = try? FileManager.default.contentsOfDirectory(
            at: sirenRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in direct {
                let ext = url.pathExtension.lowercased()
                if sirenAllowedExtensions.contains(ext) {
                    urls.append(url)
                }
            }
        }

        if !urls.isEmpty {
            return urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard sirenAllowedExtensions.contains(ext) else { continue }
            let path = url.path.lowercased()
            if path.contains("/assets/sirensong/") || path.contains("/sirensong/") {
                urls.append(url)
                continue
            }
            // Flattened-bundle fallback: match by stem against our known siren filenames.
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if sirenKnownStems.contains(stem) {
                urls.append(url)
            }
        }
        return urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func decodeSirenTrack(from url: URL) -> SirenTrackClip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(1, file.length))
        ) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        let invChannels = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var acc: Float = 0
            for ch in 0..<channelCount {
                acc += channels[ch][frame]
            }
            mono[frame] = acc * invChannels
        }
        return SirenTrackClip(id: url.lastPathComponent, sampleRate: Float(format.sampleRate), samples: mono)
    }

    private func refreshInputRouteState() {
        let uid = preferredInputUID ?? CoreAudioInputCatalog.defaultInputUID() ?? ""
        applyInputRouteForUID(uid, overrideChannelCount: nil)
        persistInputRoutingStore()
    }

    private func applyInputRouteForUID(_ uid: String, overrideChannelCount: Int?) {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUID = normalizedUID.isEmpty ? (CoreAudioInputCatalog.defaultInputUID() ?? "") : normalizedUID
        let channelCount = max(0, overrideChannelCount ?? CoreAudioInputCatalog.inputChannels(forUID: resolvedUID) ?? 0)
        let inputName = CoreAudioInputCatalog.deviceName(forUID: resolvedUID) ?? CoreAudioInputCatalog.defaultInputName() ?? "System Default"
        var profile = profileForInputUID(resolvedUID, inputChannels: channelCount)
        let warning = profile.sanitize(for: channelCount)
        inputProfilesByUID[profile.deviceUID] = profile
        applyInputRoutingToRender(profile: profile, uid: resolvedUID, name: inputName, channelCount: channelCount, warning: warning)
    }

    private func profileForInputUID(_ uid: String, inputChannels: Int) -> InputRoutingProfile {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedUID.isEmpty ? "default" : normalizedUID
        var profile = inputProfilesByUID[key] ?? InputRoutingProfile.defaultProfile(for: key, inputChannels: inputChannels)
        profile.deviceUID = key
        _ = profile.sanitize(for: inputChannels)
        inputProfilesByUID[key] = profile
        return profile
    }

    private func applyInputRoutingToRender(profile: InputRoutingProfile, uid: String, name: String, channelCount: Int, warning: String?) {
        renderState.setInputRouting(
            profile: profile,
            inputUID: uid,
            inputName: name,
            channelCount: channelCount,
            warning: warning
        )
        let info = InputRouteInfo(
            inputUID: uid,
            inputName: name,
            inputChannels: channelCount,
            activeCount: profile.activeCount,
            activeSummary: profile.activeSummary(),
            warning: warning
        )
        activeInputRoute = info
        DispatchQueue.main.async {
            self.inputRouteProfile = profile
            self.inputRouteWarning = warning
        }
    }

    private func persistInputRoutingStore() {
        let selected = preferredInputUID ?? activeInputRoute.inputUID
        InputRoutingPersistence.saveState(
            InputRoutingStore(
                selectedInputUID: selected.isEmpty ? nil : selected,
                profilesByUID: inputProfilesByUID
            )
        )
    }

    private func profileForOutputUID(_ uid: String, hardwareChannels: Int) -> OutputRoutingProfile {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedUID.isEmpty ? "default" : normalizedUID
        var profile = outputProfilesByUID[key] ?? OutputRoutingProfile.defaultProfile(for: key, hardwareChannels: hardwareChannels)
        profile.deviceUID = key
        profile.sanitize(for: hardwareChannels)
        if shouldRestoreSixChannelHouseRouting(profile: profile, hardwareChannels: hardwareChannels) {
            profile.preferredMode = .gallery6Locked
            for idx in 0..<min(OutputRoutingProfile.virtualChannelCount, profile.channels.count) {
                profile.channels[idx].hardwareOutput = idx + 1
            }
            profile.sanitize(for: hardwareChannels)
        }
        outputProfilesByUID[key] = profile
        return profile
    }

    private func shouldRestoreSixChannelHouseRouting(profile: OutputRoutingProfile, hardwareChannels: Int) -> Bool {
        guard hardwareChannels >= OutputRoutingProfile.virtualChannelCount else { return false }
        let mapped = profile.channels.prefix(OutputRoutingProfile.virtualChannelCount).map(\.hardwareOutput)
        guard !mapped.isEmpty else { return true }
        let uniqueMapped = Set(mapped)
        let stereoFoldDown = mapped.allSatisfy { $0 <= 2 }
        let missingHouseOutputs = Set(1...OutputRoutingProfile.virtualChannelCount).subtracting(uniqueMapped)
        return stereoFoldDown || !missingHouseOutputs.isEmpty
    }

    private func persistOutputRoutingStore() {
        let selected = preferredOutputUID ?? selectedOutputUID
        OutputRoutingPersistence.saveState(
            OutputRoutingStore(
                selectedOutputUID: selected.isEmpty ? nil : selected,
                profilesByUID: outputProfilesByUID
            )
        )
    }

    private func startOutputMeterPolling() {
        let timerQueue = DispatchQueue(label: "tub.audio.output.meters", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        var lastObservedOutputRenderCallbackCount: UInt64 = 0
        var lastObservedDriverCallbackCount: UInt64 = 0
        var lastRenderCallbackSeenNs: UInt64 = 0
        var lastDriverCallbackSeenNs: UInt64 = 0
        var lastPublishedLevels = outputHardwareLevels
        var lastPublishedDiagnostics = outputRenderDiagnostics

        timer.schedule(deadline: .now() + .milliseconds(180), repeating: .milliseconds(160), leeway: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let levels = self.renderState.consumeOutputHardwareMeterLevels()
            let snapshot = self.renderState.consumeOutputRenderDiagnostics()
            let driverSnapshot = self.liveOutputDriver.callbackSnapshot()
            if snapshot.callbackCounter != lastObservedOutputRenderCallbackCount {
                lastRenderCallbackSeenNs = nowNs
            }
            if driverSnapshot.count != lastObservedDriverCallbackCount {
                lastDriverCallbackSeenNs = nowNs
            }
            let diagnostics = OutputRenderDiagnostics(
                driverCallbackActive: nowNs &- lastDriverCallbackSeenNs <= Self.callbackActivityHoldNs,
                driverCallbackCount: driverSnapshot.count,
                callbackActive: nowNs &- lastRenderCallbackSeenNs <= Self.callbackActivityHoldNs,
                frameCount: snapshot.frameCount,
                bufferCount: snapshot.bufferCount,
                slotCount: snapshot.slotCount,
                configuredHardwareChannels: snapshot.configuredHardwareChannels,
                preRoutePeak: snapshot.preRoutePeak,
                postRoutePeak: snapshot.postRoutePeak
            )
            lastObservedDriverCallbackCount = driverSnapshot.count
            lastObservedOutputRenderCallbackCount = snapshot.callbackCounter

            let levelsChanged = !Self.approximatelyEqual(levels, lastPublishedLevels, tolerance: 0.012)
            let diagnosticsChanged = !Self.diagnosticsMateriallyEqual(diagnostics, lastPublishedDiagnostics)
            guard levelsChanged || diagnosticsChanged else { return }

            lastPublishedLevels = levels
            lastPublishedDiagnostics = diagnostics
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.outputHardwareLevels = levels
                self.outputRenderDiagnostics = diagnostics
            }
        }
        outputMeterPollTimer = timer
        timer.resume()
    }

    private func applyOutputDeviceRefresh(devices: [AudioOutputDevice], defaultUID: String?) {
        let selected = preferredOutputUID ?? defaultUID ?? devices.first?.uid ?? ""
        if let existing = devices.first(where: { $0.uid == selected }) {
            preferredOutputUID = existing.uid
        } else if let first = devices.first {
            preferredOutputUID = first.uid
        } else {
            preferredOutputUID = nil
        }

        let uiSelected = preferredOutputUID ?? selected
        let uiName = devices.first(where: { $0.uid == uiSelected })?.name ?? CoreAudioOutputCatalog.defaultOutputName() ?? "System Default"
        let uiChannels = devices.first(where: { $0.uid == uiSelected })?.outputChannels ?? CoreAudioOutputCatalog.defaultOutputChannelCount()
        let hardwareChannels = max(1, uiChannels)
        let profile = profileForOutputUID(uiSelected, hardwareChannels: hardwareChannels)
        let decision = OutputRoutePlanner.decide(
            preferredMode: profile.preferredMode,
            hardwareChannels: hardwareChannels,
            bindSucceeded: true
        )
        let warning = mergedOutputRouteWarning(
            routeWarning: decision.warning,
            sampleRate: CoreAudioOutputCatalog.nominalSampleRate(forUID: uiSelected) ?? Self.preferredHardwareSampleRate
        )
        renderState.setOutputRouting(
            profile: profile,
            hardwareChannels: hardwareChannels,
            activeMode: decision.mode,
            outputUID: uiSelected,
            outputName: uiName,
            warning: warning
        )
        activeOutputRoute = OutputRouteInfo(
            outputUID: uiSelected,
            outputName: uiName,
            hardwareChannels: hardwareChannels,
            activeMode: decision.mode,
            routeLocked: decision.locked,
            warning: warning,
            mappingSummary: profile.mappingSummary()
        )

        outputDevices = devices
        selectedOutputUID = uiSelected
        activeOutputName = uiName
        activeOutputChannels = hardwareChannels
        outputProfile = profile
        outputRouteMode = decision.mode
        outputRouteLocked = decision.locked
        outputRouteWarning = warning
        persistOutputRoutingStore()
    }

    private static func approximatelyEqual(_ lhs: [Float], _ rhs: [Float], tolerance: Float) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for idx in lhs.indices where abs(lhs[idx] - rhs[idx]) > tolerance {
            return false
        }
        return true
    }

    private static func diagnosticsMateriallyEqual(_ lhs: OutputRenderDiagnostics, _ rhs: OutputRenderDiagnostics) -> Bool {
        let lhsDriverSeen = lhs.driverCallbackCount > 0
        let rhsDriverSeen = rhs.driverCallbackCount > 0
        return lhs.driverCallbackActive == rhs.driverCallbackActive
            && lhsDriverSeen == rhsDriverSeen
            && lhs.callbackActive == rhs.callbackActive
            && lhs.frameCount == rhs.frameCount
            && lhs.bufferCount == rhs.bufferCount
            && lhs.slotCount == rhs.slotCount
            && lhs.configuredHardwareChannels == rhs.configuredHardwareChannels
            && abs(lhs.preRoutePeak - rhs.preRoutePeak) <= 0.012
            && abs(lhs.postRoutePeak - rhs.postRoutePeak) <= 0.012
    }

    private func mergedOutputRouteWarning(routeWarning: String?, sampleRate: Double) -> String? {
        var warnings: [String] = []
        if let routeWarning, !routeWarning.isEmpty {
            warnings.append(routeWarning)
        }
        if abs(sampleRate - Self.preferredHardwareSampleRate) > 1.0 {
            warnings.append("sample_rate_\(Int(sampleRate.rounded()))Hz_expected_44100Hz")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " | ")
    }

    private func applyOutputRoutingProfileToRender() {
        let uid = preferredOutputUID ?? selectedOutputUID
        guard !uid.isEmpty else { return }
        let channels = max(1, activeOutputChannels)
        let profile = profileForOutputUID(uid, hardwareChannels: channels)
        let decision = OutputRoutePlanner.decide(
            preferredMode: profile.preferredMode,
            hardwareChannels: channels,
            bindSucceeded: true
        )
        let warning = mergedOutputRouteWarning(
            routeWarning: decision.warning,
            sampleRate: CoreAudioOutputCatalog.nominalSampleRate(forUID: uid) ?? Self.preferredHardwareSampleRate
        )
        renderState.setOutputRouting(
            profile: profile,
            hardwareChannels: channels,
            activeMode: decision.mode,
            outputUID: uid,
            outputName: activeOutputName,
            warning: warning
        )
        let routeInfo = OutputRouteInfo(
            outputUID: uid,
            outputName: activeOutputName,
            hardwareChannels: channels,
            activeMode: decision.mode,
            routeLocked: decision.locked,
            warning: warning,
            mappingSummary: profile.mappingSummary()
        )
        activeOutputRoute = routeInfo
        DispatchQueue.main.async {
            self.outputProfile = profile
            self.outputRouteMode = decision.mode
            self.outputRouteLocked = decision.locked
            self.outputRouteWarning = warning
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

    @discardableResult
    func loadSirenSongPlaylistFromBundle() -> Int {
        let urls = Self.bundleSirenSongURLs()
        var tracks: [SirenTrackClip] = []
        tracks.reserveCapacity(urls.count)
        for url in urls {
            if let clip = Self.decodeSirenTrack(from: url) {
                tracks.append(clip)
            }
        }
        renderState.setSirenTracks(tracks)
        DispatchQueue.main.async {
            self.sirenTrackCount = tracks.count
            self.sirenPlaylistReady = !tracks.isEmpty
        }
        return tracks.count
    }

    func setSirenSongActive(_ active: Bool, fadeSeconds: Double) {
        let enabled = active && sirenPlaylistReady
        renderState.setSirenPlayback(active: enabled, fadeSeconds: max(0.0, Float(fadeSeconds)))
    }

    func setExternalLiveInputGain(target: Double, rampSeconds: Double) {
        let clamped = min(max(target, 0.0), 1.0)
        renderState.setExternalInputGain(target: Float(clamped), rampSeconds: max(0.0, Float(rampSeconds)))
        DispatchQueue.main.async {
            self.externalLiveInputGainTarget = clamped
        }
    }

    func setPianoTunerDuckActive(
        _ active: Bool,
        duckGain: Double = 0.02,
        fadeDownSeconds: Double = 0.8,
        fadeUpSeconds: Double = 0.25
    ) {
        renderState.setPianoTunerDuck(
            active: active,
            duckGain: Float(min(max(duckGain, 0.0), 1.0)),
            fadeDownSeconds: max(0.0, Float(fadeDownSeconds)),
            fadeUpSeconds: max(0.0, Float(fadeUpSeconds))
        )
    }

    func setSirenStatus(_ status: SirenSongStatus) {
        DispatchQueue.main.async {
            self.sirenStatus = status
        }
    }

    func loadSirenSongPlaylistForTesting(_ tracks: [SirenTrackClip]) {
        renderState.setSirenTracks(tracks)
        self.sirenTrackCount = tracks.count
        self.sirenPlaylistReady = !tracks.isEmpty
    }

    func externalInputGainSnapshotForTesting() -> (current: Double, target: Double) {
        let snapshot = renderState.externalInputGainSnapshot()
        return (current: Double(snapshot.current), target: Double(snapshot.target))
    }

    func sirenPlaybackSnapshotForTesting() -> (trackCount: Int, activeTarget: Bool, gainCurrent: Double, gainTarget: Double) {
        let snapshot = renderState.sirenPlaybackSnapshot()
        return (
            trackCount: snapshot.trackCount,
            activeTarget: snapshot.activeTarget,
            gainCurrent: Double(snapshot.gainCurrent),
            gainTarget: Double(snapshot.gainTarget)
        )
    }

    func pianoTunerDuckSnapshotForTesting() -> (activeTarget: Bool, current: Double, target: Double) {
        let snapshot = renderState.pianoTunerDuckSnapshot()
        return (
            activeTarget: snapshot.activeTarget,
            current: Double(snapshot.current),
            target: Double(snapshot.target)
        )
    }

    func advanceRenderAutomationForTesting(frames: Int) {
        renderState.advanceAutomationOnly(frames: frames)
    }

    func snapshotSafetyInterventions() -> [String] {
        var interventions = renderState.snapshotInterventions()
        interventions.append("input_uid:\(activeInputRoute.inputUID.isEmpty ? "default" : activeInputRoute.inputUID)")
        interventions.append("input_name:\(activeInputRoute.inputName)")
        interventions.append("input_channels:\(activeInputRoute.inputChannels)")
        interventions.append("input_active:\(activeInputRoute.activeSummary)")
        if let warning = activeInputRoute.warning, !warning.isEmpty {
            interventions.append(warning)
        }
        interventions.append("output_uid:\(activeOutputRoute.outputUID.isEmpty ? "default" : activeOutputRoute.outputUID)")
        interventions.append("output_name:\(activeOutputRoute.outputName)")
        interventions.append("output_channels:\(activeOutputRoute.hardwareChannels)")
        interventions.append("output_mode:\(activeOutputRoute.activeMode.rawValue)")
        if activeOutputRoute.routeLocked {
            interventions.append("output_route_locked")
        }
        if let warning = activeOutputRoute.warning, !warning.isEmpty {
            interventions.append(warning)
        }
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
        liveInputInfoLock.lock()
        let sampleRate = max(8_000, liveInputSampleRate)
        let channels = max(1, liveInputChannels > 0 ? liveInputChannels : activeInputRoute.inputChannels)
        liveInputInfoLock.unlock()
        return (sampleRate: sampleRate, channels: channels, format: "caf")
    }

    func updateLiveInputCaptureInfo(sampleRate: Double, channels: Int) {
        liveInputInfoLock.lock()
        liveInputSampleRate = max(8_000, sampleRate)
        liveInputChannels = max(1, channels)
        liveInputInfoLock.unlock()
    }

    func ingestLiveInputBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        guard inputSource == .live else { return }
        updateLiveInputCaptureInfo(
            sampleRate: buffer.format.sampleRate,
            channels: Int(buffer.format.channelCount)
        )
        renderState.ingestInput(buffer: buffer)
        recorder?.append(buffer: buffer, time: time)
    }

    func ingestLiveInputAudioBuffers(_ audioBufferList: UnsafePointer<AudioBufferList>, frameCount: Int, sampleRate: Double) {
        guard inputSource == .live else { return }
        let binding = RawInputChannelBinding(audioBuffers: audioBufferList)
        updateLiveInputCaptureInfo(
            sampleRate: sampleRate,
            channels: max(1, binding.channelCount)
        )
        renderState.ingestInput(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: Float(sampleRate))
    }

    func startInputRecording(to url: URL, fileFormat: String = "caf") throws -> (sampleRate: Double, channels: Int, format: String) {
        guard isAudioRunning else {
            throw NSError(domain: "AudioEngineController", code: 20, userInfo: [NSLocalizedDescriptionKey: "audio engine is not running"])
        }
        guard inputSource == .live else {
            throw NSError(domain: "AudioEngineController", code: 21, userInfo: [NSLocalizedDescriptionKey: "input recording only supports live input source"])
        }
        _ = stopInputRecording()

        let capture = currentInputCaptureInfo()
        guard capture.sampleRate > 0, capture.channels > 0 else {
            throw NSError(domain: "AudioEngineController", code: 23, userInfo: [NSLocalizedDescriptionKey: "live input format unavailable"])
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: capture.sampleRate,
            channels: AVAudioChannelCount(capture.channels)
        ) else {
            throw NSError(domain: "AudioEngineController", code: 24, userInfo: [NSLocalizedDescriptionKey: "invalid live input format"])
        }
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
        let hadLiveInput = isAudioRunning && inputSource == .live
        if !isAudioRunning {
            startReplayEngineIfNeeded()
        }
        _ = stopInputRecording()
        replayRestoreLiveInputOnStop = hadLiveInput

        inputSource = .replayFile

        if replayInput == nil {
            replayInput = ReplayAudioInput(engine: engine, destinationMixer: outputMixer) { [weak self] buffer, _ in
                self?.renderState.ingestInput(buffer: buffer)
            }
        }
        try replayInput?.prepare(url: audioURL)
    }

    func enableSilentReplayInputFallback() {
        let hadLiveInput = isAudioRunning && inputSource == .live
        if !isAudioRunning {
            startReplayEngineIfNeeded()
        }
        _ = stopInputRecording()
        replayInput?.stop()
        inputSource = .replayFile
        replayRestoreLiveInputOnStop = hadLiveInput
    }

    func stopReplayInput(restoreLiveInput: Bool = true) {
        replayInput?.stop()
        let shouldRestore = restoreLiveInput && replayRestoreLiveInputOnStop
        replayRestoreLiveInputOnStop = false
        if shouldRestore {
            inputSource = .live
        } else {
            inputSource = .replayFile
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
        let routeUID = preferredInputUID ?? CoreAudioInputCatalog.defaultInputUID() ?? ""
        if !routeUID.isEmpty {
            do {
                try CoreAudioInputCatalog.setCurrentInputDevice(on: input, uid: routeUID)
            } catch {
                audioError = "input select failed: \(error.localizedDescription)"
            }
        }

        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        guard format.channelCount > 0 else { return }
        updateLiveInputCaptureInfo(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.ingestLiveInputBuffer(buffer, time: time)
            self?.onLiveInputBufferCaptured?(buffer, time)
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
    let interpolationQuality: Float
    let active: Bool

    static let normal = CPUGuardAction(
        voiceLimit: 24,
        densityScale: 1.0,
        wetScale: 1.0,
        interpolationQuality: 1.0,
        active: false
    )
    static let throttled = CPUGuardAction(
        voiceLimit: 8,
        densityScale: 0.65,
        wetScale: 0.72,
        interpolationQuality: 0.35,
        active: true
    )
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
    private var prevSample: Float = 0
    private var envFast: Float = 0
    private var envSlow: Float = 0
    private var deltaEnv: Float = 0
    private var lowTrack: Float = 0
    private var highEnv: Float = 0
    private var risk: Float = 0
    private var holdSamples: Int = 0

    mutating func process(_ sample: Float, sampleRate: Float) -> FeedbackAction {
        let sr = max(8_000.0, sampleRate)
        let absx = abs(sample)
        envFast += 0.020 * (absx - envFast)
        envSlow += 0.0022 * (absx - envSlow)

        let delta = abs(sample - prevSample)
        prevSample = sample
        deltaEnv += 0.030 * (delta - deltaEnv)

        lowTrack += 0.012 * (sample - lowTrack)
        let high = sample - lowTrack
        highEnv += 0.020 * (abs(high) - highEnv)

        let activeSignal = envFast > 0.015
        let steadyTone = deltaEnv < (envFast * 0.20)
        let risingLoop = envFast > (envSlow * 1.45)
        let brightBias = highEnv > (envFast * 0.45)

        let trigger = activeSignal && steadyTone && (risingLoop || brightBias)
        if trigger {
            risk += 0.020 + (0.070 * min(1.0, envFast * 8.0))
        } else {
            risk -= 0.012
        }
        risk = max(0.0, min(1.5, risk))

        if risk > 0.92 {
            holdSamples = max(holdSamples, Int(sr * 0.45))
        }
        if holdSamples > 0 {
            holdSamples -= 1
            risk = max(risk, 0.75)
        }

        let active = holdSamples > 0 || risk > 0.95
        guard active else {
            return FeedbackAction(wetScale: 1.0, levelScale: 1.0, active: false)
        }

        let severity = max(0.0, min(1.0, (risk - 0.70) / 0.60))
        let wetScale = max(0.18, 1.0 - (0.78 * severity))
        let levelScale = max(0.60, 1.0 - (0.40 * severity))
        return FeedbackAction(wetScale: wetScale, levelScale: levelScale, active: true)
    }
}

private struct GrainVoice {
    var active: Bool = false
    var position: Float = 0
    var step: Float = 1
    var decorrelationSamples: Float = 0
    var pan: Float = 0
    var envelopeBlend: Float = 0.5
    var age: Int = 0
    var length: Int = 0
    var gain: Float = 0.0

    mutating func reset(
        position: Float,
        step: Float,
        decorrelationSamples: Float,
        pan: Float,
        envelopeBlend: Float,
        length: Int,
        gain: Float
    ) {
        self.active = true
        self.position = position
        self.step = step
        self.decorrelationSamples = decorrelationSamples
        self.pan = pan
        self.envelopeBlend = envelopeBlend
        self.age = 0
        self.length = max(1, length)
        self.gain = gain
    }
}

struct Mode1ClockState {
    private(set) var beatSamples: Int = 48_000
    private(set) var confidence: Float = 0
    private(set) var samplesSinceOnset: Int = 0
    private(set) var onsetCount: Int = 0

    mutating func configure(sampleRate: Float) {
        beatSamples = max(64, Int(sampleRate))
        confidence = 0
        samplesSinceOnset = 0
        onsetCount = 0
    }

    mutating func advance(samples: Int = 1) {
        samplesSinceOnset += max(1, samples)
        if samplesSinceOnset > beatSamples * 4 {
            confidence *= 0.985
        }
    }

    mutating func noteOnset(intervalSamples: Int, sampleRate: Float) {
        let minBeat = max(64, Int(sampleRate * 0.28))
        let maxBeat = max(minBeat + 1, Int(sampleRate * 1.6))
        let clamped = max(minBeat, min(maxBeat, intervalSamples))
        if onsetCount == 0 {
            beatSamples = clamped
        } else {
            let mixed = (Float(beatSamples) * 0.86) + (Float(clamped) * 0.14)
            beatSamples = max(minBeat, min(maxBeat, Int(mixed)))
        }
        onsetCount += 1
        samplesSinceOnset = 0
        confidence = min(1.0, confidence + 0.17)
    }

    mutating func noteUntrustedOnset() {
        confidence = max(0, confidence - 0.07)
        samplesSinceOnset = 0
    }

    mutating func confidenceDecay() {
        confidence = max(0, confidence * 0.995)
    }

    func effectiveBeatSamples(sampleRate: Float) -> Int {
        let fallback = max(64, Int(sampleRate))
        if confidence >= 0.42 {
            return beatSamples
        }
        return fallback
    }

    func stepSamples(gridDiv: String, sampleRate: Float) -> Int {
        let beat = effectiveBeatSamples(sampleRate: sampleRate)
        if gridDiv == "1/16" {
            return max(64, beat / 4)
        }
        return max(64, beat / 2)
    }
}

private struct Mode1RepeatScheduler {
    var pendingTrigger: Bool = false
    var pendingTriggerStrength: Float = 0.52
    var active: Bool = false
    var transportActive: Bool = false
    var repeatStart: Int = 0
    var repeatLength: Int = 0
    var repeatPos: Int = 0
    var sliceLength: Int = 0
    var slicePos: Int = 0
    var sliceReadHead: Float = 0
    var sliceStep: Float = 1
    var repeatSamplesRemaining: Int = 0
    var continuousRepeatSamples: Int = 0
    var cooldownSamples: Int = 0
    var boundaryStep: Int = -1
    var patternStep: Int = 0
    var lastSliceTailSample: Float = 0
    var barStepCounter: Int = 0
    var repeatGain: Float = 0
    var sliceJumpIndex: Int = 0
    var lastTriggerSource: String = "none"
    var hasValidCapture: Bool = false
    var lastValidRepeatStart: Int = 0
    var lastValidRepeatLength: Int = 0
}

struct Mode1SampleHoldPlan {
    var outputHoldSamples: Int
    var feedbackHoldSamples: Int
    var outputJitterSamples: Int
    var feedbackJitterSamples: Int
    var outputDepth: Float
    var feedbackDepth: Float
    var outputSmoothAlpha: Float
    var feedbackSmoothAlpha: Float
    var profileId: String
}

struct Mode1SampleHoldPlanner {
    static func plan(
        gridSamples: Int,
        sampleRate: Float,
        stutterNorm: Float,
        gateNorm: Float,
        repeatProb: Float,
        feedbackNorm: Float,
        repeatStyleId: String
    ) -> Mode1SampleHoldPlan {
        let grid = max(1, gridSamples)
        let styleAgg: Float = repeatStyleId == "stutter_b" ? 1.0 : 0.0
        let stutter = clamp01(stutterNorm)
        let gate = clamp01(gateNorm)
        let repeats = clamp01(repeatProb)
        let feedback = clamp01(feedbackNorm)

        let divA = 8 + Int((1.0 - stutter) * 10.0) // tighter/cleaner
        let divB = 4 + Int((1.0 - stutter) * 6.0)  // longer/rougher
        let outputDiv = styleAgg > 0.5 ? divB : divA
        let outputHold = max(1, grid / max(2, outputDiv))

        let feedbackDivA = 6 + Int((1.0 - stutter) * 8.0)
        let feedbackDivB = 3 + Int((1.0 - stutter) * 4.0)
        let feedbackDiv = styleAgg > 0.5 ? feedbackDivB : feedbackDivA
        let feedbackHold = max(1, grid / max(2, feedbackDiv))

        let outputJitter = Int(Float(outputHold) * (0.02 + 0.16 * gate + 0.08 * styleAgg))
        let feedbackJitter = Int(Float(feedbackHold) * (0.02 + 0.14 * gate + 0.12 * styleAgg))

        // Keep S&H as clear rhythmic coloration, not full-rate collapse.
        let outputDepth = min(0.68, 0.18 + 0.26 * repeats + 0.10 * stutter + 0.14 * styleAgg)
        let feedbackDepth = min(0.62, 0.06 + 0.34 * feedback + 0.08 * gate + 0.12 * styleAgg)

        let outputSmoothMs = max(0.30, min(6.0, (3.0 - 0.85 * styleAgg) * (0.48 + 0.52 * gate)))
        let feedbackSmoothMs = max(0.24, min(5.0, (2.5 - 0.75 * styleAgg) * (0.44 + 0.50 * gate)))

        return Mode1SampleHoldPlan(
            outputHoldSamples: outputHold,
            feedbackHoldSamples: feedbackHold,
            outputJitterSamples: outputJitter,
            feedbackJitterSamples: feedbackJitter,
            outputDepth: outputDepth,
            feedbackDepth: feedbackDepth,
            outputSmoothAlpha: smoothAlpha(ms: outputSmoothMs, sampleRate: sampleRate),
            feedbackSmoothAlpha: smoothAlpha(ms: feedbackSmoothMs, sampleRate: sampleRate),
            profileId: styleAgg > 0.5 ? "stutter_b_aggro" : "stutter_a_clean"
        )
    }

    private static func clamp01(_ x: Float) -> Float {
        min(max(x, 0), 1)
    }

    private static func smoothAlpha(ms: Float, sampleRate: Float) -> Float {
        let samples = max(1.0, (ms / 1_000.0) * max(8_000.0, sampleRate))
        return 1.0 - expf(-1.0 / samples)
    }
}

private struct Mode1SampleHoldLaneState {
    var holdSamplesRemaining: Int = 0
    var heldValue: Float = 0
    var smoothValue: Float = 0
    var rng: UInt64 = 0xA511_E9B3_C0DE_D00D
    var lastHoldSamples: Int = 1

    mutating func reset(seed: UInt64) {
        holdSamplesRemaining = 0
        heldValue = 0
        smoothValue = 0
        lastHoldSamples = 1
        rng = seed
    }

    mutating func nextUnit() -> Float {
        rng &+= 0x9E3779B97F4A7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= (z >> 31)
        return Float(Double(z & 0xFFFF_FFFF) / Double(UInt32.max))
    }
}

private struct Mode1SampleHoldState {
    var outputLane = Mode1SampleHoldLaneState(rng: 0xA511_E9B3_C0DE_D00D)
    var feedbackLane = Mode1SampleHoldLaneState(rng: 0xB71D_2C4F_F00D_BAAD)
    var outputHoldSamples: Int = 0
    var feedbackHoldSamples: Int = 0
    var outputJitterSamples: Int = 0
    var feedbackJitterSamples: Int = 0
    var outputDepth: Float = 0
    var feedbackDepth: Float = 0
    var outputSmoothAlpha: Float = 0.05
    var feedbackSmoothAlpha: Float = 0.05
    var profileId: String = "stutter_a_clean"
    var planRefreshCountdown: Int = 0
    var lastGridSamples: Int = -1
    var lastStutterBucket: Int = -1
    var lastGateBucket: Int = -1
    var lastRepeatBucket: Int = -1
    var lastFeedbackBucket: Int = -1
    var lastStyleBucket: Int = -1

    mutating func reset() {
        outputLane.reset(seed: 0xA511_E9B3_C0DE_D00D)
        feedbackLane.reset(seed: 0xB71D_2C4F_F00D_BAAD)
        outputHoldSamples = 0
        feedbackHoldSamples = 0
        outputJitterSamples = 0
        feedbackJitterSamples = 0
        outputDepth = 0
        feedbackDepth = 0
        outputSmoothAlpha = 0.05
        feedbackSmoothAlpha = 0.05
        profileId = "stutter_a_clean"
        planRefreshCountdown = 0
        lastGridSamples = -1
        lastStutterBucket = -1
        lastGateBucket = -1
        lastRepeatBucket = -1
        lastFeedbackBucket = -1
        lastStyleBucket = -1
    }
}

private enum Mode1GlitchState: String {
    case live
    case hold
    case fade
    case mute
}

private struct Mode1SceneVoice {
    var active: Bool = false
    var start: Int = 0
    var end: Int = 0
    var position: Float = 0
    var rate: Float = 1
    var gain: Float = 0
    var age: Int = 0
    var length: Int = 0
    var fadeInSamples: Int = 24
    var fadeOutSamples: Int = 80
    var lanePan: Float = 0

    mutating func reset(
        start: Int,
        end: Int,
        reverse: Bool,
        rate: Float,
        gain: Float,
        length: Int,
        fadeInSamples: Int,
        fadeOutSamples: Int,
        lanePan: Float
    ) {
        self.active = true
        self.start = min(start, end)
        self.end = max(start, end)
        self.rate = reverse ? -abs(rate) : abs(rate)
        self.position = reverse ? Float(self.end - 1) : Float(self.start)
        self.gain = gain
        self.age = 0
        self.length = max(1, length)
        self.fadeInSamples = max(1, fadeInSamples)
        self.fadeOutSamples = max(1, fadeOutSamples)
        self.lanePan = lanePan
    }
}

struct Mode2GranulatorState {
    var prevInput: Float = 0
    var readHeadSeeded: Bool = false
    var readHead: Float = 0
    var scanVelocity: Float = 0
    var freezeSamplesRemaining: Int = 0
    var freezeCooldownSamples: Int = 0
    var spawnCounter: Int = 0
    var transientDuck: Float = 0
    var loudnessNorm: Float = 1
    var dampLP: Float = 0
    var sceneWander: Float = 0
    fileprivate var grains: [GrainVoice] = Array(repeating: GrainVoice(), count: 24)

    init() {}

    mutating func beginFreeze(sampleRate: Float, requestedLenSec: Float) {
        let bounded = min(max(requestedLenSec, 0.08), 3.2)
        freezeSamplesRemaining = max(1, Int(sampleRate * Float(bounded)))
        freezeCooldownSamples = max(1, Int(sampleRate * 0.45))
    }
}

private struct Mode3InharmonicState {
    var carrierPhase: Float = 0
    var modPhaseA: Float = 0
    var modPhaseB: Float = 0
    var ringPhase: Float = 0
    var shimmerPhase: Float = 0
    var env: Float = 0
    var prevInput: Float = 0
    var strikeEnv: Float = 0
    var strikeHz: Float = 176.0
    var strikeCooldown: Int = 0
    var strikeIndex: Int = 0
    var triggerSmoothed: Float = 0
    var glitchHoldCounter: Int = 0
    var glitchHoldValue: Float = 0
    var holdCounter: Int = 0
    var holdSample: Float = 0
    var holdSmoothed: Float = 0
    var hfClampY: Float = 0
    var deEssEnv: Float = 0
    var lowMidLP: Float = 0
    var dcPrevX: Float = 0
    var dcPrevY: Float = 0
}

private struct Mode7Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    mutating func configureLowPass(cutoffHz: Float, sampleRate: Float, q: Float = 0.70710678) {
        configure(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q, highPass: false)
    }

    mutating func configureHighPass(cutoffHz: Float, sampleRate: Float, q: Float = 0.70710678) {
        configure(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q, highPass: true)
    }

    private mutating func configure(cutoffHz: Float, sampleRate: Float, q: Float, highPass: Bool) {
        let sr = max(8_000, sampleRate)
        let fc = max(20.0, min(cutoffHz, sr * 0.45))
        let omega = 2.0 * Float.pi * fc / sr
        let sinW = sinf(omega)
        let cosW = cosf(omega)
        let alpha = sinW / (2.0 * max(0.1, q))

        let rawB0: Float
        let rawB1: Float
        let rawB2: Float
        if highPass {
            rawB0 = (1.0 + cosW) * 0.5
            rawB1 = -(1.0 + cosW)
            rawB2 = (1.0 + cosW) * 0.5
        } else {
            rawB0 = (1.0 - cosW) * 0.5
            rawB1 = 1.0 - cosW
            rawB2 = (1.0 - cosW) * 0.5
        }
        let rawA0 = 1.0 + alpha
        let rawA1 = -2.0 * cosW
        let rawA2 = 1.0 - alpha

        let invA0 = 1.0 / max(1e-6, rawA0)
        b0 = rawB0 * invA0
        b1 = rawB1 * invA0
        b2 = rawB2 * invA0
        a1 = rawA1 * invA0
        a2 = rawA2 * invA0
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let out = (b0 * input) + z1
        z1 = (b1 * input) - (a1 * out) + z2
        z2 = (b2 * input) - (a2 * out)
        return out
    }
}

private struct Mode7LinkwitzRileyCrossover {
    var lowA = Mode7Biquad()
    var lowB = Mode7Biquad()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        lowA.configureLowPass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        lowB.configureLowPass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func split(_ input: Float) -> (Float, Float) {
        let low = lowB.process(lowA.process(input))
        // Keep each split complementary so identity mapping reconstructs cleanly.
        let high = input - low
        return (low, high)
    }
}

struct Mode7ClockState {
    private(set) var beatSamples: Int = 48_000
    private(set) var confidence: Float = 0
    private(set) var samplesSinceOnset: Int = 0
    private(set) var onsetCount: Int = 0
    private(set) var lastOnsetSample: Int64 = -1

    mutating func configure(sampleRate: Float) {
        beatSamples = max(64, Int(sampleRate))
        confidence = 0
        samplesSinceOnset = 0
        onsetCount = 0
        lastOnsetSample = -1
    }

    mutating func advance(samples: Int = 1) {
        samplesSinceOnset += max(1, samples)
        if samplesSinceOnset > beatSamples * 4 {
            confidence *= 0.988
        }
    }

    mutating func noteOnset(sampleCounter: Int64, sampleRate: Float) {
        let minBeat = max(64, Int(sampleRate * 0.22))
        let maxBeat = max(minBeat + 1, Int(sampleRate * 1.9))
        if lastOnsetSample >= 0 {
            let interval = Int(sampleCounter - lastOnsetSample)
            if interval >= minBeat && interval <= maxBeat {
                if onsetCount == 0 {
                    beatSamples = interval
                } else {
                    let mixed = (Float(beatSamples) * 0.84) + (Float(interval) * 0.16)
                    beatSamples = max(minBeat, min(maxBeat, Int(mixed)))
                }
                onsetCount += 1
                confidence = min(1.0, confidence + 0.14)
            } else {
                confidence = max(0, confidence * 0.90)
            }
        } else {
            confidence = max(0, confidence * 0.97)
        }
        lastOnsetSample = sampleCounter
        samplesSinceOnset = 0
    }

    mutating func confidenceDecay() {
        confidence = max(0, confidence * 0.996)
    }

    func effectiveBeatSamples(sampleRate: Float) -> Int {
        let fallback = max(64, Int(sampleRate))
        if confidence >= 0.40 {
            return beatSamples
        }
        return fallback
    }

    func stepSamples(sampleRate: Float, swapRateNorm: Float) -> Int {
        let rateHz = 0.1 + 5.9 * max(0, min(1, swapRateNorm))
        let beat = effectiveBeatSamples(sampleRate: sampleRate)
        let desired = max(1.0, sampleRate / rateHz)
        let divF = Float(beat) / desired
        let div = max(1, min(12, Int(divF.rounded())))
        return max(64, beat / div)
    }
}

struct Mode7SwapScheduler {
    private(set) var sceneStep: Int = 0
    var samplesUntilStep: Int = 0
    private(set) var crossfadeSamples: Int = 1
    private(set) var crossfadeRemaining: Int = 0
    private(set) var activeMatrix: [Float] = Mode7SwapScheduler.identityMatrix()
    private(set) var previousMatrix: [Float] = Mode7SwapScheduler.identityMatrix()
    private(set) var targetMatrix: [Float] = Mode7SwapScheduler.identityMatrix()
    var liveMatrix: [Float] = Mode7SwapScheduler.identityMatrix()
    private(set) var activeBandGains: [Float] = Mode7SwapScheduler.unityBandGains()
    private(set) var previousBandGains: [Float] = Mode7SwapScheduler.unityBandGains()
    private(set) var targetBandGains: [Float] = Mode7SwapScheduler.unityBandGains()
    var liveBandGains: [Float] = Mode7SwapScheduler.unityBandGains()

    static func identityMatrix() -> [Float] {
        var out = [Float](repeating: 0, count: 64)
        for i in 0..<8 {
            out[i * 8 + i] = 1.0
        }
        return out
    }

    static func unityBandGains() -> [Float] {
        Array(repeating: 1.0, count: 8)
    }

    private static func normalizedBandGains(_ values: [Float]) -> [Float] {
        if values.count != 8 {
            return unityBandGains()
        }
        var out = [Float](repeating: 1.0, count: 8)
        var sum: Float = 0
        for i in 0..<8 {
            out[i] = max(0.12, min(2.80, values[i]))
            sum += out[i]
        }
        let invMean = sum > 1e-6 ? (8.0 / sum) : 1.0
        for i in 0..<8 {
            out[i] *= invMean
        }
        return out
    }

    mutating func configure(sampleRate: Float) {
        let identity = Self.identityMatrix()
        let unity = Self.unityBandGains()
        sceneStep = 0
        samplesUntilStep = max(1, Int(sampleRate * 0.50))
        crossfadeSamples = max(1, Int(sampleRate * 0.02))
        crossfadeRemaining = 0
        activeMatrix = identity
        previousMatrix = identity
        targetMatrix = identity
        liveMatrix = identity
        activeBandGains = unity
        previousBandGains = unity
        targetBandGains = unity
        liveBandGains = unity
    }

    mutating func beginCrossfade(to matrix: [Float], crossfadeSamples: Int, bandGains: [Float]? = nil) {
        guard matrix.count == 64 else { return }
        previousMatrix = liveMatrix
        targetMatrix = matrix
        previousBandGains = liveBandGains
        targetBandGains = Self.normalizedBandGains(bandGains ?? activeBandGains)
        self.crossfadeSamples = max(1, crossfadeSamples)
        crossfadeRemaining = self.crossfadeSamples
    }

    mutating func advanceMatrix() {
        if crossfadeRemaining > 0 {
            let t = 1.0 - (Float(crossfadeRemaining) / Float(max(1, crossfadeSamples)))
            for i in 0..<64 {
                liveMatrix[i] = previousMatrix[i] + (targetMatrix[i] - previousMatrix[i]) * t
            }
            for i in 0..<8 {
                liveBandGains[i] = previousBandGains[i] + (targetBandGains[i] - previousBandGains[i]) * t
            }
            crossfadeRemaining -= 1
            if crossfadeRemaining <= 0 {
                activeMatrix = targetMatrix
                liveMatrix = activeMatrix
                activeBandGains = targetBandGains
                liveBandGains = activeBandGains
            }
        } else {
            liveMatrix = activeMatrix
            liveBandGains = activeBandGains
        }
    }

    mutating func advanceSceneStep() {
        sceneStep += 1
    }
}

struct Mode7RedistributorState {
    static let defaultCrossovers: [Float] = [120, 220, 420, 780, 1_400, 2_500, 4_300]

    fileprivate var crossovers: [Mode7LinkwitzRileyCrossover] = Array(repeating: Mode7LinkwitzRileyCrossover(), count: 7)
    var bands: [Float] = Array(repeating: 0, count: 8)
    var mapped: [Float] = Array(repeating: 0, count: 8)
    var loudnessNorm: Float = 1
    var hfClampY: Float = 0
    var prevInput: Float = 0
    var inputEnv: Float = 0
    var mappingId: String = "swap_pairs"
    var mappingFamily: String = "bucket_swap"
    var entropy: Float = 0.5
    var variance: Float = 0.2
    var seed: Int = 7
    var clock = Mode7ClockState()
    var scheduler = Mode7SwapScheduler()

    init() {}

    mutating func configure(sampleRate: Float) {
        let nyquistBound = sampleRate * 0.45
        for i in 0..<crossovers.count {
            let cutoff = max(60.0, min(Self.defaultCrossovers[i], nyquistBound))
            crossovers[i].configure(cutoffHz: cutoff, sampleRate: sampleRate)
        }
        bands = Array(repeating: 0, count: 8)
        mapped = Array(repeating: 0, count: 8)
        loudnessNorm = 1
        hfClampY = 0
        prevInput = 0
        inputEnv = 0
        clock.configure(sampleRate: sampleRate)
        scheduler.configure(sampleRate: sampleRate)
    }

    mutating func splitBands(input: Float) {
        var remainder = input
        for i in 0..<crossovers.count {
            let (low, high) = crossovers[i].split(remainder)
            bands[i] = low
            remainder = high
        }
        bands[7] = remainder
    }

    mutating func identityReconstructionSample(_ input: Float) -> Float {
        splitBands(input: input)
        var out: Float = 0
        for i in 0..<bands.count {
            out += bands[i]
        }
        return out
    }
}

struct Mode7SceneBuilder {
    static func buildMatrix(
        mappingId: String,
        mappingFamily: String,
        sharpness: Float,
        entropy: Float,
        varianceAmt: Float,
        seed: Int,
        sceneStep: Int
    ) -> [Float] {
        let mId = mappingId.isEmpty ? "swap_pairs" : mappingId
        let family = mappingFamily.lowercased()
        let sharp = max(0, min(1, sharpness))
        let ent = max(0, min(1, entropy))
        let varAmt = max(0, min(1, varianceAmt))
        let familyAggression: Float = family.contains("bucket") ? 1.0 : 0.85

        var matrix = [Float](repeating: 0, count: 64)
        for src in 0..<8 {
            let primary = mappedDest(src, mappingId: mId, sceneStep: sceneStep, entropy: ent)
            let direction = ((sceneStep + src) & 1) == 0 ? 1 : -1
            let secondary = (primary + direction + 8) % 8
            let tertiary = (primary + 2 + ((sceneStep + src) % 3)) % 8

            var row = [Float](repeating: 0, count: 8)
            row[primary] += max(0.05, (0.46 + 0.40 * sharp - 0.16 * ent) * familyAggression)
            row[secondary] += max(0.04, 0.24 + 0.30 * ent + 0.08 * (1.0 - sharp))
            row[tertiary] += max(0.03, (0.10 + 0.20 * ent) * familyAggression)

            let smearBase = (0.001 + 0.032 * ent) * max(0.05, varAmt)
            for dst in 0..<8 where dst != primary && dst != secondary && dst != tertiary {
                let jitterSeed = seed &+ (sceneStep &* 97) &+ (src &* 13)
                row[dst] = smearBase * noise(seed: jitterSeed, src: src, dst: dst)
            }

            var rowSum: Float = 0
            for dst in 0..<8 {
                rowSum += row[dst]
            }
            if rowSum < 1e-6 {
                row[src] = 1
                rowSum = 1
            }
            let inv = 1.0 / rowSum
            for dst in 0..<8 {
                matrix[src * 8 + dst] = row[dst] * inv
            }
        }
        return matrix
    }

    static func buildBandGains(
        mappingId: String,
        mappingFamily: String,
        sharpness: Float,
        entropy: Float,
        varianceAmt: Float,
        seed: Int,
        sceneStep: Int
    ) -> [Float] {
        let mId = mappingId.isEmpty ? "swap_pairs" : mappingId
        let family = mappingFamily.lowercased()
        let sharp = max(0, min(1, sharpness))
        let ent = max(0, min(1, entropy))
        let varAmt = max(0, min(1, varianceAmt))
        let familyDrive: Float = family.contains("bucket") ? 1.0 : 0.84
        let depth = (0.24 + 0.92 * ent) * familyDrive
        let sweepDir: Float = mId == "invert_diagonal" ? -1.0 : 1.0

        let profile: [Float]
        switch mId {
        case "invert_diagonal":
            profile = [1.60, 1.44, 1.30, 1.16, 0.98, 0.82, 0.68, 0.56]
        case "octave_flip":
            profile = [1.34, 0.92, 0.70, 1.08, 1.24, 0.76, 0.62, 1.50]
        default:
            profile = [0.60, 1.44, 0.78, 1.34, 0.86, 1.24, 0.98, 1.14]
        }
        let rotationStep = max(1, Int((1.0 + floor(ent * 3.0))))
        let rot = (sceneStep * rotationStep) % 8
        var gains = [Float](repeating: 1.0, count: 8)
        for band in 0..<8 {
            let idx = (band + rot + 8) % 8
            let base = profile[idx]
            let stripe: Float = ((band + sceneStep) & 1) == 0 ? 1.0 : -0.72
            let accentDepth: Float = 0.30 + 0.40 * sharp
            let accent = 1.0 + (stripe * depth * accentDepth)
            let sweepSlope: Float = 0.02 + 0.04 * ent
            let bandOffset = Float(band) - 3.5
            let sweep = 1.0 + (sweepDir * bandOffset * sweepSlope)
            let jitterSeed = seed &+ (sceneStep &* 71)
            let jitterNoise = noise(seed: jitterSeed, src: band, dst: idx)
            let jitterDepth: Float = 0.18 + 0.70 * varAmt
            let jitter = 1.0 + ((jitterNoise - 0.5) * jitterDepth)
            let shaped = base * accent * sweep * jitter
            gains[band] = max(0.12, min(2.80, shaped))
        }
        var sum: Float = 0
        for value in gains {
            sum += value
        }
        if sum < 1e-6 {
            return Array(repeating: 1.0, count: 8)
        }
        let invMean = 8.0 / sum
        for i in 0..<8 {
            gains[i] *= invMean
        }
        return gains
    }

    private static func mappedDest(_ src: Int, mappingId: String, sceneStep: Int, entropy: Float) -> Int {
        let jumpSpan = max(1, Int((entropy * 3.0).rounded()))
        let offset = (sceneStep * jumpSpan) % 8
        switch mappingId {
        case "invert_diagonal":
            return (7 - src + offset) % 8
        case "octave_flip":
            return (src + 4 + offset) % 8
        default:
            return ((src ^ 1) + offset) % 8
        }
    }

    private static func noise(seed: Int, src: Int, dst: Int) -> Float {
        let x = Float((seed &* 31) ^ (src &* 131) ^ (dst &* 521))
        let n = sinf(x * 12.9898 + 78.233) * 43758.5453
        return n - floorf(n)
    }
}

private struct Mode4ClipAnalysis {
    let rms: Float
    let peak: Float
    let brightness: Float
    let lowBandRatio: Float
    let onsetCandidates: [Int]
    let safeCutPoints: [Int]
}

private struct Mode4SampleClip {
    let id: String
    let category: String
    let gain: Float
    let sampleRate: Float
    let samples: [Float]
    let analysis: Mode4ClipAnalysis
}

private struct Mode4LiveFeatures {
    let onsetNoisy: Float
    let brightness: Float
    let lowBand: Float
}

private struct Mode4GestureVoice {
    var active: Bool = false
    var clipIndex: Int = 0
    var startFrame: Int = 0
    var endFrame: Int = 1
    var playhead: Float = 0
    var playbackStep: Float = 1
    var reverse: Bool = false
    var age: Int = 0
    var length: Int = 1
    var gain: Float = 0
    var panX: Float = 0
    var panY: Float = 0
    var fadeInSamples: Int = 1
    var fadeOutSamples: Int = 1
    var category: String = "general"
    var clipId: String = "unknown"

    mutating func reset(
        clipIndex: Int,
        clipId: String,
        category: String,
        startFrame: Int,
        endFrame: Int,
        reverse: Bool,
        playbackStep: Float,
        length: Int,
        gain: Float,
        panX: Float,
        panY: Float
    ) {
        self.active = true
        self.clipIndex = max(0, clipIndex)
        self.clipId = clipId
        self.category = category
        self.startFrame = max(0, startFrame)
        self.endFrame = max(self.startFrame + 1, endFrame)
        self.reverse = reverse
        self.playbackStep = max(0.05, playbackStep)
        self.playhead = reverse ? Float(self.endFrame - 1) : Float(self.startFrame)
        self.age = 0
        self.length = max(1, length)
        self.gain = gain
        self.panX = panX
        self.panY = panY
        let fade = max(12, min(240, self.length / 6))
        self.fadeInSamples = fade
        self.fadeOutSamples = fade
    }
}

private struct ResonVoice {
    var active: Bool = false
    var midiNote: Int = 60
    var freqHz: Float = 261.63
    var phase: Float = 0
    var instrumentId: String = "inst_A"
    var sampleZoneIndex: Int = -1
    var samplePosition: Float = 0
    var sampleStep: Float = 1
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
        instrumentId: String,
        sampleZoneIndex: Int,
        samplePosition: Float,
        sampleStep: Float,
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
        self.instrumentId = instrumentId
        self.sampleZoneIndex = sampleZoneIndex
        self.samplePosition = samplePosition
        self.sampleStep = sampleStep
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

private struct ResonSampleZone {
    let rootMidi: Int
    let lowMidi: Int
    let highMidi: Int
    let sampleRate: Float
    let samples: [Float]
    let gain: Float
    let startFrame: Int
    let endFrame: Int
    let peak: Float
}

private struct ResonInstrument {
    let id: String
    let wavetable: [Float]
    let gain: Float
    let brightness: Float
    let polyphonyHint: Int
    let sampleZones: [ResonSampleZone]
    let sourceKind: String
    let sourceRef: String

    static func fallback(id: String) -> ResonInstrument {
        let tableCount = 2_048
        var table = [Float](repeating: 0, count: tableCount)
        for i in 0..<tableCount {
            let ph = 2.0 * Float.pi * Float(i) / Float(tableCount)
            table[i] = (sinf(ph) * 0.72) + (sinf(ph * 2.0) * 0.18) + (sinf(ph * 3.0) * 0.10)
        }
        return ResonInstrument(
            id: id,
            wavetable: table,
            gain: 1.0,
            brightness: 0.5,
            polyphonyHint: 8,
            sampleZones: [],
            sourceKind: "fallback_wavetable",
            sourceRef: "fallback_wavetable"
        )
    }

}

private struct OutputChannelSlot {
    let base: UnsafeMutablePointer<Float>
    let stride: Int

    func write(frameIndex: Int, sample: Float) {
        base[frameIndex * stride] = sample
    }
}

private struct OutputChannelBinding {
    let slots: [OutputChannelSlot]

    init(audioBuffers: UnsafeMutableAudioBufferListPointer) {
        var built: [OutputChannelSlot] = []
        built.reserveCapacity(audioBuffers.reduce(0) { $0 + max(1, Int($1.mNumberChannels)) })
        for buffer in audioBuffers {
            guard let mData = buffer.mData else { continue }
            let base = mData.assumingMemoryBound(to: Float.self)
            let channelCount = max(1, Int(buffer.mNumberChannels))
            if channelCount == 1 {
                built.append(OutputChannelSlot(base: base, stride: 1))
            } else {
                for channel in 0..<channelCount {
                    built.append(OutputChannelSlot(base: base.advanced(by: channel), stride: channelCount))
                }
            }
        }
        slots = built
    }

    var channelCount: Int { slots.count }

    func write(channelIndex: Int, frameIndex: Int, sample: Float) {
        guard channelIndex >= 0, channelIndex < slots.count else { return }
        slots[channelIndex].write(frameIndex: frameIndex, sample: sample)
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

struct InputResampleState {
    var sourceSampleRate: Float = 48_000
    var nextOutputSourcePosition: Double = 1.0
    var previousSample: Float = 0
    var hasPreviousSample: Bool = false

    mutating func reset(sourceSampleRate: Float) {
        self.sourceSampleRate = max(8_000, sourceSampleRate)
        nextOutputSourcePosition = 1.0
        previousSample = 0
        hasPreviousSample = false
    }
}

enum InputResampler {
    static func resample(
        samples: [Float],
        sourceSampleRate: Float,
        outputSampleRate: Float,
        correction: Float = 0,
        state: inout InputResampleState
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let srcRate = max(8_000, sourceSampleRate)
        let dstRate = max(8_000, outputSampleRate)
        let boundedCorrection = max(-0.08, min(0.08, correction))
        let effectiveDstRate = dstRate * max(0.25, 1.0 + boundedCorrection)

        if !state.hasPreviousSample || abs(state.sourceSampleRate - srcRate) > 0.5 {
            state.reset(sourceSampleRate: srcRate)
            state.previousSample = samples[0]
            state.hasPreviousSample = true
        } else {
            state.sourceSampleRate = srcRate
        }

        let step = Double(srcRate / effectiveDstRate)
        let lastIndex = Double(samples.count)
        let estimatedCount = max(1, Int(ceil(Double(samples.count) * Double(effectiveDstRate / srcRate))) + 2)
        var out: [Float] = []
        out.reserveCapacity(estimatedCount)

        func extendedSample(at index: Int) -> Float {
            if index <= 0 {
                return state.previousSample
            }
            let sampleIndex = min(samples.count - 1, index - 1)
            return samples[sampleIndex]
        }

        var position = state.nextOutputSourcePosition
        while position <= lastIndex {
            let lower = max(0, min(samples.count, Int(floor(position))))
            let upper = max(0, min(samples.count, lower + 1))
            let frac = Float(position - Double(lower))
            let a = extendedSample(at: lower)
            let b = extendedSample(at: upper)
            out.append(a + ((b - a) * frac))
            position += step
        }

        state.nextOutputSourcePosition = max(0.0, position - Double(samples.count))
        state.previousSample = samples[samples.count - 1]
        state.hasPreviousSample = true
        return out
    }
}

nonisolated private final class MasterRenderState {
    private let ringLock = NSLock()
    private let stateLock = NSLock()

    private var sampleRate: Float = 48_000
    private var outputChannels: Int = 2
    private var outputHardwareChannels: Int = 2
    private var outputRouteMode: OutputRouteMode = .stereoFallback
    private var outputRouteUID: String = "default"
    private var outputRouteName: String = "System Default"
    private var outputRouteWarning: String? = "output_uninitialized"
    private var outputProfile: OutputRoutingProfile = OutputRoutingProfile.defaultProfile(for: "default", hardwareChannels: 2)
    private var outputHasSolo: Bool = false
    private var outputDelayBuffers: [[Float]] = Array(repeating: [Float](repeating: 0, count: 1), count: OutputRoutingProfile.virtualChannelCount)
    private var outputDelayWrite: [Int] = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
    private var outputDelayCapacity: Int = 1
    private var outputPhysicalScratch: [Float] = Array(repeating: 0, count: 8)
    private var outputHardwareMeterPeaks: [Float] = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
    private var outputHardwareMeterDisplay: [Float] = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
    private var outputRenderCallbackCounter: UInt64 = 0
    private var outputRenderBufferCount: Int = 0
    private var outputRenderSlotCount: Int = 0
    private var outputRenderFrameCount: Int = 0
    private var outputRenderPreRoutePeak: Float = 0
    private var outputRenderPostRoutePeak: Float = 0
    private var outputRenderPreRouteDisplay: Float = 0
    private var outputRenderPostRouteDisplay: Float = 0
    private var outputTestActive: Bool = false
    private var outputTestScanAll: Bool = false
    private var outputTestChannelIndex: Int = 0
    private var outputTestBurstSamples: Int = 0
    private var outputTestGapSamples: Int = 0
    private var outputTestBurstRemaining: Int = 0
    private var outputTestGapRemaining: Int = 0
    private var outputTestCurrentChannel: Int = 0
    private var outputTestLevelLinear: Float = 0.125
    private var outputTestRng: UInt64 = 0x9E37_DA73_DA73_1001
    private var outputTestPinkA: Float = 0
    private var outputTestPinkB: Float = 0
    private var controlTarget = AudioControl()
    private var controlCurrent = AudioControl()
    private var reverb = DualReverbCore()
    private var inputRouteUID: String = "default"
    private var inputRouteName: String = "System Default"
    private var inputRouteChannels: Int = 0
    private var inputRouteWarning: String? = "input_route_uninitialized"
    private var inputRouteProfile: InputRoutingProfile = InputRoutingProfile.defaultProfile(for: "default", inputChannels: 1)

    private var inputRing: [Float] = Array(repeating: 0, count: 262_144)
    private var ringWrite: Int = 0
    private var ringRead: Int = 0
    private var inputScratch: [Float] = Array(repeating: 0, count: 4_096)
    private var maxInputLagSamples: Int = 4_320
    private var targetInputLagSamples: Int = 2_048
    private var pendingInputFlush: Bool = false
    private var inputResampleState = InputResampleState()
    private var externalInputGainCurrent: Float = 1.0
    private var externalInputGainTarget: Float = 1.0
    private var externalInputGainStep: Float = 0.0
    private var externalInputGainRampRemaining: Int = 0
    private var pianoTunerDuckActiveTarget: Bool = false
    private var pianoTunerDuckCurrent: Float = 1.0
    private var pianoTunerDuckTarget: Float = 1.0
    private var pianoTunerDuckStep: Float = 0.0
    private var pianoTunerDuckRampRemaining: Int = 0

    private var sirenTracks: [SirenTrackClip] = []
    private var sirenOrder: [Int] = []
    private var sirenOrderCursor: Int = 0
    private var sirenTrackIndex: Int = -1
    private var sirenPlayhead: Float = 0
    private var sirenPlayStep: Float = 1
    private var sirenActiveTarget: Bool = false
    private var sirenGainCurrent: Float = 0.0
    private var sirenGainTarget: Float = 0.0
    private var sirenGainStep: Float = 0.0
    private var sirenGainRampRemaining: Int = 0
    private var sirenNominalGain: Float = 0.34
    private var sirenRng: UInt64 = 0xD4B5_17C5_4A3F_1E29

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
    private var grainRng: UInt64 = 0x9E3779B97F4A7C15
    private var mode2State = Mode2GranulatorState()

    private var mode3State = Mode3InharmonicState()

    private var lowLP: Float = 0
    private var highHP: Float = 0
    private var highPrevX: Float = 0

    private var wetClampY: Float = 0

    // Mode 1 repeat engine state.
    private var mode1Buffer = [Float](repeating: 0, count: 786_432) // ~16s @48k
    private var mode1Write: Int = 0
    private var mode1PrevInput: Float = 0
    private var mode1Env: Float = 0
    private var mode1Clock = Mode1ClockState()
    private var mode1Scheduler = Mode1RepeatScheduler()
    private var mode1TransientDuck: Float = 0
    private var mode1DryAttackBoost: Float = 0
    private var mode1FeedbackLP: Float = 0
    private var mode1LastOnsetSample: Int64 = -1
    private var mode1SpatialX: Float = 0
    private var mode1SpatialY: Float = 0
    private var mode1SampleHold = Mode1SampleHoldState()
    private var mode1CaptureValid: Bool = false
    private var mode1CaptureEnergy: Float = 0
    private var mode1WetFloorState: Float = 0
    private var mode1DryDuckState: Float = 1.0
    private var mode1GateSmoothed: Float = 1.0
    private var mode1WetSmoothed: Float = 0
    private var mode1WetEnergyAccum: Float = 0
    private var mode1WetMeterSamples: Int = 0
    private var mode1WetRMS: Float = 0
    private var mode1State: Mode1GlitchState = .mute
    private var mode1SceneId: String = "razor_gate"
    private var mode1SceneCursor: Int = 0
    private var mode1BoundaryStep: Int = -1
    private var mode1SilenceSamples: Int = 0
    private var mode1HoldSamplesRemaining: Int = 0
    private var mode1FadeSamplesRemaining: Int = 0
    private var mode1FadeGain: Float = 0
    private var mode1LastTriggerSource: String = "none"
    private var mode1MacroFracture: Float = 0.58
    private var mode1MacroMutation: Float = 0.42
    private var mode1MacroPitchLock: Float = 0.68
    private var mode1HoldTargetSamples: Int = 0
    private var mode1TailFadeTargetSamples: Int = 0
    private var mode1SceneEventAccumulator: Float = 0
    private var mode1JoltBoost: Float = 0
    private var mode1LastValidSliceStart: Int = 0
    private var mode1LastValidSliceLength: Int = 0
    private var mode1HasValidSlice: Bool = false
    private var mode1CaptureSliceBuffer: [Float] = []
    private var mode1ShardVoices = Array(repeating: Mode1SceneVoice(), count: 12)
    private var mode1PitchVoices = Array(repeating: Mode1SceneVoice(), count: 6)
    private var mode1MutationHoldSamplesRemaining: Int = 0
    private var mode1MutationFeedbackHoldSamplesRemaining: Int = 0
    private var mode1MutationHeld: Float = 0
    private var mode1MutationFeedbackHeld: Float = 0
    private var mode1MutationSmooth: Float = 0
    private var mode1MutationFeedbackSmooth: Float = 0
    private var mode1MutationLP: Float = 0
    private var mode1MutationHP: Float = 0
    private var mode1MutationPrev: Float = 0
    private var mode1MutationRingPhase: Float = 0
    private var mode1SpectralLP1: Float = 0
    private var mode1SpectralLP2: Float = 0
    private var mode1SpectralLP3: Float = 0
    private var mode1SpectralFeedback: Float = 0
    private var mode1SpectralHoldRemaining: [Int] = Array(repeating: 0, count: 4)
    private var mode1SpectralHeldBands: [Float] = Array(repeating: 0, count: 4)
    private var mode1SpectralSmoothBands: [Float] = Array(repeating: 0, count: 4)
    private var mode1SpectralCarrierPhase: [Float] = Array(repeating: 0, count: 4)
    private var mode1PitchZeroCrossCount: Int = 0
    private var mode1PitchLastCross: Int = 0
    private var mode1PitchPrevInput: Float = 0
    private var mode1PitchHz: Float = 220
    private var mode1PitchConf: Float = 0
    private var mode1PrevClearRequest: Bool = false
    private var mode1PrevJoltRequest: Bool = false

    // Mode 4 clean + gesture state.
    private var mode4Voices = Array(repeating: Mode4GestureVoice(), count: 12)
    private var mode4LastTriggerSamplesAgo: Int = 100_000
    private var mode4SessionId: String = "session_boot"
    private var mode4RouteUID: String = "default"
    private var mode4RouteChangedAtMs: Int = 0
    private var mode4LastSessionResetMs: Int = 0
    private var mode4MemoryDecay: Float = 1
    private var mode4SampleLibrary: [Mode4SampleClip] = []
    private var mode4CategoryToIndices: [String: [Int]] = [:]
    private var mode4LibraryBankId: String = "samples_A"
    private var mode4LoadInterventions: [String] = []
    private var mode4NoSamplesDryOnly: Bool = false
    private var mode4RecentClipIndices: [Int] = []
    private var mode4TriggerAccumulator: Float = 0
    private var mode4ActiveVoices: Int = 0
    private var mode4PrevInput: Float = 0
    private var mode4InputEnv: Float = 0
    private var mode4LowTrack: Float = 0
    private var mode4LowEnv: Float = 0
    private var mode4HighEnv: Float = 0
    private var mode4Noisiness: Float = 0

    // Modes 5/6 share the mode-4 transient DSP, but point at a separate siren-song library.
    private var mode56SampleLibrary: [Mode4SampleClip] = []
    private var mode56CategoryToIndices: [String: [Int]] = [:]
    private var mode56LibraryLoaded: Bool = false
    private var mode46LastDispatchMode: Int = -1

    // Modes 5/6 resonifier state.
    private var resonVoices = Array(repeating: ResonVoice(), count: 8)
    private var resonInstrumentCache: [String: ResonInstrument] = [:]
    private var resonCurrentInstrument: ResonInstrument = ResonInstrument.fallback(id: "inst_A")
    private var resonSwapInstrument: ResonInstrument = ResonInstrument.fallback(id: "inst_A")
    private var mode56LoadInterventions: [String] = []
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
    private var resonReactiveGateSamples: Int = 0
    private var resonNoiseFloor: Float = 0.001
    private var resonSilenceSamples: Int = 0
    private var resonIsSilent: Bool = true
    private var resonInputLevel: Float = 0
    private var resonLastMidi: Int = -1
    private var resonDesiredVoices: Int = 0
    private var resonSpawnCount: Int = 0
    private var resonOutputEnergyAccum: Float = 0
    private var resonOutputMeterSamples: Int = 0
    private var resonLastOutputRMS: Float = 0
    private var resonDebugCounter: Int = 0

    // Mode 7 true redistribution state.
    private var mode7State = Mode7RedistributorState()

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
            self.outputHardwareChannels = self.outputChannels
            self.outputProfile.sanitize(for: self.outputHardwareChannels)
            self.outputHasSolo = self.outputProfile.channels.contains(where: { $0.solo })
            self.outputTestBurstSamples = max(1, Int(self.sampleRate * 0.30))
            self.outputTestGapSamples = max(1, Int(self.sampleRate * 0.22))
            self.outputTestBurstRemaining = 0
            self.outputTestGapRemaining = 0
            self.outputTestCurrentChannel = self.outputTestChannelIndex
            self.outputTestPinkA = 0
            self.outputTestPinkB = 0
            self.outputHardwareMeterPeaks = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
            self.outputHardwareMeterDisplay = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
            self.outputRenderCallbackCounter = 0
            self.outputRenderBufferCount = 0
            self.outputRenderSlotCount = 0
            self.outputRenderFrameCount = 0
            self.outputRenderPreRoutePeak = 0
            self.outputRenderPostRoutePeak = 0
            self.outputRenderPreRouteDisplay = 0
            self.outputRenderPostRouteDisplay = 0
            self.rebuildOutputDelayBuffers()
            self.maxInputLagSamples = max(512, Int(self.sampleRate * 0.090))
            self.targetInputLagSamples = min(self.maxInputLagSamples - 32, max(256, Int(self.sampleRate * 0.040)))
            self.inputResampleState.reset(sourceSampleRate: self.sampleRate)
            self.externalInputGainCurrent = 1.0
            self.externalInputGainTarget = 1.0
            self.externalInputGainStep = 0.0
            self.externalInputGainRampRemaining = 0
            self.pianoTunerDuckActiveTarget = false
            self.pianoTunerDuckCurrent = 1.0
            self.pianoTunerDuckTarget = 1.0
            self.pianoTunerDuckStep = 0.0
            self.pianoTunerDuckRampRemaining = 0
            self.sirenTrackIndex = -1
            self.sirenPlayhead = 0
            self.sirenPlayStep = 1
            self.sirenActiveTarget = false
            self.sirenGainCurrent = 0
            self.sirenGainTarget = 0
            self.sirenGainStep = 0
            self.sirenGainRampRemaining = 0
            self.hpAlpha = hpfAlpha(fc: 100.0, sampleRate: self.sampleRate)
            self.reverb.configure(sampleRate: self.sampleRate)
            self.reverb.setTarget(controlCurrent.reverb)
            self.mode1Clock.configure(sampleRate: self.sampleRate)
            self.mode1SampleHold.reset()
            self.mode1Scheduler = Mode1RepeatScheduler()
            self.mode1CaptureValid = false
            self.mode1CaptureEnergy = 0
            self.mode1WetFloorState = 0
            self.mode1DryDuckState = 1.0
            self.mode1GateSmoothed = 1.0
            self.mode1WetSmoothed = 0
            self.mode1WetEnergyAccum = 0
            self.mode1WetMeterSamples = 0
            self.mode1WetRMS = 0
            self.mode1State = .mute
            self.mode1SceneId = "razor_gate"
            self.mode1SceneCursor = 0
            self.mode1BoundaryStep = -1
            self.mode1SilenceSamples = 0
            self.mode1HoldSamplesRemaining = 0
            self.mode1FadeSamplesRemaining = 0
            self.mode1FadeGain = 0
            self.mode1LastTriggerSource = "none"
            self.mode1MacroFracture = 0.58
            self.mode1MacroMutation = 0.42
            self.mode1MacroPitchLock = 0.68
            self.mode1HoldTargetSamples = Int(self.sampleRate * 8.0)
            self.mode1TailFadeTargetSamples = Int(self.sampleRate * 0.48)
            self.mode1SceneEventAccumulator = 0
            self.mode1JoltBoost = 0
            self.mode1LastValidSliceStart = 0
            self.mode1LastValidSliceLength = 0
            self.mode1HasValidSlice = false
            self.mode1CaptureSliceBuffer.removeAll(keepingCapacity: false)
            for i in self.mode1ShardVoices.indices { self.mode1ShardVoices[i].active = false }
            for i in self.mode1PitchVoices.indices { self.mode1PitchVoices[i].active = false }
            self.mode1MutationHoldSamplesRemaining = 0
            self.mode1MutationFeedbackHoldSamplesRemaining = 0
            self.mode1MutationHeld = 0
            self.mode1MutationFeedbackHeld = 0
            self.mode1MutationSmooth = 0
            self.mode1MutationFeedbackSmooth = 0
            self.mode1MutationLP = 0
            self.mode1MutationHP = 0
            self.mode1MutationPrev = 0
            self.mode1MutationRingPhase = 0
            self.mode1SpectralLP1 = 0
            self.mode1SpectralLP2 = 0
            self.mode1SpectralLP3 = 0
            self.mode1SpectralFeedback = 0
            for i in self.mode1SpectralHoldRemaining.indices {
                self.mode1SpectralHoldRemaining[i] = 0
                self.mode1SpectralHeldBands[i] = 0
                self.mode1SpectralSmoothBands[i] = 0
                self.mode1SpectralCarrierPhase[i] = 0
            }
            self.mode1PitchZeroCrossCount = 0
            self.mode1PitchLastCross = 0
            self.mode1PitchPrevInput = 0
            self.mode1PitchHz = 220
            self.mode1PitchConf = 0
            self.mode1PrevClearRequest = false
            self.mode1PrevJoltRequest = false
            self.mode2State = Mode2GranulatorState()
            self.mode3State = Mode3InharmonicState()
            self.mode7State.configure(sampleRate: self.sampleRate)
            reloadMode4SampleLibrary(bankId: controlCurrent.bankId ?? "samples_A")
            if !mode56LibraryLoaded {
                loadMode56SampleLibraryFromBundle()
            }
            preloadResonifierDefaults()
            setMode7TargetMatrix(mappingId: "swap_pairs", mappingFamily: "bucket_swap", bias: 0.5, varianceAmt: 0.2, seed: 7)
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
                clamped.wetLevel = min(max(clamped.wetLevel, 0.88), 1.0)
                clamped.dryLevel = min(max(clamped.dryLevel, 0.0), 0.10)
            } else if clamped.mode == 4 {
                clamped.wetLevel = min(max(clamped.wetLevel, 0.82), 1.0)
                clamped.dryLevel = min(max(clamped.dryLevel, 0.0), 0.20)
            } else {
                clamped.wetLevel = min(max(clamped.wetLevel, 0), 0.60)
            }

            let mode4ActiveOrPending = controlCurrent.mode == 4 || controlTarget.mode == 4 || pendingControl?.mode == 4
            let mode56ActiveOrPending = controlCurrent.mode == 5
                || controlCurrent.mode == 6
                || controlTarget.mode == 5
                || controlTarget.mode == 6
                || pendingControl?.mode == 5
                || pendingControl?.mode == 6
            if clamped.mode == 4 {
                let requestedBankId = clamped.bankId ?? "samples_A"
                if requestedBankId != mode4LibraryBankId || mode4SampleLibrary.isEmpty {
                    reloadMode4SampleLibrary(bankId: requestedBankId)
                    pendingInputFlush = true
                } else if !mode4ActiveOrPending {
                    resetMode4RuntimeState()
                }
            }
            if clamped.mode == 5 || clamped.mode == 6 {
                if !mode56ActiveOrPending {
                    reloadResonifierLibrary(activeInstrumentId: clamped.midiInstId)
                    pendingInputFlush = true
                }
            }

            if clamped.mode != controlTarget.mode {
                if let pending = pendingControl, pending.mode == clamped.mode {
                    // Refresh target parameters without extending switch deferral.
                    pendingControl = clamped
                } else {
                    pendingControl = clamped
                    pendingSwitchSamples = pendingGestureSamples(
                        outgoingMode: controlCurrent.mode,
                        incomingMode: clamped.mode
                    )
                }
                if isLowLatencyIncomingMode(clamped.mode) {
                    pendingInputFlush = true
                }
            } else {
                controlTarget = clamped
                pendingControl = nil
                pendingSwitchSamples = 0
            }

            if clamped.mode == 7 {
                setMode7TargetMatrix(
                    mappingId: clamped.mappingId,
                    mappingFamily: clamped.mappingFamily,
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

    func setOutputRouting(
        profile: OutputRoutingProfile,
        hardwareChannels: Int,
        activeMode: OutputRouteMode,
        outputUID: String,
        outputName: String,
        warning: String?
    ) {
        stateLock.withLock {
            var sanitized = profile
            sanitized.sanitize(for: max(1, hardwareChannels))
            outputProfile = sanitized
            outputHardwareChannels = max(1, hardwareChannels)
            outputChannels = outputHardwareChannels
            outputRouteMode = activeMode
            outputRouteUID = outputUID
            outputRouteName = outputName
            outputRouteWarning = warning
            outputHasSolo = sanitized.channels.contains(where: { $0.solo })
            rebuildOutputDelayBuffers()
        }
    }

    func setInputRouting(
        profile: InputRoutingProfile,
        inputUID: String,
        inputName: String,
        channelCount: Int,
        warning: String?
    ) {
        stateLock.withLock {
            var sanitized = profile
            _ = sanitized.sanitize(for: max(0, channelCount))
            inputRouteProfile = sanitized
            inputRouteUID = inputUID
            inputRouteName = inputName
            inputRouteChannels = max(0, channelCount)
            inputRouteWarning = warning
        }
    }

    func setSirenTracks(_ tracks: [SirenTrackClip]) {
        stateLock.withLock {
            sirenTracks = tracks.filter { !$0.samples.isEmpty && $0.sampleRate > 1.0 }
            sirenTrackIndex = -1
            sirenPlayhead = 0
            sirenPlayStep = 1
            sirenActiveTarget = false
            sirenGainCurrent = 0
            sirenGainTarget = 0
            sirenGainStep = 0
            sirenGainRampRemaining = 0
            sirenReshuffleOrderLocked()
        }
    }

    func setSirenPlayback(active: Bool, fadeSeconds: Float) {
        stateLock.withLock {
            let shouldEnable = active && !sirenTracks.isEmpty
            sirenActiveTarget = shouldEnable
            let nextTarget: Float = shouldEnable ? sirenNominalGain : 0.0
            if fadeSeconds <= 0 {
                sirenGainCurrent = nextTarget
                sirenGainTarget = nextTarget
                sirenGainStep = 0
                sirenGainRampRemaining = 0
            } else {
                let total = max(1, Int(sampleRate * fadeSeconds))
                sirenGainTarget = nextTarget
                sirenGainStep = (sirenGainTarget - sirenGainCurrent) / Float(total)
                sirenGainRampRemaining = total
            }
            if shouldEnable && sirenTrackIndex < 0 {
                sirenTrackIndex = nextSirenTrackIndexLocked()
                sirenPlayhead = 0
                if sirenTrackIndex >= 0 {
                    sirenPlayStep = sirenTracks[sirenTrackIndex].sampleRate / max(8_000.0, sampleRate)
                }
            }
        }
    }

    func setExternalInputGain(target: Float, rampSeconds: Float) {
        stateLock.withLock {
            let clamped = min(max(target, 0.0), 1.0)
            if rampSeconds <= 0 {
                externalInputGainCurrent = clamped
                externalInputGainTarget = clamped
                externalInputGainStep = 0
                externalInputGainRampRemaining = 0
            } else {
                let total = max(1, Int(sampleRate * rampSeconds))
                externalInputGainTarget = clamped
                externalInputGainStep = (externalInputGainTarget - externalInputGainCurrent) / Float(total)
                externalInputGainRampRemaining = total
            }
        }
    }

    func setPianoTunerDuck(active: Bool, duckGain: Float, fadeDownSeconds: Float, fadeUpSeconds: Float) {
        stateLock.withLock {
            let clampedDuckGain = min(max(duckGain, 0.0), 1.0)
            pianoTunerDuckActiveTarget = active
            let nextTarget: Float = active ? clampedDuckGain : 1.0
            let rampSeconds = active ? fadeDownSeconds : fadeUpSeconds
            if rampSeconds <= 0 {
                pianoTunerDuckCurrent = nextTarget
                pianoTunerDuckTarget = nextTarget
                pianoTunerDuckStep = 0
                pianoTunerDuckRampRemaining = 0
            } else {
                let total = max(1, Int(sampleRate * rampSeconds))
                pianoTunerDuckTarget = nextTarget
                pianoTunerDuckStep = (pianoTunerDuckTarget - pianoTunerDuckCurrent) / Float(total)
                pianoTunerDuckRampRemaining = total
            }
        }
    }

    func externalInputGainSnapshot() -> (current: Float, target: Float) {
        stateLock.withLock {
            (externalInputGainCurrent, externalInputGainTarget)
        }
    }

    func sirenPlaybackSnapshot() -> (trackCount: Int, activeTarget: Bool, gainCurrent: Float, gainTarget: Float) {
        stateLock.withLock {
            (sirenTracks.count, sirenActiveTarget, sirenGainCurrent, sirenGainTarget)
        }
    }

    func pianoTunerDuckSnapshot() -> (activeTarget: Bool, current: Float, target: Float) {
        stateLock.withLock {
            (pianoTunerDuckActiveTarget, pianoTunerDuckCurrent, pianoTunerDuckTarget)
        }
    }

    func advanceAutomationOnly(frames: Int) {
        guard frames > 0 else { return }
        stateLock.withLock {
            for _ in 0..<frames {
                advanceExternalInputGainLocked()
                advancePianoTunerDuckLocked()
                advanceSirenGainLocked()
            }
        }
    }

    func setOutputTest(active: Bool, channelIndex: Int, scanAll: Bool, levelDb: Double) {
        stateLock.withLock {
            outputTestActive = active
            outputTestChannelIndex = max(0, min(OutputRoutingProfile.virtualChannelCount - 1, channelIndex))
            outputTestScanAll = scanAll
            outputTestCurrentChannel = outputTestChannelIndex
            outputTestBurstRemaining = 0
            outputTestGapRemaining = 0
            outputTestPinkA = 0
            outputTestPinkB = 0
            let clamped = max(OutputRoutingProfile.minTestLevelDb, min(OutputRoutingProfile.maxTestLevelDb, levelDb))
            outputTestLevelLinear = powf(10.0, Float(clamped) / 20.0)
        }
    }

    func consumeOutputHardwareMeterLevels() -> [Float] {
        stateLock.withLock {
            for idx in 0..<OutputRoutingProfile.virtualChannelCount {
                let held = outputHardwareMeterDisplay[idx] * 0.80
                let next = max(outputHardwareMeterPeaks[idx], held)
                outputHardwareMeterDisplay[idx] = next < 0.0006 ? 0 : next
                outputHardwareMeterPeaks[idx] = 0
            }
            return outputHardwareMeterDisplay
        }
    }

    func consumeOutputRenderDiagnostics() -> OutputRenderDiagnosticsSnapshot {
        stateLock.withLock {
            outputRenderPreRouteDisplay = max(outputRenderPreRoutePeak, outputRenderPreRouteDisplay * 0.80)
            outputRenderPostRouteDisplay = max(outputRenderPostRoutePeak, outputRenderPostRouteDisplay * 0.80)
            if outputRenderPreRouteDisplay < 0.0006 { outputRenderPreRouteDisplay = 0 }
            if outputRenderPostRouteDisplay < 0.0006 { outputRenderPostRouteDisplay = 0 }
            let snapshot = OutputRenderDiagnosticsSnapshot(
                callbackCounter: outputRenderCallbackCounter,
                frameCount: outputRenderFrameCount,
                bufferCount: outputRenderBufferCount,
                slotCount: outputRenderSlotCount,
                configuredHardwareChannels: outputHardwareChannels,
                preRoutePeak: outputRenderPreRouteDisplay,
                postRoutePeak: outputRenderPostRouteDisplay
            )
            outputRenderPreRoutePeak = 0
            outputRenderPostRoutePeak = 0
            return snapshot
        }
    }

    func snapshotInterventions() -> [String] {
        stateLock.withLock {
            var out = lastInterventions.names()
            out.append("render_mode:\(controlCurrent.mode)")
            out.append("input_backlog_ms:\(String(format: "%.1f", inputBacklogMs()))")
            out.append("input_uid:\(inputRouteUID.isEmpty ? "default" : inputRouteUID)")
            out.append("input_name:\(inputRouteName)")
            out.append("input_channels:\(inputRouteChannels)")
            out.append("input_active:\(inputRouteProfile.activeSummary())")
            if let inputRouteWarning, !inputRouteWarning.isEmpty {
                out.append(inputRouteWarning)
            }
            out.append("output_uid:\(outputRouteUID.isEmpty ? "default" : outputRouteUID)")
            out.append("output_name:\(outputRouteName)")
            out.append("output_channels:\(outputHardwareChannels)")
            out.append("output_mode:\(outputRouteMode.rawValue)")
            out.append("output_mapping:\(outputProfile.mappingSummary())")
            out.append("siren_tracks:\(sirenTracks.count)")
            out.append("siren_active:\(sirenActiveTarget ? 1 : 0)")
            out.append("siren_gain:\(String(format: "%.3f", sirenGainCurrent))")
            out.append("external_input_gain:\(String(format: "%.3f", externalInputGainCurrent))")
            out.append("piano_tuner_active:\(pianoTunerDuckActiveTarget ? 1 : 0)")
            out.append("piano_tuner_gain:\(String(format: "%.3f", pianoTunerDuckCurrent))")
            if let outputRouteWarning, !outputRouteWarning.isEmpty {
                out.append(outputRouteWarning)
            }
            if controlCurrent.mode == 1 {
                out.append("mode1_grid_div:\(controlCurrent.gridDiv)")
                out.append("mode1_repeat_style:\(controlCurrent.repeatStyleId)")
                out.append("mode1_scene:\(mode1SceneId)")
                out.append("mode1_state:\(mode1State.rawValue)")
                let holdRemainingMs = Int((Float(mode1HoldSamplesRemaining) * 1000.0) / max(1.0, sampleRate))
                out.append("mode1_hold_remaining_ms:\(max(0, holdRemainingMs))")
                out.append("mode1_trigger_src:\(mode1LastTriggerSource)")
                out.append("mode1_macro_fracture:\(String(format: "%.2f", mode1MacroFracture))")
                out.append("mode1_macro_mutation:\(String(format: "%.2f", mode1MacroMutation))")
                out.append("mode1_macro_pitch_lock:\(String(format: "%.2f", mode1MacroPitchLock))")
                out.append("mode1_wet_rms:\(String(format: "%.4f", mode1WetRMS))")
            } else if controlCurrent.mode == 2 {
                out.append("mode2_freeze:\(mode2State.freezeSamplesRemaining > 0 ? 1 : 0)")
                out.append("mode2_voices:\(mode2State.grains.filter { $0.active }.count)")
            } else if controlCurrent.mode == 4 {
                out.append("performer_session_id:\(mode4SessionId)")
                out.append("mode4_gesture_type:\(controlCurrent.gestureTypeId)")
                out.append("mode4_bank:\(mode4LibraryBankId)")
                out.append("mode4_samples_loaded:\(mode4SampleLibrary.count)")
                out.append("mode4_active_voices:\(mode4ActiveVoices)")
                if mode4NoSamplesDryOnly {
                    out.append("mode4_no_samples_dry_only")
                }
                if !mode4LoadInterventions.isEmpty {
                    out.append(contentsOf: mode4LoadInterventions.prefix(6))
                }
            } else if controlCurrent.mode == 5 || controlCurrent.mode == 6 {
                out.append("mode\(controlCurrent.mode)_inst:\(controlCurrent.midiInstId)")
                out.append("mode\(controlCurrent.mode)_chord:\(controlCurrent.chordSetId)")
                out.append("mode\(controlCurrent.mode)_voices:\(resonVoices.filter { $0.active }.count)")
                out.append("mode\(controlCurrent.mode)_inst_source:\(resonCurrentInstrument.sourceKind)")
                out.append("mode\(controlCurrent.mode)_sample_zones:\(resonCurrentInstrument.sampleZones.count)")
                out.append("mode\(controlCurrent.mode)_source_ref:\(resonCurrentInstrument.sourceRef)")
                out.append("mode\(controlCurrent.mode)_spawns:\(resonSpawnCount)")
                out.append("mode\(controlCurrent.mode)_rms:\(String(format: "%.4f", resonLastOutputRMS))")
                out.append("mode\(controlCurrent.mode)_reactive_gate:\(resonReactiveGateSamples > 0 ? 1 : 0)")
                out.append("mode\(controlCurrent.mode)_input_level:\(String(format: "%.3f", resonInputLevel))")
                out.append("mode\(controlCurrent.mode)_silent:\(resonIsSilent ? 1 : 0)")
                out.append("mode\(controlCurrent.mode)_desired_voices:\(resonDesiredVoices)")
                out.append("mode\(controlCurrent.mode)_last_midi:\(resonLastMidi)")
                if !mode56LoadInterventions.isEmpty {
                    out.append(contentsOf: mode56LoadInterventions.suffix(6))
                }
            } else if controlCurrent.mode == 7 {
                out.append("mode7_mapping_id:\(controlCurrent.mappingId)")
                out.append("mode7_wet:\(String(format: "%.3f", controlCurrent.wetLevel))")
                out.append("mode7_clock_conf:\(String(format: "%.2f", mode7State.clock.confidence))")
                out.append("mode7_step_samples:\(mode7State.clock.stepSamples(sampleRate: sampleRate, swapRateNorm: Float(controlCurrent.morphRate)))")
                out.append("mode7_crossfade_samples:\(mode7State.scheduler.crossfadeSamples)")
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

    private func isLowLatencyIncomingMode(_ mode: Int) -> Bool {
        mode == 1 || mode == 2 || mode == 3
    }

    private func pendingGestureSamples(outgoingMode: Int, incomingMode: Int) -> Int {
        var base: Int
        switch outgoingMode {
        case 1:
            switch mode1State {
            case .live:
                base = Int(sampleRate * 0.09)
            case .hold:
                base = min(max(mode1HoldSamplesRemaining, Int(sampleRate * 0.06)), Int(sampleRate * 0.35))
            case .fade:
                base = min(max(mode1FadeSamplesRemaining, Int(sampleRate * 0.04)), Int(sampleRate * 0.28))
            case .mute:
                base = Int(sampleRate * 0.04)
            }
            if mode1ShardVoices.contains(where: { $0.active }) || mode1PitchVoices.contains(where: { $0.active }) {
                base = max(base, Int(sampleRate * 0.08))
            } else {
                base = min(base, Int(sampleRate * 0.06))
            }
        case 4:
            if mode4ActiveVoices > 0 {
                var maxRemaining = 0
                for v in mode4Voices where v.active {
                    maxRemaining = max(maxRemaining, max(0, v.length - v.age))
                }
                base = min(max(maxRemaining, Int(sampleRate * 0.10)), Int(sampleRate * 0.50))
            } else {
                base = Int(sampleRate * 0.08)
            }
        case 5, 6:
            var maxRemaining = 0
            for v in resonVoices where v.active {
                let left = (v.sustainSamples + v.releaseSamples) - v.age
                maxRemaining = max(maxRemaining, max(0, left))
            }
            if maxRemaining > 0 {
                base = min(max(maxRemaining, Int(sampleRate * 0.08)), Int(sampleRate * 0.45))
            } else {
                base = Int(sampleRate * 0.07)
            }
        case 7:
            base = Int(sampleRate * 0.18)
        default:
            base = Int(sampleRate * 0.05)
        }
        if isLowLatencyIncomingMode(incomingMode) {
            return min(base, Int(sampleRate * 0.055))
        }
        return base
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
        var fadeSec: Float
        switch outgoing {
        case 4, 7:
            fadeSec = 0.22
        case 1:
            fadeSec = 0.14
        default:
            fadeSec = 0.08
        }
        if isLowLatencyIncomingMode(next.mode) {
            fadeSec = min(fadeSec, 0.055)
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
        let routeProfile = stateLock.withLock { inputRouteProfile }
        let activeMask = InputChannelRouter.sanitizedMask(routeProfile.activeChannels, channelCount: channels)
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            mono[i] = InputChannelRouter.mixedSample(
                channelCount: channels,
                activeMask: activeMask,
                channelGainDb: routeProfile.channelGainDb
            ) { ch in
                channelData[ch][i]
            }
        }
        ingestMonoInputSamples(mono, inputSampleRate: max(8_000, Float(buffer.format.sampleRate)))
    }

    func ingestInput(audioBufferList: UnsafePointer<AudioBufferList>, frameCount: Int, sampleRate inputSampleRate: Float) {
        let binding = RawInputChannelBinding(audioBuffers: audioBufferList)
        let channels = binding.channelCount
        guard frameCount > 0, channels > 0 else { return }
        let routeProfile = stateLock.withLock { inputRouteProfile }
        let activeMask = InputChannelRouter.sanitizedMask(routeProfile.activeChannels, channelCount: channels)
        var mono = [Float](repeating: 0, count: frameCount)
        for frameIndex in 0..<frameCount {
            mono[frameIndex] = InputChannelRouter.mixedSample(
                channelCount: channels,
                activeMask: activeMask,
                channelGainDb: routeProfile.channelGainDb
            ) { ch in
                binding.sample(channelIndex: ch, frameIndex: frameIndex)
            }
        }
        ingestMonoInputSamples(mono, inputSampleRate: max(8_000, inputSampleRate))
    }

    private func ingestMonoInputSamples(_ mono: [Float], inputSampleRate: Float) {
        guard !mono.isEmpty else { return }

        ringLock.lock()
        let backlog = ringDistanceSamples(read: ringRead, write: ringWrite, capacity: inputRing.count)
        ringLock.unlock()

        let backlogError = targetInputLagSamples - backlog
        let correction = max(-0.03, min(0.03, Float(backlogError) / Float(max(1, targetInputLagSamples)) * 0.03))
        let resampled = InputResampler.resample(
            samples: mono,
            sourceSampleRate: inputSampleRate,
            outputSampleRate: sampleRate,
            correction: correction,
            state: &inputResampleState
        )

        ringLock.lock()
        let cap = inputRing.count
        var write = ringWrite
        var read = ringRead
        for sample in resampled {
            inputRing[write] = sample
            write += 1
            if write >= cap { write = 0 }
            if write == read {
                read += 1
                if read >= cap { read = 0 }
            }
        }
        let lagSamples = ringDistanceSamples(read: read, write: write, capacity: cap)
        if lagSamples > maxInputLagSamples {
            read = advanceRingIndex(read, by: lagSamples - maxInputLagSamples, capacity: cap)
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
        stateLock.withLock {
            if pendingInputFlush {
                flushInputRingToLive()
                pendingInputFlush = false
            }
            // Keep render-time lock order consistent with live input ingest:
            // stateLock -> ringLock. The previous ringLock -> stateLock path
            // could deadlock the hardware callback before diagnostics updated.
            copyInputFrames(into: &inputScratch, frames: frames)
        }

        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !abl.isEmpty else { return }
        let outputBinding = OutputChannelBinding(audioBuffers: abl)
        guard outputBinding.channelCount > 0 else { return }

        stateLock.withLock {
            outputRenderCallbackCounter &+= 1
            outputRenderBufferCount = abl.count
            outputRenderSlotCount = outputBinding.channelCount
            outputRenderFrameCount = frames
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

                advanceExternalInputGainLocked()
                advancePianoTunerDuckLocked()
                advanceSirenGainLocked()

                let input = inputScratch[n] * externalInputGainCurrent
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
                    let glitchOut = processMode1(input: input, analysisInput: hp, interventions: &interventions)
                    let mode1IsActiveTarget: Float = mode1State == .mute ? 0.0 : 1.0
                    mode1WetFloorState += 0.028 * (mode1IsActiveTarget - mode1WetFloorState)
                    let liveDryTarget: Float = mode1State == .live ? 1.0 : 0.0
                    mode1DryDuckState += 0.015 * (liveDryTarget - mode1DryDuckState)
                    let stateWetFloor: Float
                    switch mode1State {
                    case .live: stateWetFloor = 0.76
                    case .hold: stateWetFloor = 0.84
                    case .fade: stateWetFloor = 0.68
                    case .mute: stateWetFloor = 0.0
                    }
                    let dryAnchor = (0.010 + 0.055 * mode1DryDuckState) * (mode1State == .mute ? 0.0 : 1.0)
                    let dryBoost = 0.88 + 0.05 * mode1DryAttackBoost
                    let wetLevelEff = min(1.0, max(Float(controlCurrent.wetLevel), stateWetFloor * mode1WetFloorState))
                    let spectralLift = 1.55 + (0.80 * mode1MacroMutation) + (0.25 * mode1MacroFracture)
                    dryMono = hp * Float(controlCurrent.dryLevel) * dryAnchor * dryBoost
                    fxMono = glitchOut * wetLevelEff * spectralLift
                    reverbSend = (dryMono * 0.02) + (fxMono * 0.42)
                    placeMode1Object(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 2:
                    let gran = processGranulator(input: hp, cpuAction: activeCpu, interventions: &interventions)
                    let mode2DryBoost = 1.0 + 0.14 * mode2State.transientDuck
                    let mode2WetDuck = max(0.50, 1.0 - 0.44 * mode2State.transientDuck)
                    let densityBias = Float(controlCurrent.grainDensity)
                    let densityWetTrim = 1.0 - 0.24 * max(0, densityBias - 0.55)
                    dryMono = hp * Float(controlCurrent.dryLevel) * mode2DryBoost
                    fxMono = gran * Float(controlCurrent.wetLevel) * mode2WetDuck * densityWetTrim
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
                    let wet = processMode3(input: hp)
                    // Mode 3 should be effect-forward; keep only a light dry anchor.
                    dryMono = hp * Float(min(0.22, max(0.0, controlCurrent.dryLevel * 0.35)))
                    fxMono = wet * Float(min(1.0, max(0.55, controlCurrent.wetLevel * 1.80)))
                    reverbSend = (fxMono * 0.03) + (dryMono * 0.02)
                    placeMainObject(
                        sample: dryMono + fxMono,
                        spread: Float(controlCurrent.spread),
                        motionSpeed: Float(controlCurrent.motionSpeed),
                        radius: Float(controlCurrent.motionRadius),
                        mode: mode,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
                    )

                case 4:
                    prepareMode46DispatchTransition(to: 4)
                    processMode4(
                        input: hp,
                        interventions: &interventions,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )

                case 5:
                    prepareMode46DispatchTransition(to: 5)
                    swap(&mode4SampleLibrary, &mode56SampleLibrary)
                    swap(&mode4CategoryToIndices, &mode56CategoryToIndices)
                    processMode4(
                        input: hp,
                        interventions: &interventions,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )
                    swap(&mode4SampleLibrary, &mode56SampleLibrary)
                    swap(&mode4CategoryToIndices, &mode56CategoryToIndices)

                case 6:
                    prepareMode46DispatchTransition(to: 6)
                    swap(&mode4SampleLibrary, &mode56SampleLibrary)
                    swap(&mode4CategoryToIndices, &mode56CategoryToIndices)
                    processMode4(
                        input: hp,
                        interventions: &interventions,
                        &ch0, &ch1, &ch2, &ch3, &ch4, &ch5,
                        reverbSend: &reverbSend
                    )
                    swap(&mode4SampleLibrary, &mode56SampleLibrary)
                    swap(&mode4CategoryToIndices, &mode56CategoryToIndices)
                    // Mode 6 keeps the wet+dry dichotomy — bleed a little input bed under the sampled voices.
                    let hasMode6Voices = mode4Voices.contains(where: { $0.active })
                    if hasMode6Voices {
                        let dry = hp * Float(controlCurrent.dryLevel) * 0.15
                        ch1 += dry * 0.5
                        ch4 += dry * 0.5
                    }

                case 7:
                    let swapped = processMode7(input: hp)
                    dryMono = hp * min(Float(controlCurrent.dryLevel), 0.03)
                    fxMono = swapped * max(0.95, min(1.45, Float(controlCurrent.wetLevel) * 1.32))
                    reverbSend = fxMono * 0.010
                    if fb.active {
                        // Mode 7 can build narrowband room loops quickly; use stronger wet ducking.
                        let mode7FeedbackDuck = max(0.04, min(0.82, fb.wetScale * fb.wetScale * 0.52))
                        fxMono *= mode7FeedbackDuck
                        reverbSend = 0
                    }
                    placeMainObject(
                        sample: dryMono + fxMono,
                        spread: max(0.60, Float(controlCurrent.spread)),
                        motionSpeed: max(0.28, Float(controlCurrent.motionSpeed)),
                        radius: max(0.44, Float(controlCurrent.motionRadius)),
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
                    reverbWet = processMode3ReverbClamp(input: reverbWet)
                } else if controlCurrent.mode == 7 {
                    // Keep Mode 7 character dominated by redistribution, not room wash.
                    // If feedback guard is active, force room send fully down for this frame.
                    reverbWet *= fb.active ? 0.0 : 0.12
                }
                let diffuse = reverbWet * 0.408
                ch0 += diffuse
                ch1 += diffuse
                ch2 += diffuse
                ch3 += diffuse
                ch4 += diffuse
                ch5 += diffuse

                let sirenMono = nextSirenRawSampleLocked() * sirenGainCurrent
                if abs(sirenMono) > 0.000_001 {
                    // Keep attract playback broad and room-legible without relying on a single speaker pair.
                    ch0 += sirenMono * 0.40
                    ch1 += sirenMono * 0.52
                    ch2 += sirenMono * 0.40
                    ch3 += sirenMono * 0.40
                    ch4 += sirenMono * 0.52
                    ch5 += sirenMono * 0.40
                }

                let master = Float(controlCurrent.level) * modeFade * feedbackLevelScale * transitionSafetyScale * pianoTunerDuckCurrent
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

                let preRoutePeak = max6(abs(ch0), abs(ch1), abs(ch2), abs(ch3), abs(ch4), abs(ch5))
                outputRenderPreRoutePeak = max(outputRenderPreRoutePeak, preRoutePeak)

                let postRoutePeak = routeAndWriteOutputs(
                    virtual0: ch0, virtual1: ch1, virtual2: ch2,
                    virtual3: ch3, virtual4: ch4, virtual5: ch5,
                    frameIndex: n,
                    outputBinding: outputBinding
                )
                outputRenderPostRoutePeak = max(outputRenderPostRoutePeak, postRoutePeak)

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

    private func rebuildOutputDelayBuffers() {
        let maxDelaySamples = max(0, Int((OutputRoutingProfile.maxDelayMs / 1000.0) * Double(sampleRate)))
        outputDelayCapacity = max(1, maxDelaySamples + 2)
        outputDelayBuffers = Array(
            repeating: Array(repeating: 0, count: outputDelayCapacity),
            count: OutputRoutingProfile.virtualChannelCount
        )
        outputDelayWrite = Array(repeating: 0, count: OutputRoutingProfile.virtualChannelCount)
        if outputPhysicalScratch.count < max(1, outputHardwareChannels) {
            outputPhysicalScratch = Array(repeating: 0, count: max(1, outputHardwareChannels))
        }
    }

    private func routeAndWriteOutputs(
        virtual0: Float,
        virtual1: Float,
        virtual2: Float,
        virtual3: Float,
        virtual4: Float,
        virtual5: Float,
        frameIndex: Int,
        outputBinding: OutputChannelBinding
    ) -> Float {
        let hardwareChannelCount = max(1, outputBinding.channelCount)
        if outputPhysicalScratch.count < hardwareChannelCount {
            outputPhysicalScratch = Array(repeating: 0, count: hardwareChannelCount)
        }
        for idx in 0..<hardwareChannelCount {
            outputPhysicalScratch[idx] = 0
        }

        var v0 = virtual0
        var v1 = virtual1
        var v2 = virtual2
        var v3 = virtual3
        var v4 = virtual4
        var v5 = virtual5

        if outputTestActive {
            v0 = 0; v1 = 0; v2 = 0; v3 = 0; v4 = 0; v5 = 0
            let sample = nextOutputTestSample()
            switch outputTestCurrentChannel {
            case 0: v0 = sample
            case 1: v1 = sample
            case 2: v2 = sample
            case 3: v3 = sample
            case 4: v4 = sample
            default: v5 = sample
            }
        }

        let c0 = calibratedVirtualSample(v0, virtualIndex: 0)
        let c1 = calibratedVirtualSample(v1, virtualIndex: 1)
        let c2 = calibratedVirtualSample(v2, virtualIndex: 2)
        let c3 = calibratedVirtualSample(v3, virtualIndex: 3)
        let c4 = calibratedVirtualSample(v4, virtualIndex: 4)
        let c5 = calibratedVirtualSample(v5, virtualIndex: 5)

        let master = powf(10.0, Float(outputProfile.masterGainDb) / 20.0)
        var postPeak: Float = 0
        if outputRouteMode == .gallery6Locked {
            mixVirtualToPhysical(c0, virtualIndex: 0, outCount: hardwareChannelCount)
            mixVirtualToPhysical(c1, virtualIndex: 1, outCount: hardwareChannelCount)
            mixVirtualToPhysical(c2, virtualIndex: 2, outCount: hardwareChannelCount)
            mixVirtualToPhysical(c3, virtualIndex: 3, outCount: hardwareChannelCount)
            mixVirtualToPhysical(c4, virtualIndex: 4, outCount: hardwareChannelCount)
            mixVirtualToPhysical(c5, virtualIndex: 5, outCount: hardwareChannelCount)
            for idx in 0..<hardwareChannelCount {
                let sample = hardClip(outputPhysicalScratch[idx] * master)
                outputBinding.write(channelIndex: idx, frameIndex: frameIndex, sample: sample)
                postPeak = max(postPeak, abs(sample))
                if idx < OutputRoutingProfile.virtualChannelCount {
                    outputHardwareMeterPeaks[idx] = max(outputHardwareMeterPeaks[idx], abs(sample))
                }
            }
        } else if hardwareChannelCount >= 2 {
            let stereo = GridSpatializer.downmixStereo(from6: [c0, c1, c2, c3, c4, c5])
            let left = hardClip(stereo.left * master)
            let right = hardClip(stereo.right * master)
            outputBinding.write(channelIndex: 0, frameIndex: frameIndex, sample: left)
            outputBinding.write(channelIndex: 1, frameIndex: frameIndex, sample: right)
            postPeak = max(abs(left), abs(right))
            outputHardwareMeterPeaks[0] = max(outputHardwareMeterPeaks[0], abs(left))
            outputHardwareMeterPeaks[1] = max(outputHardwareMeterPeaks[1], abs(right))
            if hardwareChannelCount > 2 {
                for idx in 2..<hardwareChannelCount {
                    outputBinding.write(channelIndex: idx, frameIndex: frameIndex, sample: 0)
                }
            }
        } else {
            let mono = ((c0 + c1 + c2 + c3 + c4 + c5) / 6.0) * master
            let sample = hardClip(mono)
            outputBinding.write(channelIndex: 0, frameIndex: frameIndex, sample: sample)
            postPeak = abs(sample)
            outputHardwareMeterPeaks[0] = max(outputHardwareMeterPeaks[0], abs(sample))
        }
        return postPeak
    }

    private func calibratedVirtualSample(_ input: Float, virtualIndex: Int) -> Float {
        guard virtualIndex >= 0, virtualIndex < outputProfile.channels.count else { return input }
        let cal = outputProfile.channels[virtualIndex]
        if outputHasSolo && !cal.solo { return 0 }
        if cal.muted { return 0 }

        var value = input
        if cal.polarityInverted {
            value = -value
        }
        value *= powf(10.0, Float(cal.gainDb) / 20.0)
        let delaySamples = max(0, min(outputDelayCapacity - 1, Int((cal.delayMs / 1000.0) * Double(sampleRate))))
        return processOutputDelay(value, virtualIndex: virtualIndex, delaySamples: delaySamples)
    }

    private func processOutputDelay(_ input: Float, virtualIndex: Int, delaySamples: Int) -> Float {
        guard virtualIndex >= 0, virtualIndex < outputDelayBuffers.count else { return input }
        guard outputDelayCapacity > 1 else { return input }
        var write = outputDelayWrite[virtualIndex]
        outputDelayBuffers[virtualIndex][write] = input
        var read = write - delaySamples
        if read < 0 {
            read += outputDelayCapacity * ((-read / outputDelayCapacity) + 1)
        }
        read %= outputDelayCapacity
        let delayed = outputDelayBuffers[virtualIndex][read]
        write += 1
        if write >= outputDelayCapacity {
            write = 0
        }
        outputDelayWrite[virtualIndex] = write
        return delayed
    }

    private func mixVirtualToPhysical(_ sample: Float, virtualIndex: Int, outCount: Int) {
        guard outCount > 0 else { return }
        guard virtualIndex >= 0, virtualIndex < outputProfile.channels.count else { return }
        let mapped = outputProfile.channels[virtualIndex].hardwareOutput
        let hwIndex = max(0, min(outCount - 1, mapped - 1))
        outputPhysicalScratch[hwIndex] += sample
    }

    private func nextOutputTestSample() -> Float {
        guard outputTestActive else { return 0 }
        if outputTestGapRemaining > 0 {
            outputTestGapRemaining -= 1
            return 0
        }
        if outputTestBurstRemaining <= 0 {
            outputTestBurstRemaining = max(1, outputTestBurstSamples)
        }

        outputTestRng = outputTestRng &* 6364136223846793005 &+ 1442695040888963407
        let white = (Float((outputTestRng >> 33) & 0xFFFF_FFFF) / Float(UInt32.max)) * 2.0 - 1.0
        outputTestPinkA = 0.99765 * outputTestPinkA + 0.0990460 * white
        outputTestPinkB = 0.96300 * outputTestPinkB + 0.2965164 * white
        let pink = (outputTestPinkA + outputTestPinkB + (0.164 * white)) * 0.35

        outputTestBurstRemaining -= 1
        if outputTestBurstRemaining <= 0 {
            outputTestGapRemaining = max(1, outputTestGapSamples)
            if outputTestScanAll {
                outputTestCurrentChannel = (outputTestCurrentChannel + 1) % OutputRoutingProfile.virtualChannelCount
            } else {
                outputTestCurrentChannel = outputTestChannelIndex
            }
        }
        return pink * outputTestLevelLinear
    }

    private func advanceExternalInputGainLocked() {
        if externalInputGainRampRemaining > 0 {
            externalInputGainCurrent += externalInputGainStep
            externalInputGainRampRemaining -= 1
            if externalInputGainRampRemaining <= 0 {
                externalInputGainCurrent = externalInputGainTarget
                externalInputGainStep = 0
            }
        } else {
            externalInputGainCurrent = externalInputGainTarget
        }
        externalInputGainCurrent = min(max(externalInputGainCurrent, 0.0), 1.0)
    }

    private func advancePianoTunerDuckLocked() {
        if pianoTunerDuckRampRemaining > 0 {
            pianoTunerDuckCurrent += pianoTunerDuckStep
            pianoTunerDuckRampRemaining -= 1
            if pianoTunerDuckRampRemaining <= 0 {
                pianoTunerDuckCurrent = pianoTunerDuckTarget
                pianoTunerDuckStep = 0
            }
        } else {
            pianoTunerDuckCurrent = pianoTunerDuckTarget
        }
        pianoTunerDuckCurrent = min(max(pianoTunerDuckCurrent, 0.0), 1.0)
    }

    private func advanceSirenGainLocked() {
        if sirenGainRampRemaining > 0 {
            sirenGainCurrent += sirenGainStep
            sirenGainRampRemaining -= 1
            if sirenGainRampRemaining <= 0 {
                sirenGainCurrent = sirenGainTarget
                sirenGainStep = 0
            }
        } else {
            sirenGainCurrent = sirenGainTarget
        }
        sirenGainCurrent = min(max(sirenGainCurrent, 0.0), max(0.0, sirenNominalGain))

        if !sirenActiveTarget && sirenGainCurrent <= 0.000_01 {
            sirenTrackIndex = -1
            sirenPlayhead = 0
            sirenPlayStep = 1
        }
    }

    private func sirenReshuffleOrderLocked() {
        sirenOrder = Array(0..<sirenTracks.count)
        guard sirenOrder.count > 1 else {
            sirenOrderCursor = 0
            return
        }
        for i in stride(from: sirenOrder.count - 1, through: 1, by: -1) {
            sirenRng = sirenRng &* 6364136223846793005 &+ 1442695040888963407
            let j = Int((sirenRng >> 33) % UInt64(i + 1))
            if i != j {
                sirenOrder.swapAt(i, j)
            }
        }
        sirenOrderCursor = 0
    }

    private func nextSirenTrackIndexLocked() -> Int {
        guard !sirenOrder.isEmpty else { return -1 }
        if sirenOrderCursor >= sirenOrder.count {
            sirenReshuffleOrderLocked()
        }
        guard !sirenOrder.isEmpty else { return -1 }
        let index = sirenOrder[sirenOrderCursor]
        sirenOrderCursor += 1
        return index
    }

    private func nextSirenRawSampleLocked() -> Float {
        guard !sirenTracks.isEmpty else { return 0 }
        guard sirenActiveTarget || sirenGainCurrent > 0.000_01 else { return 0 }

        if sirenTrackIndex < 0 || sirenTrackIndex >= sirenTracks.count {
            sirenTrackIndex = nextSirenTrackIndexLocked()
            sirenPlayhead = 0
            if sirenTrackIndex >= 0 {
                sirenPlayStep = sirenTracks[sirenTrackIndex].sampleRate / max(8_000.0, sampleRate)
            }
        }
        guard sirenTrackIndex >= 0, sirenTrackIndex < sirenTracks.count else { return 0 }

        let track = sirenTracks[sirenTrackIndex]
        if track.samples.count < 2 {
            sirenTrackIndex = nextSirenTrackIndexLocked()
            sirenPlayhead = 0
            if sirenTrackIndex >= 0 {
                sirenPlayStep = sirenTracks[sirenTrackIndex].sampleRate / max(8_000.0, sampleRate)
            }
            return 0
        }

        let i0 = Int(sirenPlayhead)
        if i0 >= track.samples.count - 1 {
            sirenTrackIndex = nextSirenTrackIndexLocked()
            sirenPlayhead = 0
            if sirenTrackIndex >= 0 {
                sirenPlayStep = sirenTracks[sirenTrackIndex].sampleRate / max(8_000.0, sampleRate)
            }
            return 0
        }

        let i1 = min(track.samples.count - 1, i0 + 1)
        let frac = sirenPlayhead - Float(i0)
        let sample = track.samples[i0] + ((track.samples[i1] - track.samples[i0]) * frac)
        sirenPlayhead += max(0.05, sirenPlayStep)
        if sirenPlayhead >= Float(track.samples.count - 1) {
            sirenTrackIndex = nextSirenTrackIndexLocked()
            sirenPlayhead = 0
            if sirenTrackIndex >= 0 {
                sirenPlayStep = sirenTracks[sirenTrackIndex].sampleRate / max(8_000.0, sampleRate)
            }
        }
        return sample
    }

    private func copyInputFrames(into out: inout [Float], frames: Int) {
        ringLock.lock()
        let cap = inputRing.count
        var read = ringRead
        let write = ringWrite
        let lagSamples = ringDistanceSamples(read: read, write: write, capacity: cap)
        if lagSamples > maxInputLagSamples {
            read = advanceRingIndex(read, by: lagSamples - maxInputLagSamples, capacity: cap)
        }
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

    private func ringDistanceSamples(read: Int, write: Int, capacity: Int) -> Int {
        if write >= read {
            return write - read
        }
        return (capacity - read) + write
    }

    private func advanceRingIndex(_ index: Int, by delta: Int, capacity: Int) -> Int {
        guard capacity > 0 else { return 0 }
        var out = index + delta
        if out >= capacity {
            out %= capacity
        }
        return out
    }

    private func flushInputRingToLive() {
        ringLock.lock()
        ringRead = ringWrite
        ringLock.unlock()
    }

    private func inputBacklogMs() -> Float {
        ringLock.lock()
        let backlog = ringDistanceSamples(read: ringRead, write: ringWrite, capacity: inputRing.count)
        ringLock.unlock()
        return (Float(backlog) * 1000.0) / max(1.0, sampleRate)
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
        controlCurrent.grainPitchSpread += Double(slew) * (controlTarget.grainPitchSpread - controlCurrent.grainPitchSpread)
        controlCurrent.freezeProb += Double(slew) * (controlTarget.freezeProb - controlCurrent.freezeProb)
        controlCurrent.freezeLenSec += Double(slew) * (controlTarget.freezeLenSec - controlCurrent.freezeLenSec)
        controlCurrent.repeatProb += Double(slew) * (controlTarget.repeatProb - controlCurrent.repeatProb)
        controlCurrent.thresholdBias += Double(slew) * (controlTarget.thresholdBias - controlCurrent.thresholdBias)
        controlCurrent.windowNorm += Double(slew) * (controlTarget.windowNorm - controlCurrent.windowNorm)
        controlCurrent.stutterLenNorm += Double(slew) * (controlTarget.stutterLenNorm - controlCurrent.stutterLenNorm)
        controlCurrent.gateSharpness += Double(slew) * (controlTarget.gateSharpness - controlCurrent.gateSharpness)
        controlCurrent.motionIntensity += Double(slew) * (controlTarget.motionIntensity - controlCurrent.motionIntensity)
        controlCurrent.mode1Fracture += Double(slew) * (controlTarget.mode1Fracture - controlCurrent.mode1Fracture)
        controlCurrent.mode1Mutation += Double(slew) * (controlTarget.mode1Mutation - controlCurrent.mode1Mutation)
        controlCurrent.mode1PitchLock += Double(slew) * (controlTarget.mode1PitchLock - controlCurrent.mode1PitchLock)
        controlCurrent.mode1HoldLenSec += Double(slew) * (controlTarget.mode1HoldLenSec - controlCurrent.mode1HoldLenSec)
        controlCurrent.mode1TailFadeMs += Double(slew) * (controlTarget.mode1TailFadeMs - controlCurrent.mode1TailFadeMs)
        controlCurrent.mode1SceneRateHz += Double(slew) * (controlTarget.mode1SceneRateHz - controlCurrent.mode1SceneRateHz)
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
        controlCurrent.mode1SceneId = controlTarget.mode1SceneId
        controlCurrent.mode1ClearRequest = controlTarget.mode1ClearRequest
        controlCurrent.mode1JoltRequest = controlTarget.mode1JoltRequest
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

    private func mode4AssetRoots() -> [URL] {
        var roots: [URL] = []
        if let dir = ManifestCatalog.shared.sourceDirectory {
            roots.append(dir)
            roots.append(dir.deletingLastPathComponent())
        }
        if let resource = Bundle.main.resourceURL {
            roots.append(resource)
        }
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        roots.append(sourceDir)
        roots.append(sourceDir.deletingLastPathComponent())

        var unique: [URL] = []
        var seen: Set<String> = []
        for root in roots {
            let key = root.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(root)
        }
        return unique
    }

    private func resolveMode4AssetURL(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fm = FileManager.default
        if trimmed.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: trimmed)
            return fm.isReadableFile(atPath: absolute.path) ? absolute : nil
        }

        for root in mode4AssetRoots() {
            let candidate = root.appendingPathComponent(trimmed)
            if fm.isReadableFile(atPath: candidate.path) {
                return candidate
            }
            let basenameCandidate = root.appendingPathComponent((trimmed as NSString).lastPathComponent)
            if fm.isReadableFile(atPath: basenameCandidate.path) {
                return basenameCandidate
            }
        }
        return nil
    }

    private func mode4IsAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "wav" || ext == "aif" || ext == "aiff" || ext == "caf" || ext == "m4a" || ext == "mp3"
    }

    private func mode4FallbackDirectories(bankId: String, manifestAssets: [BankAsset]) -> [String] {
        var preferredDirs: [String] = []
        if bankId == "samples_A" {
            preferredDirs = [
                "TubCompanion/Samples",
                "Samples",
                "Samples/ultrachunk",
                "Samples/long_bank_gradient",
                "Assets/Samples/ultrachunk",
                "Assets/Samples/long_bank_gradient",
            ]
        }

        let manifestDirs = manifestAssets
            .map { ($0.path as NSString).deletingLastPathComponent }
            .filter { !$0.isEmpty }

        var merged: [String] = []
        var seen: Set<String> = []
        for raw in preferredDirs + manifestDirs {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                merged.append(key)
            }
        }
        return merged
    }

    private func mode4ScanFallbackAudioFiles(
        relativeDirectories: [String],
        includeAssetRootScan: Bool = true,
        stopAfterFirstDirectoryWithContent: Bool = false
    ) -> [URL] {
        let fm = FileManager.default
        let roots = mode4AssetRoots()
        var out: [URL] = []
        var seen: Set<String> = []

        let cleanedDirs = relativeDirectories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        @discardableResult
        func scanDirectory(_ dirURL: URL) -> Bool {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { return false }
            guard let entries = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return false }
            var found = false
            for entry in entries {
                guard mode4IsAudioFile(entry) else { continue }
                let key = entry.resolvingSymlinksInPath().standardizedFileURL.path
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(entry)
                found = true
            }
            return found
        }

        for dir in cleanedDirs {
            var foundInDir = false
            if dir.hasPrefix("/") {
                foundInDir = scanDirectory(URL(fileURLWithPath: dir, isDirectory: true))
            } else {
                for root in roots {
                    if scanDirectory(root.appendingPathComponent(dir, isDirectory: true)) {
                        foundInDir = true
                    }
                }
            }
            if stopAfterFirstDirectoryWithContent, foundInDir {
                break
            }
        }

        if includeAssetRootScan {
            for root in roots {
                _ = scanDirectory(root)
            }
        }

        out.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return out
    }

    private func mode4NormalizedAssetId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func mode4ExpandedAssets(bankId: String, manifestAssets: [BankAsset], fallbackPool: [URL]) -> [BankAsset] {
        guard bankId == "samples_A", !fallbackPool.isEmpty else {
            return manifestAssets
        }

        var merged = manifestAssets
        var seenIds = Set(manifestAssets.map { mode4NormalizedAssetId($0.id) })
        var seenBasenames = Set(manifestAssets.map { mode4PathBasename($0.path).lowercased() })

        for fileURL in fallbackPool {
            let basename = fileURL.lastPathComponent.lowercased()
            if seenBasenames.contains(basename) {
                continue
            }
            let derivedId = mode4NormalizedAssetId((basename as NSString).deletingPathExtension)
            if derivedId.isEmpty || seenIds.contains(derivedId) {
                continue
            }
            merged.append(
                BankAsset(
                    id: derivedId,
                    path: fileURL.path,
                    gain: nil,
                    category: "general"
                )
            )
            seenIds.insert(derivedId)
            seenBasenames.insert(basename)
        }

        return merged
    }

    private func mode4PathBasename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func mode4FilenameMatchesAssetId(filename: String, assetId: String) -> Bool {
        let base = (filename as NSString).deletingPathExtension.lowercased()
        return base == assetId.lowercased()
    }

    private func decodeMode4MonoSamples(from url: URL) throws -> (samples: [Float], sampleRate: Float) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(max(1, file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw NSError(domain: "Mode4SampleDecode", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        try file.read(into: buffer)

        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0 else {
            return ([], Float(format.sampleRate))
        }

        var mono = [Float](repeating: 0, count: frames)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            if format.isInterleaved {
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let mData = abl.first?.mData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 2, userInfo: [NSLocalizedDescriptionKey: "interleaved float data missing"])
                }
                let src = mData.assumingMemoryBound(to: Float.self)
                let inv = 1.0 / Float(channels)
                for n in 0..<frames {
                    var s: Float = 0
                    let base = n * channels
                    for ch in 0..<channels {
                        s += src[base + ch]
                    }
                    mono[n] = s * inv
                }
            } else {
                guard let src = buffer.floatChannelData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 2, userInfo: [NSLocalizedDescriptionKey: "float channel data missing"])
                }
                if channels == 1 {
                    mono.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress?.update(from: src[0], count: frames)
                    }
                } else {
                    let inv = 1.0 / Float(channels)
                    for n in 0..<frames {
                        var s: Float = 0
                        for ch in 0..<channels { s += src[ch][n] }
                        mono[n] = s * inv
                    }
                }
            }

        case .pcmFormatInt16:
            let scale = 1.0 / Float(Int16.max)
            if format.isInterleaved {
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let mData = abl.first?.mData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 3, userInfo: [NSLocalizedDescriptionKey: "interleaved int16 data missing"])
                }
                let src = mData.assumingMemoryBound(to: Int16.self)
                let inv = 1.0 / Float(channels)
                for n in 0..<frames {
                    var s: Float = 0
                    let base = n * channels
                    for ch in 0..<channels {
                        s += Float(src[base + ch]) * scale
                    }
                    mono[n] = s * inv
                }
            } else {
                guard let src = buffer.int16ChannelData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 3, userInfo: [NSLocalizedDescriptionKey: "int16 channel data missing"])
                }
                if channels == 1 {
                    for n in 0..<frames { mono[n] = Float(src[0][n]) * scale }
                } else {
                    let inv = 1.0 / Float(channels)
                    for n in 0..<frames {
                        var s: Float = 0
                        for ch in 0..<channels { s += Float(src[ch][n]) * scale }
                        mono[n] = s * inv
                    }
                }
            }

        case .pcmFormatInt32:
            let scale = 1.0 / Float(Int32.max)
            if format.isInterleaved {
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let mData = abl.first?.mData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 4, userInfo: [NSLocalizedDescriptionKey: "interleaved int32 data missing"])
                }
                let src = mData.assumingMemoryBound(to: Int32.self)
                let inv = 1.0 / Float(channels)
                for n in 0..<frames {
                    var s: Float = 0
                    let base = n * channels
                    for ch in 0..<channels {
                        s += Float(src[base + ch]) * scale
                    }
                    mono[n] = s * inv
                }
            } else {
                guard let src = buffer.int32ChannelData else {
                    throw NSError(domain: "Mode4SampleDecode", code: 4, userInfo: [NSLocalizedDescriptionKey: "int32 channel data missing"])
                }
                if channels == 1 {
                    for n in 0..<frames { mono[n] = Float(src[0][n]) * scale }
                } else {
                    let inv = 1.0 / Float(channels)
                    for n in 0..<frames {
                        var s: Float = 0
                        for ch in 0..<channels { s += Float(src[ch][n]) * scale }
                        mono[n] = s * inv
                    }
                }
            }

        default:
            throw NSError(domain: "Mode4SampleDecode", code: 5, userInfo: [NSLocalizedDescriptionKey: "unsupported sample format"])
        }

        return (mono, Float(format.sampleRate))
    }

    private func analyzeMode4Clip(samples: [Float], sampleRate: Float) -> Mode4ClipAnalysis {
        let count = max(1, samples.count)
        var sumSq: Float = 0
        var sumAbs: Float = 0
        var peak: Float = 0
        var zc: Int = 0
        var diffAbs: Float = 0
        var safeCuts: [Int] = [0]
        safeCuts.reserveCapacity(max(512, count / 8))

        var lp: Float = 0
        let lowAlpha = min(0.20, max(0.001, (2.0 * Float.pi * 280.0) / max(8_000.0, sampleRate)))
        var lowSq: Float = 0
        var totalSq: Float = 0

        var prev = samples.first ?? 0
        var lastCut = 0
        for n in 0..<count {
            let x = samples[n]
            let ax = abs(x)
            sumSq += x * x
            sumAbs += ax
            peak = max(peak, ax)
            totalSq += x * x
            lp += lowAlpha * (x - lp)
            lowSq += lp * lp
            if n > 0 {
                if (prev <= 0 && x > 0) || (prev >= 0 && x < 0) || ax < 0.0015 {
                    zc += 1
                    if n - lastCut >= 8 {
                        safeCuts.append(n)
                        lastCut = n
                    }
                }
                diffAbs += abs(x - prev)
            }
            prev = x
        }
        if safeCuts.last != count - 1 {
            safeCuts.append(count - 1)
        }

        let rms = sqrtf(sumSq / Float(count))
        let zcr = Float(zc) / Float(max(1, count - 1))
        let hfRatio = diffAbs / max(1e-6, sumAbs)
        let brightness = max(0, min(1, 0.65 * min(1, hfRatio * 0.95) + 0.35 * min(1, zcr * 7.0)))
        let lowBandRatio = max(0, min(1, sqrtf(lowSq / max(totalSq, 1e-9))))

        let onsetWindow = max(64, min(2_048, Int(sampleRate * 0.018)))
        var flux: [(Int, Float)] = []
        flux.reserveCapacity(max(8, count / max(1, onsetWindow)))
        var prevEnergy: Float = 0
        var idx = 0
        while idx < count {
            let end = min(count, idx + onsetWindow)
            var e: Float = 0
            for i in idx..<end {
                let v = samples[i]
                e += v * v
            }
            e = sqrtf(e / Float(max(1, end - idx)))
            let f = max(0, e - prevEnergy)
            flux.append((idx, f))
            prevEnergy = e
            idx += onsetWindow
        }

        var onsetCandidates: [Int] = []
        if !flux.isEmpty {
            let sorted = flux.map(\.1).sorted()
            let p75 = sorted[Int(Float(sorted.count - 1) * 0.75)]
            let threshold = max(0.004, p75)
            for (frame, f) in flux where f >= threshold {
                onsetCandidates.append(frame)
            }
        }
        if onsetCandidates.isEmpty {
            let step = max(96, min(2_048, Int(sampleRate * 0.06)))
            var frame = 0
            while frame < count {
                onsetCandidates.append(frame)
                frame += step
            }
        }

        return Mode4ClipAnalysis(
            rms: rms,
            peak: peak,
            brightness: brightness,
            lowBandRatio: lowBandRatio,
            onsetCandidates: onsetCandidates,
            safeCutPoints: safeCuts
        )
    }

    private func normalizeMode4Category(_ raw: String?) -> String {
        guard let raw else { return "general" }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? "general" : cleaned
    }

    private func resetMode4RuntimeState() {
        mode4NoSamplesDryOnly = mode4SampleLibrary.isEmpty
        mode4RecentClipIndices.removeAll(keepingCapacity: true)
        mode4TriggerAccumulator = 0
        mode4PrevInput = 0
        mode4InputEnv = 0
        mode4LowTrack = 0
        mode4LowEnv = 0
        mode4HighEnv = 0
        mode4Noisiness = 0
        mode4LastTriggerSamplesAgo = 100_000
        for i in mode4Voices.indices {
            mode4Voices[i].active = false
        }
        mode4ActiveVoices = 0
    }

    private func reloadMode4SampleLibrary(bankId: String) {
        mode4LibraryBankId = bankId
        mode4SampleLibrary.removeAll(keepingCapacity: true)
        mode4CategoryToIndices.removeAll(keepingCapacity: true)
        mode4LoadInterventions.removeAll(keepingCapacity: true)
        mode4NoSamplesDryOnly = false
        mode4RecentClipIndices.removeAll(keepingCapacity: true)
        mode4TriggerAccumulator = 0
        mode4PrevInput = 0
        mode4InputEnv = 0
        mode4LowTrack = 0
        mode4LowEnv = 0
        mode4HighEnv = 0
        mode4Noisiness = 0
        mode4LastTriggerSamplesAgo = 100_000

        for i in mode4Voices.indices {
            mode4Voices[i].active = false
        }
        mode4ActiveVoices = 0

        guard let bank = ManifestCatalog.shared.banks[bankId], bank.type == .samples else {
            mode4NoSamplesDryOnly = true
            mode4LoadInterventions.append("mode4_no_samples_dry_only")
            mode4LoadInterventions.append("mode4_invalid_bank:\(bankId)")
            return
        }

        var loaded: [Mode4SampleClip] = []
        let fallbackDirs = mode4FallbackDirectories(bankId: bankId, manifestAssets: bank.assets)
        let preferUnifiedSamplesBank = bankId == "samples_A"
        let fallbackPool = mode4ScanFallbackAudioFiles(
            relativeDirectories: fallbackDirs,
            includeAssetRootScan: !preferUnifiedSamplesBank,
            stopAfterFirstDirectoryWithContent: preferUnifiedSamplesBank
        )
        var assetsToLoad = mode4ExpandedAssets(bankId: bankId, manifestAssets: bank.assets, fallbackPool: fallbackPool)
        if assetsToLoad.count > bank.assets.count {
            mode4LoadInterventions.append("mode4_asset_pool_expanded:\(bank.assets.count)->\(assetsToLoad.count)")
        }
        loaded.reserveCapacity(assetsToLoad.count)
        var fallbackCursor = 0
        var consumedFallback: Set<String> = []

        for asset in assetsToLoad {
            var resolvedURL = resolveMode4AssetURL(path: asset.path)
            var usedFallback = false
            if resolvedURL == nil {
                let desiredBasename = mode4PathBasename(asset.path).lowercased()
                if let matched = fallbackPool.first(where: { candidate in
                    let key = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                    if consumedFallback.contains(key) { return false }
                    let candidateName = candidate.lastPathComponent.lowercased()
                    return candidateName == desiredBasename || mode4FilenameMatchesAssetId(filename: candidate.lastPathComponent, assetId: asset.id)
                }) {
                    resolvedURL = matched
                    consumedFallback.insert(matched.resolvingSymlinksInPath().standardizedFileURL.path)
                }
            }
            if resolvedURL == nil {
                while fallbackCursor < fallbackPool.count {
                    let candidate = fallbackPool[fallbackCursor]
                    fallbackCursor += 1
                    let key = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                    if consumedFallback.contains(key) { continue }
                    consumedFallback.insert(key)
                    resolvedURL = candidate
                    usedFallback = true
                    mode4LoadInterventions.append("mode4_pick_fallback:\(asset.id)->\(candidate.lastPathComponent)")
                    break
                }
            }
            guard let url = resolvedURL else {
                mode4LoadInterventions.append("mode4_sample_missing:\(asset.id)")
                continue
            }
            do {
                let decoded = try decodeMode4MonoSamples(from: url)
                if decoded.samples.count < 64 {
                    mode4LoadInterventions.append("mode4_sample_too_short:\(asset.id)")
                    continue
                }
                let category = normalizeMode4Category(asset.category)
                let analysis = analyzeMode4Clip(samples: decoded.samples, sampleRate: decoded.sampleRate)
                let clip = Mode4SampleClip(
                    id: asset.id,
                    category: category,
                    gain: Float(asset.gain ?? 1.0),
                    sampleRate: max(8_000, decoded.sampleRate),
                    samples: decoded.samples,
                    analysis: analysis
                )
                loaded.append(clip)
                if !usedFallback {
                    consumedFallback.insert(url.resolvingSymlinksInPath().standardizedFileURL.path)
                }
            } catch {
                mode4LoadInterventions.append("mode4_sample_unreadable:\(asset.id)")
            }
        }

        mode4SampleLibrary = loaded
        for i in loaded.indices {
            mode4CategoryToIndices[loaded[i].category, default: []].append(i)
        }

        if mode4SampleLibrary.isEmpty {
            mode4NoSamplesDryOnly = true
            mode4LoadInterventions.append("mode4_no_samples_dry_only")
        }
        if mode4LoadInterventions.count > 16 {
            mode4LoadInterventions = Array(mode4LoadInterventions.prefix(16))
        }
    }

    private func prepareMode46DispatchTransition(to current: Int) {
        if mode46LastDispatchMode == current {
            return
        }
        // Any hop between {4,5,6} crosses a library boundary — stop in-flight voices so their
        // cached clipIndex can't resolve into the wrong library after the swap.
        let prior = mode46LastDispatchMode
        mode46LastDispatchMode = current
        guard prior == 4 || prior == 5 || prior == 6 else { return }
        guard current != prior else { return }
        for i in mode4Voices.indices {
            mode4Voices[i].active = false
        }
        mode4ActiveVoices = 0
        mode4RecentClipIndices.removeAll(keepingCapacity: true)
        mode4TriggerAccumulator = 0
        mode4LastTriggerSamplesAgo = 100_000
    }

    private func loadMode56SampleLibraryFromBundle() {
        mode56SampleLibrary.removeAll(keepingCapacity: true)
        mode56CategoryToIndices.removeAll(keepingCapacity: true)

        let urls = AudioEngineController.bundleSirenSongURLs()
        var loaded: [Mode4SampleClip] = []
        loaded.reserveCapacity(urls.count)
        for url in urls {
            do {
                let decoded = try decodeMode4MonoSamples(from: url)
                guard decoded.samples.count >= 64 else { continue }
                let analysis = analyzeMode4Clip(samples: decoded.samples, sampleRate: decoded.sampleRate)
                let clip = Mode4SampleClip(
                    id: url.deletingPathExtension().lastPathComponent,
                    category: "siren",
                    gain: 1.0,
                    sampleRate: max(8_000, decoded.sampleRate),
                    samples: decoded.samples,
                    analysis: analysis
                )
                loaded.append(clip)
            } catch {
                continue
            }
        }

        mode56SampleLibrary = loaded
        for i in loaded.indices {
            mode56CategoryToIndices[loaded[i].category, default: []].append(i)
        }
        mode56LibraryLoaded = true
    }

    private func stableSeed(for text: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        return h
    }

    private struct Mode1SceneProfile {
        let id: String
        let shardBias: Float
        let pitchBias: Float
        let mutationBias: Float
        let reverseBias: Float
        let dropoutBias: Float
        let ratchetPattern: [Int]
        let sizePatternMs: [Float]
    }

    private func mode1GridSamples() -> Int {
        mode1Clock.stepSamples(gridDiv: controlCurrent.gridDiv, sampleRate: sampleRate)
    }

    private func mode1WrappedIndex(_ index: Int) -> Int {
        var out = index % mode1Buffer.count
        if out < 0 { out += mode1Buffer.count }
        return out
    }

    private func mode1SampleLinear(_ position: Float) -> Float {
        let i0 = Int(floorf(position))
        let frac = position - Float(i0)
        let s0 = mode1Buffer[mode1WrappedIndex(i0)]
        let s1 = mode1Buffer[mode1WrappedIndex(i0 + 1)]
        return s0 + (s1 - s0) * frac
    }

    private func mode1CaptureSampleLinear(_ position: Float) -> Float {
        guard !mode1CaptureSliceBuffer.isEmpty else { return 0 }
        let count = mode1CaptureSliceBuffer.count
        let wrappedPos: Float = {
            if count == 1 { return 0 }
            let p = position.truncatingRemainder(dividingBy: Float(count))
            return p < 0 ? p + Float(count) : p
        }()
        let i0 = Int(floorf(wrappedPos))
        let frac = wrappedPos - Float(i0)
        let i1 = (i0 + 1) % count
        let s0 = mode1CaptureSliceBuffer[i0]
        let s1 = mode1CaptureSliceBuffer[i1]
        return s0 + (s1 - s0) * frac
    }

    private func mode1CaptureWindowEnergy(start: Int, length: Int) -> Float {
        let count = max(1, length)
        let stride = max(1, count / 2_048)
        var idx = start
        var sumAbs: Float = 0
        var n = 0
        while n < count {
            let wrapped = mode1WrappedIndex(idx)
            sumAbs += abs(mode1Buffer[wrapped])
            idx += stride
            n += stride
        }
        let samples = max(1, n / stride)
        return sumAbs / Float(samples)
    }

    private func mode1NearestZeroCross(_ index: Int, radius: Int) -> Int {
        let r = max(1, radius)
        var best = mode1WrappedIndex(index)
        var bestAbs = abs(mode1Buffer[best])
        for d in 1...r {
            let left = mode1WrappedIndex(index - d)
            let right = mode1WrappedIndex(index + d)
            let leftAbs = abs(mode1Buffer[left])
            let rightAbs = abs(mode1Buffer[right])
            if leftAbs < bestAbs {
                bestAbs = leftAbs
                best = left
            }
            if rightAbs < bestAbs {
                bestAbs = rightAbs
                best = right
            }
            if bestAbs < 0.0008 { break }
        }
        return best
    }

    private func mode1CaptureNearestZeroCross(_ index: Int, radius: Int) -> Int {
        guard !mode1CaptureSliceBuffer.isEmpty else { return 0 }
        let maxIdx = mode1CaptureSliceBuffer.count - 1
        let center = max(0, min(maxIdx, index))
        let r = max(1, radius)
        var best = center
        var bestAbs = abs(mode1CaptureSliceBuffer[center])
        for d in 1...r {
            let left = max(0, center - d)
            let right = min(maxIdx, center + d)
            let leftAbs = abs(mode1CaptureSliceBuffer[left])
            let rightAbs = abs(mode1CaptureSliceBuffer[right])
            if leftAbs < bestAbs {
                bestAbs = leftAbs
                best = left
            }
            if rightAbs < bestAbs {
                bestAbs = rightAbs
                best = right
            }
            if bestAbs < 0.0008 { break }
        }
        return best
    }

    private func mode1SceneFamily(repeatStyleId: String) -> [String] {
        if repeatStyleId.lowercased() == "stutter_b" {
            return ["databend", "spectral_melt", "void_strobe"]
        }
        return ["razor_gate", "arp_shred", "reverse_flock"]
    }

    private func mode1ResolveSceneId(baseSceneId: String, repeatStyleId: String) -> String {
        let normalized = baseSceneId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = ["razor_gate", "databend", "arp_shred", "reverse_flock", "spectral_melt", "void_strobe"]
        if allowed.contains(normalized) {
            return normalized
        }
        return mode1SceneFamily(repeatStyleId: repeatStyleId).first ?? "razor_gate"
    }

    private func mode1AdvanceScene(repeatStyleId: String) {
        let family = mode1SceneFamily(repeatStyleId: repeatStyleId)
        guard !family.isEmpty else { return }
        if let current = family.firstIndex(of: mode1SceneId) {
            mode1SceneId = family[(current + 1) % family.count]
        } else {
            mode1SceneId = family[0]
        }
    }

    private func mode1SceneProfile(for id: String) -> Mode1SceneProfile {
        switch id {
        case "databend":
            return Mode1SceneProfile(
                id: id,
                shardBias: 0.95,
                pitchBias: 0.36,
                mutationBias: 0.82,
                reverseBias: 0.48,
                dropoutBias: 0.26,
                ratchetPattern: [1, 2, 1, 3, 2, 1, 4, 2],
                sizePatternMs: [36, 54, 72, 98, 140, 84]
            )
        case "arp_shred":
            return Mode1SceneProfile(
                id: id,
                shardBias: 0.74,
                pitchBias: 0.88,
                mutationBias: 0.40,
                reverseBias: 0.18,
                dropoutBias: 0.18,
                ratchetPattern: [1, 1, 2, 1, 2, 3, 1, 2],
                sizePatternMs: [52, 78, 108, 144, 180, 96]
            )
        case "reverse_flock":
            return Mode1SceneProfile(
                id: id,
                shardBias: 0.88,
                pitchBias: 0.52,
                mutationBias: 0.50,
                reverseBias: 0.62,
                dropoutBias: 0.16,
                ratchetPattern: [1, 2, 1, 2, 1, 3, 1, 2],
                sizePatternMs: [44, 66, 88, 132, 176, 116]
            )
        case "spectral_melt":
            return Mode1SceneProfile(
                id: id,
                shardBias: 0.58,
                pitchBias: 0.66,
                mutationBias: 0.94,
                reverseBias: 0.30,
                dropoutBias: 0.20,
                ratchetPattern: [1, 1, 1, 2, 1, 2, 1, 3],
                sizePatternMs: [86, 112, 148, 220, 320, 164]
            )
        case "void_strobe":
            return Mode1SceneProfile(
                id: id,
                shardBias: 0.98,
                pitchBias: 0.20,
                mutationBias: 0.72,
                reverseBias: 0.74,
                dropoutBias: 0.42,
                ratchetPattern: [1, 3, 1, 4, 2, 1, 3, 2],
                sizePatternMs: [28, 34, 48, 60, 74, 92]
            )
        default:
            return Mode1SceneProfile(
                id: "razor_gate",
                shardBias: 0.86,
                pitchBias: 0.44,
                mutationBias: 0.56,
                reverseBias: 0.26,
                dropoutBias: 0.16,
                ratchetPattern: [1, 2, 1, 1, 2, 1, 3, 1],
                sizePatternMs: [34, 48, 64, 96, 120, 76]
            )
        }
    }

    private func mode1UpdatePitchTracker(_ input: Float) {
        mode1PitchZeroCrossCount += 1
        if mode1PitchPrevInput <= 0, input > 0 {
            let interval = mode1PitchZeroCrossCount
            mode1PitchZeroCrossCount = 0
            let minI = Int(sampleRate / 800.0)
            let maxI = Int(sampleRate / 70.0)
            if interval >= minI, interval <= maxI {
                let hz = sampleRate / Float(interval)
                let jitter = abs(Float(interval - mode1PitchLastCross))
                let confTarget = max(0, min(1, 1.0 - (jitter / max(1, Float(interval)))))
                mode1PitchHz += 0.18 * (hz - mode1PitchHz)
                mode1PitchConf += 0.18 * (confTarget - mode1PitchConf)
                mode1PitchLastCross = interval
            } else {
                mode1PitchConf *= 0.93
            }
        } else {
            mode1PitchConf *= 0.999
        }
        mode1PitchPrevInput = input
    }

    private func mode1CaptureRecentSlice(gridSamples: Int, energyFloor: Float) {
        let desired = max(gridSamples, min(Int(sampleRate * 1.2), gridSamples * 3))
        let start = mode1Write - desired
        let energy = mode1CaptureWindowEnergy(start: start, length: desired)
        mode1CaptureEnergy = energy
        if energy < energyFloor {
            mode1CaptureValid = mode1HasValidSlice
            return
        }
        var slice = [Float](repeating: 0, count: desired)
        for i in 0..<desired {
            slice[i] = mode1Buffer[mode1WrappedIndex(start + i)]
        }
        mode1CaptureSliceBuffer = slice
        mode1LastValidSliceStart = 0
        mode1LastValidSliceLength = desired
        mode1HasValidSlice = !slice.isEmpty
        mode1CaptureValid = mode1HasValidSlice
    }

    private func mode1RenderSceneVoice(_ voice: inout Mode1SceneVoice) -> Float {
        guard voice.active, !mode1CaptureSliceBuffer.isEmpty else {
            voice.active = false
            return 0
        }
        let raw = mode1CaptureSampleLinear(voice.position)
        let fadeIn = min(1.0, Float(voice.age) / Float(max(1, voice.fadeInSamples)))
        let remaining = max(0, voice.length - voice.age)
        let fadeOut = min(1.0, Float(remaining) / Float(max(1, voice.fadeOutSamples)))
        let env = min(fadeIn, fadeOut)
        let out = raw * env * voice.gain

        voice.position += voice.rate
        let countF = Float(mode1CaptureSliceBuffer.count)
        if countF > 1 {
            if voice.position < 0 {
                voice.position += countF
            } else if voice.position >= countF {
                voice.position -= countF
            }
        } else {
            voice.position = 0
        }
        voice.age += 1
        if voice.age >= voice.length {
            voice.active = false
        }
        return out
    }

    private func mode1SceneIntervals(sceneId: String) -> [Int] {
        switch sceneId {
        case "arp_shred": return [0, 4, 7, 12]
        case "spectral_melt": return [0, 3, 7, 10]
        case "databend": return [0, 1, 4, 7, 11]
        case "void_strobe": return [0, 7, 10]
        default: return [0, 2, 5, 7, 10]
        }
    }

    private func mode1SpawnShardVoice(
        profile: Mode1SceneProfile,
        cursor: Int,
        gridSamples: Int,
        activityNorm: Float,
        onsetNorm: Float,
        ratchetIndex: Int,
        interventions: inout SafetyInterventions
    ) {
        guard mode1HasValidSlice, !mode1CaptureSliceBuffer.isEmpty else { return }
        let fracture = max(0, min(1, mode1MacroFracture + (0.30 * mode1JoltBoost)))
        let voiceCap = max(2, min(mode1ShardVoices.count, Int(3 + floor(fracture * 7.0))))
        let activeCount = mode1ShardVoices.reduce(into: 0) { $0 += ($1.active ? 1 : 0) }
        guard activeCount < voiceCap, let slot = mode1ShardVoices.firstIndex(where: { !$0.active }) else {
            interventions.insert(.voiceCap)
            return
        }

        let patternMs = profile.sizePatternMs[(cursor + ratchetIndex) % profile.sizePatternMs.count]
        let ratchetScale: Float = ratchetIndex == 0 ? 1.0 : max(0.30, 0.72 - 0.16 * Float(ratchetIndex))
        let sizeMs = max(68.0, patternMs * (0.90 + (0.50 * (1.0 - fracture))) * ratchetScale)
        let sliceFrames = max(24, min(mode1CaptureSliceBuffer.count - 1, Int((sizeMs / 1_000.0) * sampleRate)))
        guard sliceFrames > 12 else { return }

        let maxOffset = max(1, mode1CaptureSliceBuffer.count - sliceFrames - 1)
        let shaped = 0.5 + 0.5 * sinf(Float(cursor + 1) * 1.618_033_9)
        var start = Int(Float(maxOffset) * shaped)
        let jitterSpan = Int(Float(max(8, sliceFrames / 3)) * (0.15 + 0.85 * fracture))
        start += Int((randomUnit() * 2.0 - 1.0) * Float(jitterSpan))
        start = max(0, min(maxOffset, start))
        start = mode1CaptureNearestZeroCross(start, radius: max(8, sliceFrames / 4))
        var end = start + sliceFrames
        end = max(start + 12, min(mode1CaptureSliceBuffer.count - 1, end))
        end = mode1CaptureNearestZeroCross(end, radius: max(8, sliceFrames / 4))
        if end <= start + 8 {
            end = min(mode1CaptureSliceBuffer.count - 1, start + max(12, sliceFrames / 2))
        }

        let reverseProb = min(0.55, profile.reverseBias * 0.70 + (0.24 * fracture) + (0.10 * onsetNorm))
        let reverse = randomUnit() < reverseProb
        var rate = (0.94 + 0.12 * randomUnit()) + ((randomUnit() * 2.0 - 1.0) * (0.05 + 0.26 * fracture))
        rate = max(0.55, min(1.85, rate))
        let rawLength = Int(Float(max(16, end - start)) / max(0.25, abs(rate)))
        let length = max(56, min(Int(sampleRate * 0.9), rawLength))
        let gainBase = 0.08 + (0.26 * activityNorm) + (0.15 * fracture)
        let gain = max(0.03, min(0.96, gainBase * (0.82 + 0.24 * randomUnit()) * ratchetScale))

        mode1ShardVoices[slot].reset(
            start: start,
            end: end,
            reverse: reverse,
            rate: rate,
            gain: gain,
            length: length,
            fadeInSamples: max(20, min(120, sliceFrames / 2)),
            fadeOutSamples: max(28, min(180, sliceFrames / 2)),
            lanePan: -0.35 + (0.70 * randomUnit())
        )
    }

    private func mode1SpawnPitchVoice(
        profile: Mode1SceneProfile,
        cursor: Int,
        gridSamples: Int,
        activityNorm: Float,
        interventions: inout SafetyInterventions
    ) {
        guard mode1HasValidSlice, !mode1CaptureSliceBuffer.isEmpty else { return }
        let pitchLock = max(0, min(1, mode1MacroPitchLock))
        let voiceCap = max(1, min(mode1PitchVoices.count, Int(1 + floor(pitchLock * 4.0))))
        let activeCount = mode1PitchVoices.reduce(into: 0) { $0 += ($1.active ? 1 : 0) }
        guard activeCount < voiceCap, let slot = mode1PitchVoices.firstIndex(where: { !$0.active }) else {
            interventions.insert(.voiceCap)
            return
        }

        let baseMs: Float = 90.0 + (180.0 * (1.0 - mode1MacroFracture))
        let sliceFrames = max(36, min(mode1CaptureSliceBuffer.count - 1, Int((baseMs / 1_000.0) * sampleRate)))
        guard sliceFrames > 16 else { return }
        let maxOffset = max(1, mode1CaptureSliceBuffer.count - sliceFrames - 1)
        var start = Int((0.5 + 0.5 * cosf(Float(cursor + 3) * 1.143)) * Float(maxOffset))
        start = max(0, min(maxOffset, start))
        start = mode1CaptureNearestZeroCross(start, radius: max(12, sliceFrames / 3))
        var end = max(start + 16, min(mode1CaptureSliceBuffer.count - 1, start + sliceFrames))
        end = mode1CaptureNearestZeroCross(end, radius: max(12, sliceFrames / 3))
        if end <= start + 10 {
            end = min(mode1CaptureSliceBuffer.count - 1, start + max(16, sliceFrames / 2))
        }

        let pitchTracked = mode1PitchConf > 0.28
        let detectedMidi = pitchTracked ? (69.0 + (12.0 * log2(max(30.0, mode1PitchHz) / 440.0))) : Float(60 + ((cursor % 12) - 6))
        let lockStrength = pitchTracked ? pitchLock * max(0, min(1, (mode1PitchConf - 0.24) / 0.76)) : (pitchLock * 0.35)
        let intervals = mode1SceneIntervals(sceneId: profile.id)
        let targetMidi = nearestChordMidi(
            targetMidi: Int(detectedMidi.rounded()),
            rootMidi: 60,
            intervals: intervals
        )
        let detune = (randomUnit() * 2.0 - 1.0) * (1.0 - lockStrength) * 6.0
        let semitoneDelta = (Float(targetMidi) - detectedMidi) * lockStrength + detune
        let rate = max(0.30, min(2.8, powf(2.0, semitoneDelta / 12.0) * (0.92 + 0.20 * randomUnit())))
        let length = max(32, min(Int(sampleRate * 1.2), Int(Float(max(16, end - start)) / max(0.25, abs(rate)))))
        let reverse = randomUnit() < (0.04 + 0.18 * profile.reverseBias)
        let gain = max(0.02, min(0.70, (0.08 + (0.22 * activityNorm) + (0.16 * pitchLock)) * (0.80 + 0.25 * randomUnit())))

        mode1PitchVoices[slot].reset(
            start: start,
            end: end,
            reverse: reverse,
            rate: rate,
            gain: gain,
            length: length,
            fadeInSamples: max(18, min(120, sliceFrames / 2)),
            fadeOutSamples: max(24, min(180, sliceFrames / 2)),
            lanePan: -0.20 + (0.40 * randomUnit())
        )
    }

    private func mode1ScheduleSceneEvents(
        profile: Mode1SceneProfile,
        gridSamples: Int,
        activityNorm: Float,
        onsetNorm: Float,
        interventions: inout SafetyInterventions
    ) {
        guard mode1HasValidSlice else { return }
        let stepHz = sampleRate / Float(max(1, gridSamples))
        let sceneRate = Float(max(0.25, min(12.0, controlCurrent.mode1SceneRateHz)))
        let fracture = max(0, min(1, mode1MacroFracture + (0.30 * mode1JoltBoost)))
        let eventsPerStep = sceneRate / max(0.25, stepHz)
        let activityGain = 0.72 + (0.52 * activityNorm) + (0.22 * onsetNorm)
        mode1SceneEventAccumulator += eventsPerStep * activityGain * (0.48 + (1.02 * fracture)) * profile.shardBias
        mode1SceneEventAccumulator = min(5.0, mode1SceneEventAccumulator)

        var spawnBudget = Int(mode1SceneEventAccumulator)
        mode1SceneEventAccumulator -= Float(spawnBudget)
        spawnBudget = max(0, min(2, spawnBudget))
        if spawnBudget == 0 && mode1State == .live && (activityNorm > 0.25 || onsetNorm > 0.50) && mode1SceneEventAccumulator > 0.35 {
            spawnBudget = 1
        }

        for _ in 0..<spawnBudget {
            let cursor = mode1SceneCursor
            mode1SceneCursor += 1
            let dropoutChance = max(0.0, min(0.90, profile.dropoutBias + (0.26 * (1.0 - activityNorm)) - (0.24 * fracture)))
            if randomUnit() < dropoutChance {
                continue
            }
            mode1SpawnShardVoice(
                profile: profile,
                cursor: cursor,
                gridSamples: gridSamples,
                activityNorm: activityNorm,
                onsetNorm: onsetNorm,
                ratchetIndex: 0,
                interventions: &interventions
            )

            let maxRatchet = mode1MacroFracture > 0.82 ? 3 : 2
            let ratchet = min(maxRatchet, max(1, profile.ratchetPattern[cursor % profile.ratchetPattern.count]))
            if ratchet > 1 {
                for i in 1..<ratchet {
                    mode1SpawnShardVoice(
                        profile: profile,
                        cursor: cursor + i,
                        gridSamples: gridSamples,
                        activityNorm: activityNorm,
                        onsetNorm: onsetNorm,
                        ratchetIndex: i,
                        interventions: &interventions
                    )
                }
            }

            let pitchChance = max(0.0, min(0.95, profile.pitchBias * (0.12 + (0.88 * mode1MacroPitchLock))))
            if randomUnit() < pitchChance {
                mode1SpawnPitchVoice(
                    profile: profile,
                    cursor: cursor,
                    gridSamples: gridSamples,
                    activityNorm: activityNorm,
                    interventions: &interventions
                )
            }
        }
    }

    private func mode1SpectralCarrierFrequencies(sceneId: String) -> [Float] {
        switch sceneId {
        case "databend": return [37, 121, 268, 712]
        case "arp_shred": return [52, 156, 312, 624]
        case "reverse_flock": return [29, 98, 246, 534]
        case "spectral_melt": return [24, 82, 214, 468]
        case "void_strobe": return [61, 187, 421, 910]
        default: return [42, 134, 286, 602]
        }
    }

    private func mode1ApplyMutation(sample: Float, profile: Mode1SceneProfile, gridSamples: Int, activityNorm: Float) -> Float {
        var mutation = max(0, min(1, mode1MacroMutation + (0.26 * mode1JoltBoost)))
        mutation = max(0, min(1, mutation))
        let fracture = max(0, min(1, mode1MacroFracture + (0.20 * mode1JoltBoost)))
        if mutation <= 0.0001 {
            mode1MutationSmooth += 0.08 * (sample - mode1MutationSmooth)
            mode1MutationFeedbackSmooth += 0.05 * (sample - mode1MutationFeedbackSmooth)
            return sample
        }

        let holdBase = max(1, Int(Float(gridSamples) * (0.01 + 0.22 * mutation)))
        if mode1MutationHoldSamplesRemaining <= 0 {
            let jitter = Int((randomUnit() * 2.0 - 1.0) * Float(max(1, holdBase / 4)))
            mode1MutationHoldSamplesRemaining = max(1, holdBase + jitter)
            mode1MutationHeld = sample
        } else {
            mode1MutationHoldSamplesRemaining -= 1
        }
        mode1MutationSmooth += (0.05 + 0.24 * mutation) * (mode1MutationHeld - mode1MutationSmooth)

        let fbHoldBase = max(1, Int(Float(gridSamples) * (0.02 + 0.18 * mutation)))
        if mode1MutationFeedbackHoldSamplesRemaining <= 0 {
            let jitter = Int((randomUnit() * 2.0 - 1.0) * Float(max(1, fbHoldBase / 5)))
            mode1MutationFeedbackHoldSamplesRemaining = max(1, fbHoldBase + jitter)
            mode1MutationFeedbackHeld = mode1MutationSmooth
        } else {
            mode1MutationFeedbackHoldSamplesRemaining -= 1
        }
        mode1MutationFeedbackSmooth += (0.05 + 0.18 * mutation) * (mode1MutationFeedbackHeld - mode1MutationFeedbackSmooth)

        mode1MutationRingPhase += 0.00028 + (0.0038 * mutation) + (0.0014 * profile.mutationBias)
        if mode1MutationRingPhase > 1 { mode1MutationRingPhase -= 1 }
        let ringCarrier = sinf(mode1MutationRingPhase * 2.0 * .pi)
        let ringed = mode1MutationSmooth * ringCarrier

        let foldDrive = 1.2 + (4.6 * (mutation + (0.4 * profile.mutationBias)))
        let folded = tanhf(mode1MutationSmooth * foldDrive)
        let foldedWrap = (2.0 / Float.pi) * asinf(max(-0.999, min(0.999, folded)))

        let lowCut = 220.0 + (180.0 * profile.mutationBias) + (200.0 * fracture)
        let lowMidCut = 1_000.0 + (1_200.0 * mutation) + (500.0 * profile.shardBias)
        let highMidCut = 3_400.0 + (2_800.0 * fracture)
        let lowAlpha = onePoleAlpha(cutoffHz: lowCut, sampleRate: sampleRate)
        let lowMidAlpha = onePoleAlpha(cutoffHz: lowMidCut, sampleRate: sampleRate)
        let highMidAlpha = onePoleAlpha(cutoffHz: highMidCut, sampleRate: sampleRate)
        mode1SpectralLP1 += lowAlpha * (mode1MutationSmooth - mode1SpectralLP1)
        mode1SpectralLP2 += lowMidAlpha * (mode1MutationSmooth - mode1SpectralLP2)
        mode1SpectralLP3 += highMidAlpha * (mode1MutationSmooth - mode1SpectralLP3)

        var bands = [Float](repeating: 0, count: 4)
        bands[0] = mode1SpectralLP1
        bands[1] = mode1SpectralLP2 - mode1SpectralLP1
        bands[2] = mode1SpectralLP3 - mode1SpectralLP2
        bands[3] = mode1MutationSmooth - mode1SpectralLP3

        let baseHold = max(8, Int(Float(gridSamples) * (0.05 + 0.20 * (1.0 - mutation))))
        let holdDivs: [Float] = [1.0, 0.72, 0.54, 0.36]
        let baseFreqs = mode1SpectralCarrierFrequencies(sceneId: profile.id)
        var spectral = Float(0)
        for i in 0..<4 {
            if mode1SpectralHoldRemaining[i] <= 0 {
                let jitter = Int((randomUnit() * 2.0 - 1.0) * Float(max(1, baseHold / 3)))
                let hold = Int(Float(baseHold) * holdDivs[i])
                mode1SpectralHoldRemaining[i] = max(1, hold + jitter)
                mode1SpectralHeldBands[i] = bands[i]
            } else {
                mode1SpectralHoldRemaining[i] -= 1
            }

            let smooth = 0.04 + (0.22 * mutation)
            mode1SpectralSmoothBands[i] += smooth * (mode1SpectralHeldBands[i] - mode1SpectralSmoothBands[i])

            let carrierHz = baseFreqs[i] * (0.70 + 0.74 * fracture + 0.28 * profile.reverseBias)
            mode1SpectralCarrierPhase[i] += carrierHz / sampleRate
            if mode1SpectralCarrierPhase[i] >= 1 {
                mode1SpectralCarrierPhase[i] -= floorf(mode1SpectralCarrierPhase[i])
            }
            let carrier = sinf(mode1SpectralCarrierPhase[i] * 2.0 * .pi)
            let amBand = mode1SpectralSmoothBands[i] * (0.30 + (0.70 * carrier))
            let laneMix = max(0.0, min(0.96, 0.34 + (0.54 * mutation) + (0.22 * profile.mutationBias)))
            var lane = bands[i] * (1.0 - laneMix) + amBand * laneMix

            if i == 0 {
                lane *= 1.05 - (0.28 * mutation)
            } else if i == 1 {
                lane *= 0.94 + (0.18 * (1.0 - activityNorm))
            } else if i == 2 {
                lane *= 0.98 + (0.30 * mutation)
            } else {
                lane *= 1.08 + (0.74 * mutation) + (0.24 * profile.mutationBias)
            }
            spectral += lane
        }

        mode1SpectralFeedback += 0.08 * ((spectral + (mode1MutationFeedbackSmooth * (0.08 + 0.20 * mutation))) - mode1SpectralFeedback)
        spectral += mode1SpectralFeedback * (0.14 + 0.36 * mutation)

        let lpAlpha = onePoleAlpha(cutoffHz: max(120.0, 2_800.0 - (2_000.0 * mutation)), sampleRate: sampleRate)
        mode1MutationLP += lpAlpha * (sample - mode1MutationLP)
        let hpAlpha = hpfAlpha(fc: 280.0 + (3_200.0 * mutation), sampleRate: sampleRate)
        mode1MutationHP = hpAlpha * (mode1MutationHP + sample - mode1MutationPrev)
        mode1MutationPrev = sample
        let tilt = (mode1MutationLP * (1.0 - mutation)) + (mode1MutationHP * mutation)

        let color = (0.46 * spectral) + (0.26 * foldedWrap) + (0.14 * ringed) + (0.14 * tilt)
        let mixAmount = max(0.0, min(0.97, 0.54 + (0.36 * mutation) + (0.12 * profile.mutationBias)))
        var out = (sample * (1.0 - mixAmount)) + (color * mixAmount)
        out += mode1MutationFeedbackSmooth * (0.05 + 0.16 * mutation)
        return tanhf(out * (1.0 + 0.75 * mutation))
    }

    private func mode1SetState(_ next: Mode1GlitchState, source: String) {
        mode1State = next
        mode1LastTriggerSource = source
        switch next {
        case .live:
            mode1FadeSamplesRemaining = 0
            mode1FadeGain = 1
        case .hold:
            mode1FadeSamplesRemaining = 0
            mode1FadeGain = 1
        case .fade:
            mode1HoldSamplesRemaining = 0
        case .mute:
            mode1HoldSamplesRemaining = 0
            mode1FadeSamplesRemaining = 0
            mode1FadeGain = 0
            for i in mode1ShardVoices.indices { mode1ShardVoices[i].active = false }
            for i in mode1PitchVoices.indices { mode1PitchVoices[i].active = false }
            mode1SpectralFeedback = 0
            for i in mode1SpectralHoldRemaining.indices {
                mode1SpectralHoldRemaining[i] = 0
                mode1SpectralHeldBands[i] = 0
                mode1SpectralSmoothBands[i] = 0
            }
            mode1SceneEventAccumulator = 0
        }
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

    private func processMode1(input: Float, analysisInput: Float, interventions: inout SafetyInterventions) -> Float {
        let gridSamples = max(64, mode1GridSamples())
        let fractureBase = max(0, min(1, Float(controlCurrent.mode1Fracture)))
        let mutationBase = max(0, min(1, Float(controlCurrent.mode1Mutation)))
        let pitchLockBase = max(0, min(1, Float(controlCurrent.mode1PitchLock)))
        mode1MacroFracture = min(1.0, fractureBase + (0.30 * mode1JoltBoost))
        mode1MacroMutation = mutationBase
        mode1MacroPitchLock = pitchLockBase
        mode1HoldTargetSamples = Int(sampleRate * Float(max(6.0, min(12.0, controlCurrent.mode1HoldLenSec))))
        mode1TailFadeTargetSamples = max(1, Int((Float(max(150.0, min(1_200.0, controlCurrent.mode1TailFadeMs))) / 1_000.0) * sampleRate))
        mode1JoltBoost *= 0.998

        let clearEdge = controlCurrent.mode1ClearRequest && !mode1PrevClearRequest
        let joltEdge = controlCurrent.mode1JoltRequest && !mode1PrevJoltRequest
        mode1PrevClearRequest = controlCurrent.mode1ClearRequest
        mode1PrevJoltRequest = controlCurrent.mode1JoltRequest

        if clearEdge {
            if mode1State != .mute {
                mode1FadeSamplesRemaining = max(1, mode1TailFadeTargetSamples)
                mode1FadeGain = 1
                mode1SetState(.fade, source: "clear")
            }
            interventions.insert(.resetVoices)
        }
        if joltEdge {
            mode1JoltBoost = max(mode1JoltBoost, 0.45)
            mode1AdvanceScene(repeatStyleId: controlCurrent.repeatStyleId)
            mode1LastTriggerSource = "jolt"
            mode1SceneCursor += 1
        }

        let resolvedScene = mode1ResolveSceneId(baseSceneId: controlCurrent.mode1SceneId, repeatStyleId: controlCurrent.repeatStyleId)
        if resolvedScene != mode1SceneId {
            mode1SceneId = resolvedScene
            mode1SceneCursor = 0
            mode1LastTriggerSource = "scene_select"
        }
        let profile = mode1SceneProfile(for: mode1SceneId)

        let feedbackWrite = mode1MutationFeedbackSmooth * (0.02 + 0.10 * mode1MacroMutation)
        mode1Buffer[mode1Write] = input + feedbackWrite
        mode1Write += 1
        if mode1Write >= mode1Buffer.count { mode1Write = 0 }

        mode1Clock.advance()
        mode1TransientDuck *= 0.996
        mode1DryAttackBoost *= 0.993
        mode1FeedbackLP *= 0.997
        mode1UpdatePitchTracker(analysisInput)

        let delta = abs(analysisInput - mode1PrevInput)
        mode1PrevInput = analysisInput
        mode1Env += 0.0045 * (abs(analysisInput) - mode1Env)

        let envOpen = 0.010 + (0.038 * mode1MacroFracture)
        let envClose = envOpen * 0.62
        let transientOpen = 0.003 + (0.028 * mode1MacroFracture)
        let transientClose = transientOpen * 0.40
        let isAttack = (mode1Env >= envOpen) || (delta >= transientOpen)
        let isSilentSample = (mode1Env < envClose) && (delta < transientClose)
        let onsetNorm = max(0, min(1, (delta - transientClose) / max(0.0001, transientOpen * 2.1)))
        let activityNorm = max(0, min(1, (mode1Env - envClose) / max(0.0001, envOpen - envClose)))

        if isAttack {
            mode1SilenceSamples = 0
            let minOnsetGap = Int64(sampleRate * 0.055)
            if mode1LastOnsetSample < 0 || (sampleCounter - mode1LastOnsetSample) >= minOnsetGap {
                if mode1LastOnsetSample >= 0 {
                    let interval = Int(sampleCounter - mode1LastOnsetSample)
                    let minInterval = Int(sampleRate * 0.20)
                    let maxInterval = Int(sampleRate * 1.8)
                    if interval >= minInterval && interval <= maxInterval {
                        mode1Clock.noteOnset(intervalSamples: interval, sampleRate: sampleRate)
                    } else {
                        mode1Clock.noteUntrustedOnset()
                    }
                }
                mode1LastOnsetSample = sampleCounter
                mode1TransientDuck = max(mode1TransientDuck, 0.55 + 0.45 * onsetNorm)
                mode1DryAttackBoost = max(mode1DryAttackBoost, 0.45 + 0.55 * onsetNorm)
            }
            if mode1State != .live {
                mode1SetState(.live, source: "attack")
            }
        } else {
            mode1Clock.confidenceDecay()
            if isSilentSample {
                mode1SilenceSamples += 1
            } else {
                mode1SilenceSamples = max(0, mode1SilenceSamples - 4)
            }
        }

        let silenceTriggerSamples = Int(sampleRate * 0.09)
        if mode1State == .live && mode1SilenceSamples >= silenceTriggerSamples {
            if mode1HasValidSlice {
                mode1HoldSamplesRemaining = mode1HoldTargetSamples
                mode1SetState(.hold, source: "silence")
            } else {
                mode1SetState(.mute, source: "silence_no_slice")
            }
        }
        if mode1State == .hold {
            mode1HoldSamplesRemaining -= 1
            if mode1HoldSamplesRemaining <= 0 {
                mode1FadeSamplesRemaining = max(1, mode1TailFadeTargetSamples)
                mode1FadeGain = 1
                mode1SetState(.fade, source: "hold_timeout")
            }
        } else if mode1State == .fade {
            if mode1FadeSamplesRemaining > 0 {
                mode1FadeSamplesRemaining -= 1
                mode1FadeGain = Float(mode1FadeSamplesRemaining) / Float(max(1, mode1TailFadeTargetSamples))
            } else {
                mode1SetState(.mute, source: "fade_done")
            }
        }

        let step = Int(sampleCounter / Int64(max(1, gridSamples)))
        if step != mode1BoundaryStep {
            mode1BoundaryStep = step
            mode1SceneCursor += 1
            updateMode1Spatial(step: mode1SceneCursor)
            if mode1State == .live {
                let captureFloor = 0.0006 + (0.0022 * (1.0 - mode1MacroFracture))
                mode1CaptureRecentSlice(gridSamples: gridSamples, energyFloor: captureFloor)
            }
            if mode1State == .live || mode1State == .hold || mode1State == .fade {
                mode1ScheduleSceneEvents(
                    profile: profile,
                    gridSamples: gridSamples,
                    activityNorm: activityNorm,
                    onsetNorm: onsetNorm,
                    interventions: &interventions
                )
            }
        }

        var shardWet: Float = 0
        var pitchWet: Float = 0
        for i in mode1ShardVoices.indices {
            shardWet += mode1RenderSceneVoice(&mode1ShardVoices[i])
        }
        for i in mode1PitchVoices.indices {
            pitchWet += mode1RenderSceneVoice(&mode1PitchVoices[i])
        }

        let shardWeight = 0.30 + (0.36 * profile.shardBias)
        let pitchWeight = 0.20 + (0.44 * mode1MacroPitchLock * profile.pitchBias)
        var wet = (shardWet * shardWeight) + (pitchWet * pitchWeight)
        wet = mode1ApplyMutation(sample: wet, profile: profile, gridSamples: gridSamples, activityNorm: activityNorm)
        if mode1State == .fade {
            wet *= max(0, min(1, mode1FadeGain))
        } else if mode1State == .mute {
            wet = 0
        }

        mode1WetSmoothed += 0.28 * (wet - mode1WetSmoothed)
        mode1FeedbackLP += 0.08 * (mode1WetSmoothed - mode1FeedbackLP)
        mode1WetEnergyAccum += mode1WetSmoothed * mode1WetSmoothed
        mode1WetMeterSamples += 1
        let wetWindow = max(256, Int(sampleRate * 0.10))
        if mode1WetMeterSamples >= wetWindow {
            mode1WetRMS = sqrtf(mode1WetEnergyAccum / Float(max(1, mode1WetMeterSamples)))
            mode1WetEnergyAccum = 0
            mode1WetMeterSamples = 0
        }
        return tanhf(mode1WetSmoothed * 2.20)
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

    private func mode4PickIndex(from values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let idx = Int(randomUnit() * Float(values.count))
        return values[max(0, min(values.count - 1, idx))]
    }

    private func mode4NearestSafeCut(_ clip: Mode4SampleClip, target: Int, lower: Int, upper: Int) -> Int {
        let lo = max(0, lower)
        let hi = min(max(lo, upper), clip.samples.count - 1)
        if lo >= hi { return lo }

        let points = clip.analysis.safeCutPoints
        if points.isEmpty {
            return max(lo, min(hi, target))
        }

        let clampedTarget = max(lo, min(hi, target))
        var l = 0
        var r = points.count
        while l < r {
            let m = (l + r) >> 1
            if points[m] < clampedTarget {
                l = m + 1
            } else {
                r = m
            }
        }

        var best = clampedTarget
        var bestDist = Int.max
        for idx in [l - 1, l] where idx >= 0 && idx < points.count {
            let point = points[idx]
            if point < lo || point > hi { continue }
            let dist = abs(point - clampedTarget)
            if dist < bestDist {
                bestDist = dist
                best = point
            }
        }
        return best
    }

    private func mode4ClipSampleLinear(_ clip: Mode4SampleClip, at frame: Float) -> Float {
        let maxIdx = max(0, clip.samples.count - 1)
        let f = max(0, min(Float(maxIdx), frame))
        let i0 = Int(floorf(f))
        let i1 = min(maxIdx, i0 + 1)
        let frac = f - Float(i0)
        let s0 = clip.samples[i0]
        let s1 = clip.samples[i1]
        return s0 + (s1 - s0) * frac
    }

    private func mode4TargetCategories(liveFeatures: Mode4LiveFeatures) -> [String] {
        var out: [String] = []
        if let requested = controlCurrent.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !requested.isEmpty {
            out.append(requested)
        }
        if liveFeatures.brightness > 0.62 {
            out.append("transient")
            out.append("metal")
            out.append("bright")
        } else if liveFeatures.lowBand > 0.58 {
            out.append("room")
            out.append("general")
            out.append("full")
        } else {
            out.append("general")
            out.append("room")
            out.append("transient")
        }

        var unique: [String] = []
        for cat in out where !unique.contains(cat) {
            unique.append(cat)
        }
        return unique
    }

    private func mode4SelectClipIndex(liveFeatures: Mode4LiveFeatures) -> Int {
        guard !mode4SampleLibrary.isEmpty else { return -1 }

        let targetCategories = mode4TargetCategories(liveFeatures: liveFeatures)
        var pool: [Int] = []
        for cat in targetCategories {
            if let ids = mode4CategoryToIndices[cat] {
                pool.append(contentsOf: ids)
            }
        }
        if pool.isEmpty {
            pool = Array(mode4SampleLibrary.indices)
        }

        let wantsCall = randomUnit() < Float(controlCurrent.callResponseBias)
        let similarity = max(0, min(1, Float(controlCurrent.similarityTarget)))
        let stability = max(0, min(1, Float(controlCurrent.memoryWeight)))
        let recent = mode4RecentClipIndices

        if wantsCall, let anchor = recent.last {
            if randomUnit() < similarity {
                return anchor
            }
            let anchorCategory = mode4SampleLibrary[anchor].category
            if let sameCategory = mode4CategoryToIndices[anchorCategory], let idx = mode4PickIndex(from: sameCategory) {
                return idx
            }
        }

        if !wantsCall, let anchor = recent.last {
            let anchorCategory = mode4SampleLibrary[anchor].category
            let contrast = pool.filter { mode4SampleLibrary[$0].category != anchorCategory }
            if !contrast.isEmpty {
                pool = contrast
            }
        }

        if !recent.isEmpty, randomUnit() < stability, let idx = mode4PickIndex(from: recent) {
            return idx
        }

        return mode4PickIndex(from: pool) ?? 0
    }

    private func mode4RememberClipIndex(_ clipIndex: Int) {
        mode4RecentClipIndices.append(clipIndex)
        if mode4RecentClipIndices.count > 12 {
            mode4RecentClipIndices.removeFirst(mode4RecentClipIndices.count - 12)
        }
    }

    private func mode4SelectChunkDurationMs(liveFeatures: Mode4LiveFeatures) -> Float {
        let stability = max(0, min(1, Float(controlCurrent.memoryWeight)))
        let microWeight = 0.20 + 0.68 * liveFeatures.onsetNoisy
        let mesoWeight: Float = 0.44
        let macroWeight = 0.22 + 0.60 * stability * (1.0 - 0.45 * liveFeatures.onsetNoisy)
        let sum = microWeight + mesoWeight + macroWeight
        let r = randomUnit() * sum
        if r < microWeight {
            return 30.0 + randomUnit() * 90.0
        }
        if r < (microWeight + mesoWeight) {
            return 120.0 + randomUnit() * 330.0
        }
        return 450.0 + randomUnit() * 750.0
    }

    private func spawnMode4Voice(liveFeatures: Mode4LiveFeatures, interventions: inout SafetyInterventions) {
        guard !mode4SampleLibrary.isEmpty else {
            mode4NoSamplesDryOnly = true
            return
        }

        mode4NoSamplesDryOnly = false
        mode4ActiveVoices = mode4Voices.reduce(into: 0) { $0 += ($1.active ? 1 : 0) }
        let voiceCap = max(2, min(mode4Voices.count, Int(2 + floor(controlCurrent.interruptiveness * 9.0))))
        if mode4ActiveVoices >= voiceCap {
            interventions.insert(.voiceCap)
            return
        }

        guard let slot = mode4Voices.firstIndex(where: { !$0.active }) else {
            interventions.insert(.voiceCap)
            return
        }

        let clipIndex = mode4SelectClipIndex(liveFeatures: liveFeatures)
        guard clipIndex >= 0, clipIndex < mode4SampleLibrary.count else { return }
        let clip = mode4SampleLibrary[clipIndex]
        let chunkMs = mode4SelectChunkDurationMs(liveFeatures: liveFeatures)
        let desiredFrames = max(24, min(clip.samples.count - 2, Int((chunkMs / 1_000.0) * clip.sampleRate)))

        let useOnsetAnchor = !clip.analysis.onsetCandidates.isEmpty && randomUnit() < (0.20 + 0.60 * liveFeatures.onsetNoisy)
        let anchor: Int
        if useOnsetAnchor {
            anchor = clip.analysis.onsetCandidates[Int(randomUnit() * Float(clip.analysis.onsetCandidates.count))]
        } else {
            let maxAnchor = max(0, clip.samples.count - 1)
            anchor = Int(randomUnit() * Float(maxAnchor))
        }

        var start = anchor - (desiredFrames / 2)
        start = max(0, min(max(0, clip.samples.count - desiredFrames - 1), start))
        var end = min(clip.samples.count - 1, start + desiredFrames)
        start = mode4NearestSafeCut(clip, target: start, lower: 0, upper: max(0, end - 24))
        end = mode4NearestSafeCut(clip, target: end, lower: min(clip.samples.count - 1, start + 24), upper: clip.samples.count - 1)
        if end - start < 24 {
            start = max(0, min(clip.samples.count - 25, start))
            end = min(clip.samples.count - 1, start + 24)
        }

        let reverseProb = min(0.55, 0.08 + 0.28 * liveFeatures.onsetNoisy + 0.12 * (1.0 - Float(controlCurrent.memoryWeight)))
        let reverse = randomUnit() < reverseProb
        let semitoneSpan = 3.0 + (6.0 * Float(controlCurrent.interruptiveness))
        let semitone = (randomUnit() * 2.0 - 1.0) * semitoneSpan
        let pitchRatio = powf(2.0, semitone / 12.0)
        let stretch = 0.70 + randomUnit() * 0.95
        let rate = max(0.30, min(2.8, pitchRatio * stretch))

        let sourceDurSec = Float(end - start) / clip.sampleRate
        let outputLen = Int((sourceDurSec / max(0.25, rate)) * sampleRate)
        let minLen = Int(sampleRate * 0.02)
        let maxLen = Int(sampleRate * 1.25)
        let length = max(minLen, min(maxLen, outputLen))

        let baseGain = (0.28 + 0.90 * Float(controlCurrent.gestureLevel)) * max(0.35, mode4MemoryDecay)
        let rmsComp = 1.0 / max(0.16, clip.analysis.rms * 2.8)
        let gain = max(0.03, min(1.1, baseGain * clip.gain * min(1.35, rmsComp) * (0.84 + 0.26 * randomUnit())))
        let panX = (randomUnit() * 2.0 - 1.0) * 0.88
        let panY = (randomUnit() * 2.0 - 1.0) * 0.72
        let playbackStep = rate * (clip.sampleRate / sampleRate)

        mode4Voices[slot].reset(
            clipIndex: clipIndex,
            clipId: clip.id,
            category: clip.category,
            startFrame: start,
            endFrame: end,
            reverse: reverse,
            playbackStep: playbackStep,
            length: length,
            gain: gain,
            panX: panX,
            panY: panY
        )
        mode4RememberClipIndex(clipIndex)
        mode4LastTriggerSamplesAgo = 0

        let stutterProb = min(0.38, 0.08 + 0.30 * liveFeatures.onsetNoisy)
        if randomUnit() < stutterProb, mode4ActiveVoices + 1 < voiceCap, let extraSlot = mode4Voices.firstIndex(where: { !$0.active }) {
            let microStart = mode4NearestSafeCut(
                clip,
                target: start + Int((randomUnit() * 2.0 - 1.0) * 42.0),
                lower: start,
                upper: max(start, end - 16)
            )
            let microEnd = mode4NearestSafeCut(
                clip,
                target: microStart + Int((0.030 + randomUnit() * 0.090) * clip.sampleRate),
                lower: min(clip.samples.count - 1, microStart + 8),
                upper: clip.samples.count - 1
            )
            let microLen = max(Int(sampleRate * 0.018), min(Int(sampleRate * 0.16), Int(Float(max(8, microEnd - microStart)) * sampleRate / clip.sampleRate)))
            mode4Voices[extraSlot].reset(
                clipIndex: clipIndex,
                clipId: clip.id,
                category: clip.category,
                startFrame: microStart,
                endFrame: max(microStart + 8, microEnd),
                reverse: randomUnit() < 0.40 ? !reverse : reverse,
                playbackStep: max(0.45, min(3.0, playbackStep * (0.8 + randomUnit() * 0.6))),
                length: microLen,
                gain: gain * (0.45 + randomUnit() * 0.28),
                panX: max(-1, min(1, panX + (randomUnit() * 2.0 - 1.0) * 0.20)),
                panY: max(-1, min(1, panY + (randomUnit() * 2.0 - 1.0) * 0.20))
            )
        }
    }

    private func processMode4(
        input: Float,
        interventions: inout SafetyInterventions,
        _ ch0: inout Float,
        _ ch1: inout Float,
        _ ch2: inout Float,
        _ ch3: inout Float,
        _ ch4: inout Float,
        _ ch5: inout Float,
        reverbSend: inout Float
    ) {
        mode4LastTriggerSamplesAgo += 1
        let dryMix = max(0.0, min(0.20, Float(controlCurrent.dryLevel)))
        let dryDuck: Float = mode4ActiveVoices > 0 ? 0.22 : 0.55
        let clean = input * dryMix * dryDuck
        placeMainObject(
            sample: clean,
            spread: Float(min(0.55, controlCurrent.spread)),
            motionSpeed: Float(0.14 + 0.36 * controlCurrent.motionSpeed),
            radius: Float(0.16 + 0.24 * controlCurrent.motionRadius),
            mode: 4,
            &ch0, &ch1, &ch2, &ch3, &ch4, &ch5
        )
        reverbSend = clean * 0.03

        let onsetMetric = abs(input - mode4PrevInput)
        mode4PrevInput = input
        mode4InputEnv += 0.02 * (abs(input) - mode4InputEnv)
        mode4LowTrack += 0.03 * (input - mode4LowTrack)
        let high = input - mode4LowTrack
        mode4LowEnv += 0.02 * (abs(mode4LowTrack) - mode4LowEnv)
        mode4HighEnv += 0.02 * (abs(high) - mode4HighEnv)
        let onsetTarget = min(1.0, (onsetMetric / max(0.002, mode4InputEnv + 0.0015)) * 0.85)
        mode4Noisiness += 0.12 * (onsetTarget - mode4Noisiness)

        let brightLive = mode4HighEnv / max(1e-6, mode4HighEnv + mode4LowEnv)
        let lowLive = mode4LowEnv / max(1e-6, mode4HighEnv + mode4LowEnv)
        let liveFeatures = Mode4LiveFeatures(
            onsetNoisy: max(0, min(1, 0.58 * mode4Noisiness + 0.42 * min(1, onsetMetric * 36.0))),
            brightness: max(0, min(1, 0.62 * brightLive + 0.38 * Float(controlCurrent.bandHighLevel))),
            lowBand: max(0, min(1, 0.62 * lowLive + 0.38 * Float(controlCurrent.bandLowLevel)))
        )
        let inputActivity = max(0, min(1, (mode4InputEnv * 18.0) + (onsetMetric * 28.0)))

        if mode4SampleLibrary.isEmpty {
            mode4NoSamplesDryOnly = true
            mode4ActiveVoices = 0
            return
        }
        mode4NoSamplesDryOnly = false

        let baseTriggerHz = 0.60 + (2.2 * Float(controlCurrent.gestureRate)) + (6.8 * Float(controlCurrent.interruptiveness))
        let featureBoost = 0.50
            + (1.40 * inputActivity)
            + (0.95 * liveFeatures.onsetNoisy)
            + (0.30 * (1.0 - Float(controlCurrent.memoryWeight)))
        let triggerHz = min(24.0, baseTriggerHz * featureBoost)
        mode4TriggerAccumulator += triggerHz / sampleRate

        let minGapSamples = Int((0.012 + 0.075 * (1.0 - Float(controlCurrent.interruptiveness))) * sampleRate)
        if mode4LastTriggerSamplesAgo > minGapSamples {
            var spawned = 0
            while mode4TriggerAccumulator >= 1.0, spawned < 2 {
                mode4TriggerAccumulator -= 1.0
                spawnMode4Voice(liveFeatures: liveFeatures, interventions: &interventions)
                spawned += 1
            }

            let impulseChance = min(0.30, triggerHz / sampleRate * (0.45 + 0.55 * inputActivity))
            if (liveFeatures.onsetNoisy > 0.66 || inputActivity > 0.62), randomUnit() < impulseChance {
                spawnMode4Voice(liveFeatures: liveFeatures, interventions: &interventions)
            }
        }

        mode4ActiveVoices = 0
        for i in 0..<mode4Voices.count where mode4Voices[i].active {
            guard mode4Voices[i].clipIndex >= 0, mode4Voices[i].clipIndex < mode4SampleLibrary.count else {
                mode4Voices[i].active = false
                continue
            }
            mode4ActiveVoices += 1
            let clip = mode4SampleLibrary[mode4Voices[i].clipIndex]
            let src = mode4ClipSampleLinear(clip, at: mode4Voices[i].playhead)

            let inEnv = mode4Voices[i].age < mode4Voices[i].fadeInSamples
                ? Float(mode4Voices[i].age) / Float(max(1, mode4Voices[i].fadeInSamples))
                : 1.0
            let remaining = mode4Voices[i].length - mode4Voices[i].age
            let outEnv = remaining < mode4Voices[i].fadeOutSamples
                ? Float(max(0, remaining)) / Float(max(1, mode4Voices[i].fadeOutSamples))
                : 1.0
            let env = max(0, min(1, inEnv * outEnv))
            let wetIntent = max(0, min(1, Float(controlCurrent.wetLevel)))
            let gestureMix = max(0, min(1, Float(controlCurrent.gestureLevel)))
            let wetScale = max(
                0.60,
                min(
                    1.70,
                    (0.62 + 1.00 * gestureMix)
                        * (0.68 + 0.55 * wetIntent)
                        * (0.70 + 0.45 * inputActivity)
                )
            )
            let voiceOut = src * env * mode4Voices[i].gain * wetScale

            GridSpatializer.fillNormalizedPointGains(
                x: mode4Voices[i].panX,
                y: mode4Voices[i].panY,
                spread: max(0.32, min(0.98, Float(controlCurrent.spread) + 0.14)),
                into: &targetGains
            )
            applyGains(voiceOut, gains: targetGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)
            reverbSend += voiceOut * 0.06

            if mode4Voices[i].reverse {
                mode4Voices[i].playhead -= mode4Voices[i].playbackStep
            } else {
                mode4Voices[i].playhead += mode4Voices[i].playbackStep
            }
            mode4Voices[i].age += 1

            if mode4Voices[i].age >= mode4Voices[i].length {
                mode4Voices[i].active = false
                continue
            }
            if mode4Voices[i].reverse {
                if mode4Voices[i].playhead <= Float(mode4Voices[i].startFrame) {
                    mode4Voices[i].active = false
                }
            } else if mode4Voices[i].playhead >= Float(mode4Voices[i].endFrame - 1) {
                mode4Voices[i].active = false
            }
        }
    }

    private func preloadResonifierDefaults() {
        reloadResonifierLibrary(activeInstrumentId: "inst_A")
    }

    private func reloadResonifierLibrary(activeInstrumentId: String?) {
        mode56LoadInterventions.removeAll(keepingCapacity: true)
        resonInstrumentCache.removeAll(keepingCapacity: true)
        let trimmed = activeInstrumentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetId = (trimmed?.isEmpty == false) ? trimmed! : "inst_A"
        resonCurrentInstrument = cachedResonInstrument(id: targetId)
        resonSwapInstrument = resonCurrentInstrument
        resonSwapMix = 1.0
        resonSwapStep = 0
        resonSwapRemaining = 0
        resonNoteAccumulator = 0
        resonReactiveGateSamples = 0
        resonNoiseFloor = 0.001
        resonSilenceSamples = 0
        resonIsSilent = true
        resonInputLevel = 0
        resonLastMidi = -1
        resonDesiredVoices = 0
        resonSpawnCount = 0
        resonOutputEnergyAccum = 0
        resonOutputMeterSamples = 0
        resonLastOutputRMS = 0
        for i in resonVoices.indices {
            resonVoices[i].active = false
        }
    }

    private func prepareResonifierTargets(control: AudioControl) {
        let instrumentId = control.midiInstId
        let incomingInstrument = cachedResonInstrument(id: instrumentId)
        if incomingInstrument.id != resonCurrentInstrument.id {
            if !incomingInstrument.sampleZones.isEmpty || !resonCurrentInstrument.sampleZones.isEmpty {
                // Sample-backed instruments are switched immediately to avoid phase-domain crossfade artifacts.
                resonCurrentInstrument = incomingInstrument
                resonSwapInstrument = incomingInstrument
                resonSwapMix = 1.0
                resonSwapStep = 0.0
                resonSwapRemaining = 0
            } else {
                resonSwapInstrument = incomingInstrument
                resonSwapMix = 1.0
                let swapSec = 0.25 + (0.50 * Float(control.inharmonicity))
                resonSwapRemaining = max(1, Int(sampleRate * swapSec))
                resonSwapStep = -1.0 / Float(resonSwapRemaining)
            }
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

    private func resonCollectAudioFiles(for path: String) -> [URL] {
        guard let resolved = resolveMode4AssetURL(path: path) else { return [] }
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            var out: [URL] = []
            if let e = fm.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in e where mode4IsAudioFile(url) {
                    out.append(url)
                }
            }
            out.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            return out
        }
        return mode4IsAudioFile(resolved) ? [resolved] : []
    }

    private func resonCompanionSamplePaths(for soundfontPath: String) -> [String] {
        let ns = soundfontPath as NSString
        let baseNoExt = ns.deletingPathExtension
        let stem = (baseNoExt as NSString).lastPathComponent
        return [
            "\(baseNoExt)",
            "\(baseNoExt)_samples",
            "\(baseNoExt).samples",
            "Assets/Soundfonts/\(stem)",
            "Assets/Soundfonts/\(stem)_samples",
            "Assets/Soundfonts/\(stem).samples",
        ]
    }

    private func resonExtractRegexCapture(pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let g = match.range(at: group)
        guard g.location != NSNotFound else { return nil }
        return ns.substring(with: g)
    }

    private func resonRootMidiFromFilename(_ filename: String) -> Int? {
        let stem = (filename as NSString).deletingPathExtension
        if let midiString = resonExtractRegexCapture(pattern: "(?:^|[_\\-\\s])(?:midi|note|n)(\\d{1,3})(?:$|[_\\-\\s])", in: stem),
           let midi = Int(midiString) {
            return max(0, min(127, midi))
        }
        if let note = resonExtractRegexCapture(pattern: "(^|[_\\-\\s])(c#|db|d#|eb|f#|gb|g#|ab|a#|bb|c|d|e|f|g|a|b)(-?\\d)($|[_\\-\\s])", in: stem, group: 2),
           let octaveString = resonExtractRegexCapture(pattern: "(^|[_\\-\\s])(c#|db|d#|eb|f#|gb|g#|ab|a#|bb|c|d|e|f|g|a|b)(-?\\d)($|[_\\-\\s])", in: stem, group: 3),
           let octave = Int(octaveString) {
            let semitoneMap: [String: Int] = [
                "c": 0, "c#": 1, "db": 1, "d": 2, "d#": 3, "eb": 3, "e": 4, "f": 5,
                "f#": 6, "gb": 6, "g": 7, "g#": 8, "ab": 8, "a": 9, "a#": 10, "bb": 10, "b": 11,
            ]
            if let semitone = semitoneMap[note.lowercased()] {
                let midi = (octave + 1) * 12 + semitone
                return max(0, min(127, midi))
            }
        }
        return nil
    }

    private func resonBuildWavetableFromSamples(_ samples: [Float], tableCount: Int = 2_048) -> [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0, count: tableCount) }
        var table = [Float](repeating: 0, count: tableCount)
        let step = Float(samples.count - 1) / Float(max(1, tableCount - 1))
        var maxAbs: Float = 0
        for i in 0..<tableCount {
            let pos = Float(i) * step
            let i0 = Int(floorf(pos))
            let i1 = min(samples.count - 1, i0 + 1)
            let frac = pos - Float(i0)
            let v = samples[i0] + (samples[i1] - samples[i0]) * frac
            table[i] = v
            maxAbs = max(maxAbs, abs(v))
        }
        let norm = maxAbs > 1e-5 ? (0.95 / maxAbs) : 1.0
        for i in 0..<tableCount {
            table[i] *= norm
        }
        return table
    }

    private func resonSampleTrimBounds(samples: [Float], peak: Float) -> (start: Int, end: Int) {
        guard samples.count > 2 else {
            return (0, max(1, samples.count - 1))
        }

        let threshold = max(0.0012, peak * 0.035)
        var start = 0
        while start < samples.count - 2, abs(samples[start]) < threshold {
            start += 1
        }
        if start > Int(Float(samples.count) * 0.75) {
            start = 0
        }

        var end = samples.count - 1
        while end > start + 1, abs(samples[end]) < threshold {
            end -= 1
        }
        if end - start < 96 {
            start = 0
            end = samples.count - 1
        }
        return (start, max(start + 1, end))
    }

    private func resonBuildSampleZones(decoded: [(rootMidi: Int, sampleRate: Float, samples: [Float], gain: Float, peak: Float)]) -> [ResonSampleZone] {
        guard !decoded.isEmpty else { return [] }
        var bestByRoot: [Int: (rootMidi: Int, sampleRate: Float, samples: [Float], gain: Float, peak: Float)] = [:]
        for entry in decoded {
            let root = max(0, min(127, entry.rootMidi))
            if let existing = bestByRoot[root] {
                let betterPeak = entry.peak > (existing.peak * 1.08)
                let similarPeak = abs(entry.peak - existing.peak) < 0.015
                let longer = entry.samples.count > existing.samples.count
                if betterPeak || (similarPeak && longer) {
                    bestByRoot[root] = (root, entry.sampleRate, entry.samples, entry.gain, entry.peak)
                }
            } else {
                bestByRoot[root] = (root, entry.sampleRate, entry.samples, entry.gain, entry.peak)
            }
        }
        let sorted = bestByRoot.values.sorted { $0.rootMidi < $1.rootMidi }
        var zones: [ResonSampleZone] = []
        zones.reserveCapacity(sorted.count)
        for i in sorted.indices {
            let root = sorted[i].rootMidi
            let low: Int = {
                guard i > 0 else { return 0 }
                return min(root, ((sorted[i - 1].rootMidi + root) / 2) + 1)
            }()
            let high: Int = {
                guard i + 1 < sorted.count else { return 127 }
                return max(root, (root + sorted[i + 1].rootMidi) / 2)
            }()
            let trim = resonSampleTrimBounds(samples: sorted[i].samples, peak: sorted[i].peak)
            zones.append(
                ResonSampleZone(
                    rootMidi: root,
                    lowMidi: max(0, min(127, low)),
                    highMidi: max(0, min(127, high)),
                    sampleRate: sorted[i].sampleRate,
                    samples: sorted[i].samples,
                    gain: sorted[i].gain,
                    startFrame: trim.start,
                    endFrame: min(sorted[i].samples.count - 1, trim.end),
                    peak: sorted[i].peak
                )
            )
        }
        return zones
    }

    private func resonLoadSampleZones(from audioFiles: [URL], instrumentGain: Float) -> [ResonSampleZone] {
        guard !audioFiles.isEmpty else { return [] }
        var decoded: [(rootMidi: Int, sampleRate: Float, samples: [Float], gain: Float, peak: Float)] = []
        decoded.reserveCapacity(audioFiles.count)
        for (idx, url) in audioFiles.enumerated() {
            do {
                let mono = try decodeMode4MonoSamples(from: url)
                guard mono.samples.count > 64 else { continue }
                var peak: Float = 0
                for s in mono.samples {
                    peak = max(peak, abs(s))
                }
                if peak < 0.0005 { continue }
                let root = resonRootMidiFromFilename(url.lastPathComponent)
                    ?? max(24, min(96, 36 + Int((Float(idx) / Float(max(1, audioFiles.count - 1))) * 48.0)))
                let rms = sqrtf(mono.samples.reduce(0) { $0 + ($1 * $1) } / Float(max(1, mono.samples.count)))
                let comp = min(1.40, max(0.30, 1.0 / max(0.10, rms * 2.8)))
                let lift = min(5.0, max(1.0, 0.90 / max(0.02, peak)))
                decoded.append(
                    (
                        rootMidi: root,
                        sampleRate: max(8_000, mono.sampleRate),
                        samples: mono.samples,
                        gain: instrumentGain * comp * lift,
                        peak: peak
                    )
                )
            } catch {
                continue
            }
        }
        return resonBuildSampleZones(decoded: decoded)
    }

    private func resonReadLEUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func resonReadLEUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func resonFourCC(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
    }

    private func resonExtractSF2ChunkRanges(_ data: Data) -> (smpl: Range<Int>, shdr: Range<Int>)? {
        guard data.count >= 12 else { return nil }
        guard resonFourCC(data, at: 0) == "RIFF", resonFourCC(data, at: 8) == "sfbk" else { return nil }
        guard let riffSize = resonReadLEUInt32(data, at: 4) else { return nil }
        let riffEnd = min(data.count, 8 + Int(riffSize))
        guard riffEnd > 12 else { return nil }

        var smplRange: Range<Int>?
        var shdrRange: Range<Int>?

        func scanChunks(start: Int, end: Int, listType: String?) {
            var cursor = start
            while cursor + 8 <= end {
                guard let chunkId = resonFourCC(data, at: cursor),
                      let chunkSizeRaw = resonReadLEUInt32(data, at: cursor + 4) else { break }
                let chunkSize = Int(chunkSizeRaw)
                let payloadStart = cursor + 8
                let payloadEnd = payloadStart + chunkSize
                if payloadEnd > end || payloadEnd < payloadStart {
                    break
                }

                if chunkId == "LIST", chunkSize >= 4, let nestedType = resonFourCC(data, at: payloadStart) {
                    scanChunks(start: payloadStart + 4, end: payloadEnd, listType: nestedType)
                } else {
                    if listType == "sdta", chunkId == "smpl" {
                        smplRange = payloadStart..<payloadEnd
                    } else if listType == "pdta", chunkId == "shdr" {
                        shdrRange = payloadStart..<payloadEnd
                    }
                }

                var advance = 8 + chunkSize
                if (chunkSize & 1) == 1 {
                    advance += 1
                }
                cursor += advance
            }
        }

        scanChunks(start: 12, end: riffEnd, listType: nil)
        guard let smplRange, let shdrRange else { return nil }
        return (smpl: smplRange, shdr: shdrRange)
    }

    private func resonLoadSampleZonesFromSF2(_ soundfontURL: URL, instrumentGain: Float) -> [ResonSampleZone] {
        guard let data = try? Data(contentsOf: soundfontURL),
              let chunks = resonExtractSF2ChunkRanges(data) else {
            return []
        }

        let samplePoolCount = chunks.smpl.count / 2
        if samplePoolCount <= 0 {
            return []
        }

        let headerSize = 46
        let headerCount = chunks.shdr.count / headerSize
        if headerCount <= 1 {
            return []
        }

        let maxZones = 96
        var decoded: [(rootMidi: Int, sampleRate: Float, samples: [Float], gain: Float, peak: Float)] = []
        decoded.reserveCapacity(min(maxZones, headerCount - 1))

        for idx in 0..<(headerCount - 1) where decoded.count < maxZones {
            let base = chunks.shdr.lowerBound + idx * headerSize
            guard let start = resonReadLEUInt32(data, at: base + 20),
                  let end = resonReadLEUInt32(data, at: base + 24),
                  let sampleRateRaw = resonReadLEUInt32(data, at: base + 36),
                  let sampleType = resonReadLEUInt16(data, at: base + 44) else {
                continue
            }

            // Skip ROM-linked entries, keep only local PCM sample data.
            if (sampleType & 0x8000) != 0 {
                continue
            }

            let startIdx = Int(start)
            let endIdx = min(samplePoolCount, Int(end))
            if endIdx <= startIdx + 64 || startIdx < 0 || startIdx >= samplePoolCount {
                continue
            }

            let sampleRate = Float(sampleRateRaw)
            if sampleRate < 4_000 || sampleRate > 192_000 {
                continue
            }

            var count = endIdx - startIdx
            let maxFramesPerZone = Int(max(16_000, sampleRate) * 6.0)
            if count > maxFramesPerZone {
                count = maxFramesPerZone
            }

            let bytesStart = chunks.smpl.lowerBound + (startIdx * 2)
            var samples = [Float](repeating: 0, count: count)
            var peak: Float = 0
            for i in 0..<count {
                let b = bytesStart + i * 2
                guard let raw = resonReadLEUInt16(data, at: b) else { continue }
                let s = Int16(bitPattern: raw)
                let f = Float(s) / Float(Int16.max)
                samples[i] = f
                peak = max(peak, abs(f))
            }
            if peak < 0.0005 {
                continue
            }

            let originalPitchRaw = Int(data[base + 40])
            let rootMidi = (0...127).contains(originalPitchRaw) ? originalPitchRaw : 60
            let rms = sqrtf(samples.reduce(0) { $0 + ($1 * $1) } / Float(max(1, samples.count)))
            let comp = min(1.40, max(0.30, 1.0 / max(0.10, rms * 2.8)))
            let lift = min(5.0, max(1.0, 0.90 / max(0.02, peak)))
            decoded.append(
                (
                    rootMidi: rootMidi,
                    sampleRate: max(8_000, sampleRate),
                    samples: samples,
                    gain: instrumentGain * comp * lift,
                    peak: peak
                )
            )
        }

        return resonBuildSampleZones(decoded: decoded)
    }

    private func resonCollectSFZSampleFiles(from sfzURL: URL) -> [URL] {
        guard let text = try? String(contentsOf: sfzURL, encoding: .utf8) else { return [] }
        let baseDir = sfzURL.deletingLastPathComponent()
        var out: [URL] = []
        var seen: Set<String> = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") { continue }
            guard let range = line.range(of: "sample=", options: [.caseInsensitive]) else { continue }
            var rhs = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rhs.isEmpty { continue }

            if rhs.hasPrefix("\"") || rhs.hasPrefix("'") {
                let quote = rhs.removeFirst()
                if let end = rhs.firstIndex(of: quote) {
                    rhs = String(rhs[..<end])
                }
            } else if let space = rhs.firstIndex(where: { $0.isWhitespace }) {
                rhs = String(rhs[..<space])
            }

            rhs = rhs.replacingOccurrences(of: "\\", with: "/")
            if rhs.isEmpty { continue }
            let candidate: URL
            if rhs.hasPrefix("/") {
                candidate = URL(fileURLWithPath: rhs)
            } else {
                candidate = baseDir.appendingPathComponent(rhs)
            }
            let key = candidate.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            if mode4IsAudioFile(candidate), FileManager.default.isReadableFile(atPath: candidate.path) {
                out.append(candidate)
            }
        }
        return out
    }

    private func resonDiscoverFallbackSoundfontURLs(for instrumentId: String) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendCandidate(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            guard ext == "sf2" || ext == "sfz" else { return }
            let key = url.standardizedFileURL.path
            if seen.contains(key) { return }
            seen.insert(key)
            candidates.append(url)
        }

        func scanDirectory(_ dir: URL, recursive: Bool) {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
            if recursive {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return }
                for case let url as URL in enumerator {
                    appendCandidate(url)
                }
            } else {
                guard let entries = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return }
                for entry in entries {
                    appendCandidate(entry)
                }
            }
        }

        for root in mode4AssetRoots() {
            scanDirectory(root.appendingPathComponent("Assets/Soundfonts", isDirectory: true), recursive: true)
            scanDirectory(root.appendingPathComponent("Soundfonts", isDirectory: true), recursive: true)
            // Xcode may flatten copied resources into the bundle root.
            scanDirectory(root, recursive: false)
        }

        guard !candidates.isEmpty else { return [] }
        let sf2Only = candidates.filter { $0.pathExtension.lowercased() == "sf2" }
        let pool = (sf2Only.isEmpty ? candidates : sf2Only)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
        guard !pool.isEmpty else { return [] }

        let start = Int(stableSeed(for: instrumentId) % UInt64(pool.count))
        if start == 0 { return pool }
        return Array(pool[start...]) + Array(pool[..<start])
    }

    private func resonSampleZoneIndex(in instrument: ResonInstrument, midiNote: Int) -> Int? {
        guard !instrument.sampleZones.isEmpty else { return nil }
        if let idx = instrument.sampleZones.firstIndex(where: { midiNote >= $0.lowMidi && midiNote <= $0.highMidi }) {
            return idx
        }
        return instrument.sampleZones.enumerated().min(by: { abs($0.element.rootMidi - midiNote) < abs($1.element.rootMidi - midiNote) })?.offset
    }

    private func resonSampleZoneLinear(_ zone: ResonSampleZone, at frame: Float) -> Float {
        let maxIdx = max(0, zone.samples.count - 1)
        let f = max(0, min(Float(maxIdx), frame))
        let i0 = Int(floorf(f))
        let i1 = min(maxIdx, i0 + 1)
        let frac = f - Float(i0)
        let s0 = zone.samples[i0]
        let s1 = zone.samples[i1]
        return s0 + (s1 - s0) * frac
    }

    private func buildResonInstrument(id: String, entry: InstrumentManifestEntry?) -> ResonInstrument {
        let fallback = ResonInstrument.fallback(id: id)
        guard let entry else {
            mode56LoadInterventions.append("mode56_inst_missing:\(id)")
            return fallback
        }

        let tableCount = 2_048
        let hash = stableSeed(for: id + (entry.samplePackPath ?? "") + (entry.soundfontPath ?? "") + (entry.samplerPresetRef ?? ""))
        let brightness = max(0.05, min(0.95, 0.25 + (Float((hash >> 8) & 0xFF) / 255.0) * 0.7))
        let gain = powf(10.0, Float((entry.gainDb ?? 0.0) / 20.0))
        let polyphony = max(1, min(16, entry.polyphonyHint ?? entry.polyphony ?? 8))
        var sampleZones: [ResonSampleZone] = []
        var sourceKind = "wavetable"
        var sourceRef = "fallback_wavetable"

        if let samplePackPath = entry.samplePackPath, !samplePackPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let files = resonCollectAudioFiles(for: samplePackPath)
            sampleZones = resonLoadSampleZones(from: files, instrumentGain: gain)
            if !sampleZones.isEmpty {
                sourceKind = "sample_pack"
                sourceRef = samplePackPath
            } else {
                mode56LoadInterventions.append("mode56_sample_pack_empty:\(id)")
            }
        }

        if sampleZones.isEmpty {
            let explicitSoundfontPath = entry.soundfontPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            var selectedSoundfontURL: URL?
            if let explicitSoundfontPath, !explicitSoundfontPath.isEmpty {
                selectedSoundfontURL = resolveMode4AssetURL(path: explicitSoundfontPath)
            }
            let discovered = resonDiscoverFallbackSoundfontURLs(for: id)
            var candidates: [URL] = []
            var seenCandidates: Set<String> = []
            if let selectedSoundfontURL {
                let key = selectedSoundfontURL.standardizedFileURL.path
                seenCandidates.insert(key)
                candidates.append(selectedSoundfontURL)
            }
            for candidate in discovered {
                let key = candidate.standardizedFileURL.path
                if seenCandidates.contains(key) { continue }
                seenCandidates.insert(key)
                candidates.append(candidate)
            }
            if selectedSoundfontURL == nil, let first = discovered.first {
                mode56LoadInterventions.append("mode56_soundfont_autopick:\(id)->\(first.lastPathComponent)")
            }

            var tryFailCount = 0
            for candidate in candidates {
                let ext = candidate.pathExtension.lowercased()
                var zones: [ResonSampleZone] = []
                var resolvedSourceKind: String?
                if ext == "sf2" {
                    zones = resonLoadSampleZonesFromSF2(candidate, instrumentGain: gain)
                    if !zones.isEmpty {
                        resolvedSourceKind = "soundfont_sf2"
                    }
                } else if ext == "sfz" {
                    let files = resonCollectSFZSampleFiles(from: candidate)
                    zones = resonLoadSampleZones(from: files, instrumentGain: gain)
                    if !zones.isEmpty {
                        resolvedSourceKind = "soundfont_sfz"
                    }
                }

                if zones.isEmpty {
                    var files: [URL] = resonCollectAudioFiles(for: candidate.path)
                    if files.isEmpty {
                        let companionSeedPath = explicitSoundfontPath ?? candidate.path
                        for companion in resonCompanionSamplePaths(for: companionSeedPath) {
                            files = resonCollectAudioFiles(for: companion)
                            if !files.isEmpty { break }
                        }
                    }
                    zones = resonLoadSampleZones(from: files, instrumentGain: gain)
                    if !zones.isEmpty {
                        resolvedSourceKind = "soundfont_samples"
                    }
                }

                if !zones.isEmpty, let resolvedSourceKind {
                    sampleZones = zones
                    sourceKind = resolvedSourceKind
                    sourceRef = candidate.lastPathComponent
                    mode56LoadInterventions.append("mode56_soundfont_selected:\(id)->\(candidate.lastPathComponent)")
                    break
                } else if tryFailCount < 4 {
                    tryFailCount += 1
                    let token = candidate.lastPathComponent.replacingOccurrences(of: " ", with: "_")
                    mode56LoadInterventions.append("mode56_soundfont_try_fail:\(id):\(token)")
                }
            }

            if sampleZones.isEmpty, !candidates.isEmpty {
                mode56LoadInterventions.append("mode56_soundfont_no_extract:\(id)")
            } else if sampleZones.isEmpty,
                      let explicitSoundfontPath,
                      !explicitSoundfontPath.isEmpty {
                mode56LoadInterventions.append("mode56_soundfont_missing:\(id)")
            }
        }

        var table: [Float]
        if let firstZone = sampleZones.first {
            table = resonBuildWavetableFromSamples(firstZone.samples, tableCount: tableCount)
        } else {
            table = [Float](repeating: 0, count: tableCount)
        }
        let h2 = 0.10 + (0.35 * brightness)
        let h3 = 0.05 + (0.25 * brightness)
        let h4 = 0.02 + (0.15 * brightness)
        let phaseJitter = Float((hash & 0x3FF)) / 1024.0 * Float.pi * 2.0

        if sampleZones.isEmpty {
            for i in 0..<tableCount {
                let ph = 2.0 * Float.pi * Float(i) / Float(tableCount)
                let fundamental = sinf(ph + phaseJitter * 0.05)
                let second = sinf(ph * 2.0 + phaseJitter * 0.21) * h2
                let third = sinf(ph * 3.0 + phaseJitter * 0.37) * h3
                let fourth = sinf(ph * 4.0 + phaseJitter * 0.49) * h4
                table[i] = (fundamental * (0.85 - 0.35 * brightness)) + second + third + fourth
            }
        }
        let sourceToken = sourceRef.replacingOccurrences(of: " ", with: "_")
        mode56LoadInterventions.append("mode56_loaded:\(id):\(sourceKind):\(sampleZones.count):\(sourceToken)")
        print("[audio] mode56 load inst=\(id) source=\(sourceKind) zones=\(sampleZones.count) ref=\(sourceRef)")
        if mode56LoadInterventions.count > 24 {
            mode56LoadInterventions = Array(mode56LoadInterventions.suffix(24))
        }
        return ResonInstrument(
            id: id,
            wavetable: table,
            gain: gain,
            brightness: brightness,
            polyphonyHint: polyphony,
            sampleZones: sampleZones,
            sourceKind: sourceKind,
            sourceRef: sourceRef
        )
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

        let transient = abs(input - resonPrevInput)
        resonEnv += 0.004 * (abs(input) - resonEnv)
        resonPrevInput = input

        let modeVoiceMax = mode == 5 ? 8 : 3
        let requestedVoiceCap: Int
        if mode == 5 {
            requestedVoiceCap = Int(2 + floor(controlCurrent.voiceCap * 6.0))
        } else {
            requestedVoiceCap = Int(2 + floor(controlCurrent.voiceCap * 2.0))
        }
        let effectiveVoiceCap = max(1, min(modeVoiceMax, min(requestedVoiceCap, cpuAction.voiceLimit)))
        if effectiveVoiceCap < requestedVoiceCap {
            interventions.insert(.voiceCap)
        }

        let maxNoteRate: Float = mode == 5 ? 11.0 : 5.5
        let noteRateNorm = Float(controlCurrent.noteRate)
        let noteRateHz: Float = (0.25 + (0.75 * noteRateNorm)) * maxNoteRate
        let noiseTrackAlpha: Float = resonReactiveGateSamples > 0 ? 0.00045 : 0.0025
        resonNoiseFloor += noiseTrackAlpha * (resonEnv - resonNoiseFloor)
        resonNoiseFloor = max(0.00005, min(0.08, resonNoiseFloor))
        let baseEnvOpen = (mode == 5 ? 0.011 : 0.014) + ((mode == 5 ? 0.018 : 0.020) * noteRateNorm)
        let envOpen = max(baseEnvOpen, resonNoiseFloor * (mode == 5 ? 2.8 : 3.2))
        let envClose = envOpen * 0.78
        let transientOpen = (mode == 5 ? 0.0035 : 0.0040) + ((mode == 5 ? 0.011 : 0.012) * noteRateNorm)

        let silenceEnv = max(0.00035, resonNoiseFloor * (mode == 5 ? 1.20 : 1.35))
        let silenceTransient = transientOpen * 0.28
        if resonEnv <= silenceEnv && transient <= silenceTransient {
            resonSilenceSamples += 1
        } else {
            resonSilenceSamples = max(0, resonSilenceSamples - 8)
        }
        let silenceHoldSamples = Int(sampleRate * (mode == 5 ? 0.060 : 0.075))
        let isSilent = resonSilenceSamples >= silenceHoldSamples

        if !isSilent && (resonEnv >= envOpen || transient >= transientOpen) {
            let holdSamples = Int(sampleRate * (mode == 5 ? 0.10 : 0.14))
            resonReactiveGateSamples = max(resonReactiveGateSamples, holdSamples)
        } else if resonEnv <= envClose || isSilent {
            resonReactiveGateSamples = max(0, resonReactiveGateSamples - 1)
        }
        let reactiveActive = resonReactiveGateSamples > 0 && !isSilent
        let levelNormDen = max(0.001, envOpen - silenceEnv)
        let levelNorm = reactiveActive ? max(0, min(1, (resonEnv - silenceEnv) / levelNormDen)) : 0
        resonInputLevel = levelNorm

        if isSilent {
            resonReactiveGateSamples = 0
            resonNoteAccumulator = 0
            resonDesiredVoices = 0
            if !resonIsSilent {
                releaseAllResonVoices(fast: true)
            }
            resonIsSilent = true
        } else {
            resonIsSilent = false
        }

        let transientNormDen = max(0.001, transientOpen * (mode == 5 ? 2.4 : 2.1))
        let transientNorm = max(0, min(1, (transient - (transientOpen * 0.35)) / transientNormDen))
        let envNormDen = max(0.001, envOpen - envClose)
        let envNorm = reactiveActive ? max(0, min(1, (resonEnv - envClose) / envNormDen)) : 0
        let activityNorm = max(levelNorm, transientNorm, envNorm)
        let pitchTracked = resonPitchConf > 0.28
        let detectedMidi = pitchTracked ? (69.0 + (12.0 * log2(max(30.0, resonPitchHz) / 440.0))) : nil
        let pitchMatchStrength: Float = {
            guard pitchTracked else { return 0 }
            let confNorm = max(0, min(1, (resonPitchConf - 0.28) / 0.72))
            let followNorm = max(0.20, Float(controlCurrent.pitchFollow))
            return reactiveActive ? confNorm * followNorm : 0
        }()

        if reactiveActive {
            let volumeRate = powf(max(0, levelNorm), 1.12)
            let rateBoost = 1.0 + ((mode == 5 ? 1.15 : 0.95) * transientNorm)
            resonNoteAccumulator += (noteRateHz * volumeRate * rateBoost) / sampleRate
            resonNoteAccumulator = min(8.0, resonNoteAccumulator)
        } else {
            resonNoteAccumulator = 0
        }
        let minReactiveVoices = mode == 5
            ? min(effectiveVoiceCap, levelNorm > 0.42 ? 2 : 1)
            : min(effectiveVoiceCap, levelNorm > 0.55 ? 2 : 1)
        let variableVoices = max(0, effectiveVoiceCap - minReactiveVoices)
        let desiredVoices = reactiveActive
            ? min(
                effectiveVoiceCap,
                minReactiveVoices + Int((activityNorm * Float(variableVoices)).rounded())
            )
            : 0
        resonDesiredVoices = desiredVoices

        let accumulatedSpawns = Int(floorf(resonNoteAccumulator))
        if accumulatedSpawns > 0 {
            resonNoteAccumulator -= Float(accumulatedSpawns)
        }
        let activeVoicesPre = resonVoices.reduce(0) { $0 + ($1.active ? 1 : 0) }
        let topUpNeed = max(0, desiredVoices - activeVoicesPre)
        var burstBonus = 0
        if transientNorm > 0.72 || levelNorm > 0.70 {
            burstBonus += 1
        }
        if mode == 5 && (transientNorm > 0.88 || levelNorm > 0.86) {
            burstBonus += 1
        }

        var spawnQuota = reactiveActive ? max(0, accumulatedSpawns + burstBonus) : 0
        if spawnQuota == 0, reactiveActive, topUpNeed > 0 {
            let shouldTopUp = levelNorm > (mode == 5 ? 0.24 : 0.32) || transientNorm > (mode == 5 ? 0.40 : 0.52)
            if shouldTopUp {
                spawnQuota = 1
            }
        }
        if topUpNeed > 0 {
            spawnQuota = max(spawnQuota, min(topUpNeed, 1 + burstBonus))
        }
        spawnQuota = max(0, min(spawnQuota, mode == 5 ? 3 : 2))

        if spawnQuota > 0 {
            let contourOffsets: [Int] = mode == 5
                ? [0, 7, 12, 3, 10, -5, 5, 14, -12]
                : [0, 5, 9, 12, -7, 7, 14, -12]
            let wideAntiRepeat: [Int] = mode == 5
                ? [5, 7, 12, -5, -12, 3]
                : [5, 7, 12, -7, 9, -12]
            let tightAntiRepeat: [Int] = [2, -2, 3, -3, 5, -5]
            let antiRepeatSteps = pitchMatchStrength > 0.55 ? tightAntiRepeat : wideAntiRepeat
            var burstMidis: [Int] = []
            for spawnIndex in 0..<spawnQuota {
                let openSlot = resonVoices.firstIndex(where: { !$0.active })
                let slot = openSlot ?? resonVoices.indices.min(by: { resonVoices[$0].age > resonVoices[$1].age })
                guard let slot else { break }
                if openSlot == nil {
                    interventions.insert(.voiceCap)
                }

                var midiTarget = 48 + Int((levelNorm * 28.0) + (transientNorm * 8.0))
                if let detectedMidi {
                    let blended = Float(midiTarget) * (1.0 - pitchMatchStrength) + detectedMidi * pitchMatchStrength
                    midiTarget = Int(blended.rounded())
                }
                let contourIndex = Int(randomUnit() * Float(contourOffsets.count))
                let contourScale = max(0.20, 1.0 - (0.80 * pitchMatchStrength))
                midiTarget += Int((Float(contourOffsets[contourIndex]) * contourScale).rounded())
                if spawnIndex > 0 {
                    let spreadOffsets = mode == 5 ? [12, -12, 7, -5] : [7, -5, 12, -12]
                    let spreadScale = max(0.35, 1.0 - (0.60 * pitchMatchStrength))
                    midiTarget += Int((Float(spreadOffsets[(spawnIndex - 1) % spreadOffsets.count]) * spreadScale).rounded())
                }
                if !resonMotif.isEmpty {
                    midiTarget += resonMotif[resonMotifStep % resonMotif.count]
                    resonMotifStep = (resonMotifStep + 1) % max(1, resonMotif.count)
                }
                var finalMidi = nearestChordMidi(targetMidi: midiTarget, rootMidi: resonRootMidi, intervals: resonChordIntervals)
                if let detectedMidi, pitchMatchStrength > 0.08 {
                    let corrected = (Float(finalMidi) * (1.0 - (0.55 * pitchMatchStrength))) + (detectedMidi * (0.55 * pitchMatchStrength))
                    finalMidi = nearestChordMidi(targetMidi: Int(corrected.rounded()), rootMidi: resonRootMidi, intervals: resonChordIntervals)
                }
                var attempts = 0
                while attempts < antiRepeatSteps.count &&
                    (finalMidi == resonLastMidi || burstMidis.contains(finalMidi)) {
                    let shift = antiRepeatSteps[(spawnIndex + attempts) % antiRepeatSteps.count]
                    finalMidi = nearestChordMidi(
                        targetMidi: finalMidi + shift,
                        rootMidi: resonRootMidi,
                        intervals: resonChordIntervals
                    )
                    attempts += 1
                }
                burstMidis.append(finalMidi)
                resonLastMidi = finalMidi

                let freqHz = 440.0 * powf(2.0, Float(finalMidi - 69) / 12.0)
                let minLenMs: Float = 60
                let maxLenMs: Float = mode == 5 ? 1_500 : 1_200
                var lenMs = minLenMs + (maxLenMs - minLenMs) * (0.15 + 0.75 * (1.0 - Float(controlCurrent.noteRate)))
                lenMs *= 1.14 - (0.58 * levelNorm)
                lenMs *= 1.0 - (0.26 * transientNorm)
                if spawnIndex > 0 {
                    lenMs *= max(0.42, 0.78 - (0.14 * Float(spawnIndex)))
                }
                let articulation = controlCurrent.articulationId.lowercased()
                if articulation.contains("short") {
                    lenMs *= 0.55
                } else if articulation.contains("legato") {
                    lenMs *= 1.20
                }
                lenMs = min(maxLenMs, max(minLenMs, lenMs))
                let sustain = max(1, Int((lenMs / 1000.0) * sampleRate))
                let release = max(1, Int((mode == 5 ? 0.11 : 0.09) * sampleRate))
                let velocityFloor: Float = mode == 5 ? 0.18 : 0.14
                let velocityBase = 0.16 + (levelNorm * 1.9 * Float(controlCurrent.velocityBias))
                let burstVelocity = max(0.62, 1.0 - (Float(spawnIndex) * 0.11))
                let velocity = max(velocityFloor, min(1.0, (velocityBase * burstVelocity) + (0.14 * transientNorm)))
                let panSpeed = (0.0005 + Float(controlCurrent.motionSpeed) * 0.0026) * (0.8 + 0.4 * randomUnit())
                let panRadiusBase = Float(controlCurrent.spread) * (mode == 5 ? 0.95 : 0.85)
                let panRadius = max(0.20, min(1.0, panRadiusBase * (0.82 + 0.30 * activityNorm)))
                let voiceInstrument = resonCurrentInstrument
                var zoneIndex = -1
                var samplePosition: Float = 0
                var sampleStep: Float = 1
                var sustainSamples = sustain
                let zoneMidiHint: Int = {
                    guard let detectedMidi else { return finalMidi }
                    let bias = 0.45 * pitchMatchStrength
                    let hinted = (Float(finalMidi) * (1.0 - bias)) + (detectedMidi * bias)
                    return Int(hinted.rounded())
                }()
                if let selectedZoneIndex = resonSampleZoneIndex(in: voiceInstrument, midiNote: zoneMidiHint) {
                    zoneIndex = selectedZoneIndex
                    let zone = voiceInstrument.sampleZones[selectedZoneIndex]
                    samplePosition = Float(zone.startFrame)
                    let transpose = powf(2.0, Float(finalMidi - zone.rootMidi) / 12.0)
                    let stepMin: Float = pitchMatchStrength > 0.50 ? 0.45 : 0.33
                    let stepMax: Float = pitchMatchStrength > 0.50 ? 2.2 : 3.0
                    sampleStep = max(stepMin, min(stepMax, (zone.sampleRate / sampleRate) * transpose))
                    let availableFrames = max(1, zone.endFrame - zone.startFrame)
                    let maxPlayable = Int(Float(availableFrames) / max(0.01, sampleStep))
                    sustainSamples = max(1, min(sustainSamples, maxPlayable))
                }
                resonVoices[slot].reset(
                    midiNote: finalMidi,
                    freqHz: freqHz,
                    instrumentId: voiceInstrument.id,
                    sampleZoneIndex: zoneIndex,
                    samplePosition: samplePosition,
                    sampleStep: sampleStep,
                    sustainSamples: sustainSamples,
                    releaseSamples: release,
                    velocity: velocity,
                    panPhase: randomUnit() * Float.pi * 2.0,
                    panSpeed: panSpeed,
                    panRadius: panRadius,
                    panOffset: randomUnit() * Float.pi * 2.0
                )
                resonSpawnCount &+= 1
            }
        }

        var activeCount = 0
        var frameEnergy: Float = 0
        for i in 0..<resonVoices.count where resonVoices[i].active {
            activeCount += 1
            if activeCount > effectiveVoiceCap {
                resonVoices[i].sustainSamples = min(resonVoices[i].sustainSamples, resonVoices[i].age)
                resonVoices[i].releaseSamples = min(resonVoices[i].releaseSamples, max(1, Int(sampleRate * 0.05)))
                interventions.insert(.voiceCap)
            }

            let voiceInstrument = cachedResonInstrument(id: resonVoices[i].instrumentId)
            let inh = Float(controlCurrent.inharmonicity)
            let phase = resonVoices[i].phase
            let oscillatorSample = renderResonInstrumentSample(voiceInstrument, phase: phase, inharmonicity: inh)
            let instSample: Float
            if resonVoices[i].sampleZoneIndex >= 0,
               resonVoices[i].sampleZoneIndex < voiceInstrument.sampleZones.count {
                let zone = voiceInstrument.sampleZones[resonVoices[i].sampleZoneIndex]
                if resonVoices[i].samplePosition >= Float(zone.endFrame) {
                    resonVoices[i].active = false
                    continue
                }
                let zoneSample = resonSampleZoneLinear(zone, at: resonVoices[i].samplePosition) * zone.gain
                let fallbackBlend: Float = zone.peak < 0.006 ? 0.25 : 0.0
                instSample = (zoneSample * (1.0 - fallbackBlend)) + (oscillatorSample * fallbackBlend)
                resonVoices[i].samplePosition += resonVoices[i].sampleStep
            } else {
                instSample = oscillatorSample
            }
            resonVoices[i].phase += resonVoices[i].freqHz / sampleRate
            resonVoices[i].phase -= floorf(resonVoices[i].phase)

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
            frameEnergy += voiceOut * voiceOut
            resonVoices[i].panPhase += resonVoices[i].panSpeed
            let x = resonVoices[i].panRadius * cosf(resonVoices[i].panPhase + resonVoices[i].panOffset)
            let y = resonVoices[i].panRadius * sinf((resonVoices[i].panPhase * 0.85) + resonVoices[i].panOffset * 0.6)
            GridSpatializer.fillNormalizedPointGains(
                x: x,
                y: y,
                spread: max(0.25, min(1.0, Float(controlCurrent.spread))),
                into: &targetGains
            )
            let modeWetBoost: Float = mode == 5 ? 1.65 : 1.35
            applyGains(voiceOut * Float(controlCurrent.wetLevel) * modeWetBoost, gains: targetGains, &ch0, &ch1, &ch2, &ch3, &ch4, &ch5)
            reverbSend += voiceOut * (mode == 5 ? 0.18 : 0.12)

            let releaseStartAge = resonVoices[i].sustainSamples
            let releaseDoneAge = resonVoices[i].sustainSamples + resonVoices[i].releaseSamples
            let nextAge = resonVoices[i].age + 1
            if nextAge > releaseDoneAge
                || (resonVoices[i].age >= releaseStartAge && env <= 0.0001) {
                resonVoices[i].active = false
            } else {
                resonVoices[i].age = nextAge
            }
        }

        resonOutputEnergyAccum += frameEnergy
        resonOutputMeterSamples += 1
        let meterWindow = max(256, Int(sampleRate * 0.10))
        if resonOutputMeterSamples >= meterWindow {
            resonLastOutputRMS = sqrtf(resonOutputEnergyAccum / Float(max(1, resonOutputMeterSamples)))
            resonOutputEnergyAccum = 0
            resonOutputMeterSamples = 0
        }

        resonDebugCounter += 1
    }

    private func mode7CrossfadeSamples() -> Int {
        let ms = 20.0 + (580.0 * Float(controlCurrent.swapCrossfade))
        return max(1, Int((ms / 1_000.0) * sampleRate))
    }

    private func mode7ApplyMatrix(bands: [Float], matrix: [Float], into mapped: inout [Float]) {
        for dst in 0..<8 {
            var acc: Float = 0
            for src in 0..<8 {
                acc += bands[src] * matrix[src * 8 + dst]
            }
            mapped[dst] = acc
        }
    }

    private func setMode7TargetMatrix(mappingId: String, mappingFamily: String, bias: Float, varianceAmt: Float, seed: Int) {
        let mId = mappingId.isEmpty ? "swap_pairs" : mappingId
        let family = mappingFamily.isEmpty ? "bucket_swap" : mappingFamily
        let ent = max(0, min(1, bias))
        let varAmt = max(0, min(1, varianceAmt))
        let configChanged =
            mode7State.mappingId != mId ||
            mode7State.mappingFamily != family ||
            abs(mode7State.entropy - ent) > 0.0001 ||
            abs(mode7State.variance - varAmt) > 0.0001 ||
            mode7State.seed != seed

        mode7State.mappingId = mId
        mode7State.mappingFamily = family
        mode7State.entropy = ent
        mode7State.variance = varAmt
        mode7State.seed = seed

        guard configChanged else { return }
        let immediateMatrix = Mode7SceneBuilder.buildMatrix(
            mappingId: mId,
            mappingFamily: family,
            sharpness: Float(controlCurrent.sharpness),
            entropy: ent,
            varianceAmt: varAmt,
            seed: seed,
            sceneStep: mode7State.scheduler.sceneStep
        )
        let immediateBandGains = Mode7SceneBuilder.buildBandGains(
            mappingId: mId,
            mappingFamily: family,
            sharpness: Float(controlCurrent.sharpness),
            entropy: ent,
            varianceAmt: varAmt,
            seed: seed,
            sceneStep: mode7State.scheduler.sceneStep
        )
        mode7State.scheduler.beginCrossfade(
            to: immediateMatrix,
            crossfadeSamples: max(1, Int(sampleRate * 0.02)),
            bandGains: immediateBandGains
        )
        mode7State.scheduler.advanceMatrix()
    }

    private func processMode7(input: Float) -> Float {
        mode7State.clock.advance()

        let delta = abs(input - mode7State.prevInput)
        mode7State.prevInput = input
        mode7State.inputEnv += 0.0038 * (abs(input) - mode7State.inputEnv)
        let sharp = max(0, min(1, Float(controlCurrent.sharpness)))
        let inputActivity = max(0, min(1, (mode7State.inputEnv * 16.0) + (delta * 18.0)))
        let onsetThreshold = 0.004 + (0.020 * (1.0 - sharp))
        let loudEnough = mode7State.inputEnv > 0.006
        let minOnsetGap = Int64(sampleRate * 0.055)
        if loudEnough,
           delta > onsetThreshold,
           (mode7State.clock.lastOnsetSample < 0 || (sampleCounter - mode7State.clock.lastOnsetSample) >= minOnsetGap) {
            mode7State.clock.noteOnset(sampleCounter: sampleCounter, sampleRate: sampleRate)
        } else {
            mode7State.clock.confidenceDecay()
        }

        let stepSamples = mode7State.clock.stepSamples(
            sampleRate: sampleRate,
            swapRateNorm: Float(controlCurrent.morphRate)
        )
        if mode7State.scheduler.samplesUntilStep <= 0 {
            let nextMatrix = Mode7SceneBuilder.buildMatrix(
                mappingId: mode7State.mappingId,
                mappingFamily: mode7State.mappingFamily,
                sharpness: Float(controlCurrent.sharpness),
                entropy: mode7State.entropy,
                varianceAmt: mode7State.variance,
                seed: mode7State.seed,
                sceneStep: mode7State.scheduler.sceneStep
            )
            let nextBandGains = Mode7SceneBuilder.buildBandGains(
                mappingId: mode7State.mappingId,
                mappingFamily: mode7State.mappingFamily,
                sharpness: Float(controlCurrent.sharpness),
                entropy: mode7State.entropy,
                varianceAmt: mode7State.variance,
                seed: mode7State.seed,
                sceneStep: mode7State.scheduler.sceneStep
            )
            mode7State.scheduler.beginCrossfade(
                to: nextMatrix,
                crossfadeSamples: mode7CrossfadeSamples(),
                bandGains: nextBandGains
            )
            mode7State.scheduler.advanceSceneStep()
            mode7State.scheduler.samplesUntilStep = stepSamples
        } else {
            mode7State.scheduler.samplesUntilStep -= 1
        }
        mode7State.scheduler.advanceMatrix()

        mode7State.splitBands(input: input)
        mode7ApplyMatrix(
            bands: mode7State.bands,
            matrix: mode7State.scheduler.liveMatrix,
            into: &mode7State.mapped
        )

        var wet: Float = 0
        for i in 0..<mode7State.mapped.count {
            wet += mode7State.mapped[i] * mode7State.scheduler.liveBandGains[i]
        }

        // Emphasize moving spectral edges so the redistribution reads in a real room.
        var spectralEdge: Float = 0
        var lowMidBody: Float = 0
        for i in 0..<mode7State.mapped.count {
            let band = mode7State.mapped[i] * mode7State.scheduler.liveBandGains[i]
            let left = i > 0 ? mode7State.mapped[i - 1] * mode7State.scheduler.liveBandGains[i - 1] : band
            let right = i + 1 < mode7State.mapped.count ? mode7State.mapped[i + 1] * mode7State.scheduler.liveBandGains[i + 1] : band
            spectralEdge += band - 0.5 * (left + right)
            if i >= 1 && i <= 4 {
                let weight: Float = i <= 2 ? 1.12 : 1.0
                lowMidBody += band * weight
            }
        }
        let edgeGain = (0.22 + 1.10 * sharp) * (0.35 + 0.95 * inputActivity)
        wet += spectralEdge * edgeGain
        wet += lowMidBody * (0.10 + 0.16 * (1.0 - sharp))

        let targetNorm = min(2.40, max(0.70, 0.40 / max(0.03, abs(wet))))
        mode7State.loudnessNorm += 0.0035 * (targetNorm - mode7State.loudnessNorm)
        wet *= mode7State.loudnessNorm

        let cutoff = 1_400.0 + (8_600.0 * (0.20 + 0.80 * sharp))
        let alpha = onePoleAlpha(cutoffHz: cutoff, sampleRate: sampleRate)
        mode7State.hfClampY += alpha * (wet - mode7State.hfClampY)
        let clampMix = 0.30 + (0.40 * (1.0 - sharp))
        let postClamp = (wet * (1.0 - clampMix)) + (mode7State.hfClampY * clampMix)
        let drive = 1.24 + (0.62 * inputActivity) + (0.32 * sharp)
        return tanhf(postClamp * drive)
    }

    private func wrappedSample(_ index: Int) -> Float {
        var i = index % granBuffer.count
        if i < 0 { i += granBuffer.count }
        return granBuffer[i]
    }

    private func sampleLinear(at position: Float) -> Float {
        let i0 = Int(floorf(position))
        let frac = position - Float(i0)
        let s0 = wrappedSample(i0)
        let s1 = wrappedSample(i0 + 1)
        return s0 + (s1 - s0) * frac
    }

    private func sampleCubic(at position: Float) -> Float {
        let i1 = Int(floorf(position))
        let t = position - Float(i1)
        let ym1 = wrappedSample(i1 - 1)
        let y0 = wrappedSample(i1)
        let y1 = wrappedSample(i1 + 1)
        let y2 = wrappedSample(i1 + 2)
        let a0 = -0.5 * ym1 + 1.5 * y0 - 1.5 * y1 + 0.5 * y2
        let a1 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
        let a2 = -0.5 * ym1 + 0.5 * y1
        let a3 = y0
        return ((a0 * t + a1) * t + a2) * t + a3
    }

    private func sampleGranulator(at position: Float, quality: Float) -> Float {
        if quality >= 0.7 {
            return sampleCubic(at: position)
        } else if quality >= 0.32 {
            return sampleLinear(at: position)
        }
        return wrappedSample(Int(position))
    }

    private func grainEnvelope(age: Int, length: Int, blend: Float) -> Float {
        let t = min(max(Float(age) / Float(max(1, length)), 0), 1)
        let hann = 0.5 - 0.5 * cosf(2.0 * .pi * t)
        let blackman = 0.42 - 0.5 * cosf(2.0 * .pi * t) + 0.08 * cosf(4.0 * .pi * t)
        return hann * (1.0 - blend) + blackman * blend
    }

    private func processGranulator(input: Float, cpuAction: CPUGuardAction, interventions: inout SafetyInterventions) -> Float {
        granBuffer[granWrite] = input
        granWrite += 1
        if granWrite >= granBuffer.count { granWrite = 0 }

        let density = Float(controlCurrent.grainDensity) * cpuAction.densityScale
        if cpuAction.active {
            interventions.insert(.densityCap)
        }

        let transient = abs(input - mode2State.prevInput)
        mode2State.prevInput = input
        if transient > (0.03 + 0.08 * density) {
            mode2State.transientDuck = max(mode2State.transientDuck, 0.85)
        } else {
            mode2State.transientDuck *= 0.996
        }

        let spawnRateHz = 2.2 + density * 52.0
        let interval = max(1, Int(sampleRate / spawnRateHz))
        if !mode2State.readHeadSeeded {
            mode2State.readHeadSeeded = true
            mode2State.readHead = Float(granWrite) - (sampleRate * 0.24)
            if mode2State.readHead < 0 {
                mode2State.readHead += Float(granBuffer.count)
            }
        }
        if mode2State.spawnCounter <= 0 {
            let voiceLimit = min(mode2State.grains.count, cpuAction.voiceLimit)
            var spawnedCount = 0
            let pitchSpreadCents = 35.0 * Float(controlCurrent.grainPitchSpread)
            let scanRate = Float(controlCurrent.scanRate)
            let burstCount = density > 0.56 ? 2 : 1
            for _ in 0..<burstCount {
                guard let slot = (0..<voiceLimit).first(where: { !mode2State.grains[$0].active }) else { break }
                let lenMs = 14.0 + 148.0 * Float(controlCurrent.grainSize)
                let len = max(16, Int((lenMs / 1000.0) * sampleRate))
                let scatter = (randomUnit() * 2.0 - 1.0) * sampleRate * (0.06 + 0.42 * Float(controlCurrent.grainSize))
                var position = mode2State.readHead + scatter
                while position < 0 { position += Float(granBuffer.count) }
                while position >= Float(granBuffer.count) { position -= Float(granBuffer.count) }
                let cents = (randomUnit() * 2.0 - 1.0) * pitchSpreadCents
                let scanWarp = 0.52 + 1.42 * scanRate
                let jitterWarp = 0.82 + 0.44 * randomUnit()
                var detuneStep = scanWarp * jitterWarp * powf(2.0, cents / 1200.0)
                if randomUnit() < (0.10 + 0.20 * Float(controlCurrent.grainPitchSpread)) {
                    detuneStep = -detuneStep * (0.88 + 0.18 * randomUnit())
                }
                detuneStep = max(-2.4, min(2.4, detuneStep))
                let pan = randomUnit() * 2.0 - 1.0
                let decorrelation = (6.0 + 48.0 * abs(pan)) * (0.6 + 0.4 * density)
                let envBlend = min(1.0, max(0.0, 0.35 + 0.50 * Float(controlCurrent.grainSize)))
                mode2State.grains[slot].reset(
                    position: position,
                    step: detuneStep,
                    decorrelationSamples: decorrelation,
                    pan: pan,
                    envelopeBlend: envBlend,
                    length: len,
                    gain: 0.40 + 0.52 * randomUnit()
                )
                spawnedCount += 1
            }
            if spawnedCount == 0 && cpuAction.active {
                interventions.insert(.voiceCap)
            }
            mode2State.spawnCounter = interval
        } else {
            mode2State.spawnCounter -= 1
        }

        if mode2State.freezeSamplesRemaining > 0 {
            mode2State.freezeSamplesRemaining -= 1
        } else if mode2State.freezeCooldownSamples > 0 {
            mode2State.freezeCooldownSamples -= 1
        } else {
            if randomUnit() < Float(controlCurrent.freezeProb) * 0.0021 {
                mode2State.beginFreeze(sampleRate: sampleRate, requestedLenSec: Float(controlCurrent.freezeLenSec))
            } else {
                let scanRate = Float(controlCurrent.scanRate)
                let targetStep = 0.10 + 1.9 * scanRate
                mode2State.scanVelocity += 0.0045 * (targetStep - mode2State.scanVelocity)
                let driftNoise = (randomUnit() * 2.0 - 1.0) * (0.008 + 0.050 * scanRate)
                mode2State.sceneWander = (mode2State.sceneWander * 0.992) + driftNoise
                mode2State.readHead += mode2State.scanVelocity + mode2State.sceneWander

                var writeAhead = Float(granWrite) - mode2State.readHead
                if writeAhead < 0 {
                    writeAhead += Float(granBuffer.count)
                }
                let minLag = sampleRate * 0.07
                let maxLag = sampleRate * 0.95
                if writeAhead < minLag {
                    mode2State.readHead -= (minLag - writeAhead) * 0.16
                } else if writeAhead > maxLag {
                    mode2State.readHead += (writeAhead - maxLag) * 0.08
                }

                if randomUnit() < Float(controlCurrent.scanJumpProb) * 0.0019 {
                    let jumpDepth = sampleRate * (0.06 + 0.26 * scanRate)
                    mode2State.readHead += (randomUnit() - 0.5) * jumpDepth
                }
                while mode2State.readHead < 0 { mode2State.readHead += Float(granBuffer.count) }
                while mode2State.readHead >= Float(granBuffer.count) { mode2State.readHead -= Float(granBuffer.count) }
            }
        }

        var out: Float = 0
        for i in 0..<mode2State.grains.count where mode2State.grains[i].active {
            let base = sampleGranulator(at: mode2State.grains[i].position, quality: cpuAction.interpolationQuality)
            let decoPos = mode2State.grains[i].position + mode2State.grains[i].decorrelationSamples
            let decorrelated = sampleGranulator(at: decoPos, quality: cpuAction.interpolationQuality)
            let panAmt = 0.12 + 0.38 * abs(mode2State.grains[i].pan) * Float(controlCurrent.spread)
            let sample = (base * (1.0 - panAmt)) + (decorrelated * panAmt)
            let env = grainEnvelope(
                age: mode2State.grains[i].age,
                length: mode2State.grains[i].length,
                blend: mode2State.grains[i].envelopeBlend
            )
            out += sample * env * mode2State.grains[i].gain

            mode2State.grains[i].position += mode2State.grains[i].step
            while mode2State.grains[i].position >= Float(granBuffer.count) {
                mode2State.grains[i].position -= Float(granBuffer.count)
            }
            while mode2State.grains[i].position < 0 {
                mode2State.grains[i].position += Float(granBuffer.count)
            }
            mode2State.grains[i].age += 1
            if mode2State.grains[i].age >= mode2State.grains[i].length {
                mode2State.grains[i].active = false
            }
        }

        let targetNorm = min(1.9, max(0.34, 0.24 / max(0.02, abs(out))))
        mode2State.loudnessNorm += 0.0018 * (targetNorm - mode2State.loudnessNorm)
        out *= mode2State.loudnessNorm

        let densityT = density
        let cutoff = 1_800.0 + 5_200.0 * (1.0 - densityT)
        let alpha = onePoleAlpha(cutoffHz: cutoff, sampleRate: sampleRate)
        mode2State.dampLP += alpha * (out - mode2State.dampLP)
        let tilt = min(0.62, 0.12 + densityT * 0.55)
        let filtered = (out * (1.0 - tilt)) + (mode2State.dampLP * tilt)
        let safetyGain = 0.52 + 0.12 * cpuAction.wetScale
        return tanhf(filtered * safetyGain)
    }

    private func processMode3(input: Float) -> Float {
        let drive = max(0, min(1, Float(controlCurrent.drive)))
        let resonance = max(0, min(1, Float(controlCurrent.resonance)))
        let downNorm = max(0, min(1, Float(controlCurrent.downsample)))
        let bitDepthControl = Float(controlCurrent.bitDepth)
        let bits = max(8, min(24, Int((8.0 + (bitDepthControl * 8.0)).rounded())))
        let bitDepthNorm = (Float(bits) - 8.0) / 16.0
        let severity = min(1.0, max(0.0, (0.58 * (1.0 - bitDepthNorm)) + (0.42 * downNorm)))
        // Gallery-safe bitcrush: keep the bloom, drop the RAT-pedal gain stage.
        let preGain = 0.85 + (2.2 * drive)
        let driven = tanhf(input * preGain)
        let texture = processMode3Inharmonic(input: driven)
        let textureMix = 0.02 + (0.10 * resonance)
        let source = (driven * (1.0 - textureMix)) + (texture * textureMix)
        let crushed = processMode3BitCore(input: source)
        let crusherDelta = crushed - source
        let emphasized = crushed + (crusherDelta * (0.10 + (0.25 * severity)))
        let shaped = processMode3SafetyShaping(input: emphasized)
        let glue = 0.85 + (0.10 * drive)
        return tanhf(shaped * glue) * 0.35
    }

    private func processMode3Inharmonic(input: Float) -> Float {
        let spread = max(0, min(1, Float(controlCurrent.resonance)))
        let depth = max(0, min(1, Float(controlCurrent.drive)))
        let tone = max(0, min(1, Float(controlCurrent.exciteAmount)))
        let downNorm = max(0, min(1, Float(controlCurrent.downsample)))

        // Keep a smooth activity follower; avoid transient-triggered jumps that read as clicks.
        mode3State.env += 0.010 * (abs(input) - mode3State.env)
        let transient = abs(input - mode3State.prevInput)
        mode3State.prevInput = input
        mode3State.triggerSmoothed += 0.020 * (transient - mode3State.triggerSmoothed)

        let baseHz: Float = 78.0 + (132.0 * spread) + (96.0 * tone)
        let ratioA: Float = 1.313 + (0.52 * spread)
        let ratioB: Float = 2.071 + (0.44 * spread)
        let ratioRing: Float = 2.743 + (0.52 * tone)
        let carrierHz = baseHz * (1.0 + 0.06 * tone)

        mode3State.modPhaseA += (2.0 * .pi * baseHz * ratioA) / sampleRate
        mode3State.modPhaseB += (2.0 * .pi * baseHz * ratioB) / sampleRate
        mode3State.ringPhase += (2.0 * .pi * baseHz * ratioRing) / sampleRate
        mode3State.shimmerPhase += (2.0 * .pi * (16.0 + (58.0 * spread))) / sampleRate
        mode3State.carrierPhase += (2.0 * .pi * carrierHz) / sampleRate
        if mode3State.modPhaseA > 2.0 * .pi { mode3State.modPhaseA -= 2.0 * .pi }
        if mode3State.modPhaseB > 2.0 * .pi { mode3State.modPhaseB -= 2.0 * .pi }
        if mode3State.ringPhase > 2.0 * .pi { mode3State.ringPhase -= 2.0 * .pi }
        if mode3State.shimmerPhase > 2.0 * .pi { mode3State.shimmerPhase -= 2.0 * .pi }
        if mode3State.carrierPhase > 2.0 * .pi { mode3State.carrierPhase -= 2.0 * .pi }

        let modA = sinf(mode3State.modPhaseA)
        let modB = sinf(mode3State.modPhaseB)
        let shimmer = sinf(mode3State.shimmerPhase)
        let modSignal = (modA * 0.56) + (modB * 0.44) + (shimmer * 0.20)
        let fmIndex = 0.18 + (1.12 * depth) + (0.46 * mode3State.env)
        let carrier = sinf(mode3State.carrierPhase + (fmIndex * modSignal))
        let sideA = sinf((mode3State.carrierPhase * 1.41) + (modB * 1.07))
        let sideB = sinf((mode3State.carrierPhase * 2.07) + (modA * 0.88))
        let ringed = carrier * sinf(mode3State.ringPhase)
        let texture = (carrier * 0.44) + (sideA * 0.22) + (sideB * 0.18) + (ringed * 0.24)
        let activity = min(1.0, (mode3State.env * 8.0) + (transient * 6.0))
        let textureAmt = (0.06 + (0.22 * spread) + (0.10 * tone)) * activity * (1.0 - 0.35 * downNorm)
        let inputAnchor = input * (0.68 + (0.16 * depth))
        return inputAnchor + (texture * textureAmt)
    }

    private func mode3BellBucketFrequency(spread: Float, tone: Float, trigger: Float, input: Float) -> Float {
        let buckets: [Float] = [110.0, 130.81, 146.83, 174.61, 196.0, 220.0, 261.63, 293.66, 329.63, 392.0, 440.0, 523.25]
        let weighted = min(0.999, max(0.0, (0.52 * spread) + (0.28 * tone) + (0.20 * min(1.0, trigger * 8.0))))
        let baseIndex = min(buckets.count - 1, max(0, Int(weighted * Float(buckets.count))))
        let offset = (input >= 0 ? 1 : -1) * ((mode3State.strikeIndex % 3) - 1)
        let idx = max(0, min(buckets.count - 1, baseIndex + offset))
        let base = buckets[idx]
        let semitone = roundf(12.0 * log2f(base / 55.0))
        let quantized = 55.0 * powf(2.0, semitone / 12.0)
        return quantized * (1.0 + (0.05 * (spread - 0.5)))
    }

    private func processMode3BitCore(input: Float) -> Float {
        let bitDepthControl = Float(controlCurrent.bitDepth)
        let bits = max(8, min(24, Int((8.0 + (bitDepthControl * 8.0)).rounded())))
        let effectiveBits = max(3, min(12, Int((Float(bits) * 0.45).rounded())))
        let bitDepthNorm = (Float(effectiveBits) - 3.0) / 9.0
        let downNorm = max(0, min(1, Float(controlCurrent.downsample)))
        let levels = powf(2.0, Float(effectiveBits - 1))
        let quantized = roundf(input * levels) / max(1.0, levels)

        let downForHold = max(0.15, downNorm)
        let holdN = max(2, Int(2 + (powf(downForHold, 1.20) * 220.0)))
        if mode3State.holdCounter <= 0 {
            mode3State.holdSample = quantized
            mode3State.holdCounter = holdN
        } else {
            mode3State.holdCounter -= 1
        }
        // De-zipper S&H edges to avoid impulse-like clicks while preserving grit.
        let holdSmooth = 0.18 + (0.42 * (1.0 - downNorm))
        mode3State.holdSmoothed += holdSmooth * (mode3State.holdSample - mode3State.holdSmoothed)

        let baseSeverity = min(1.0, max(0.0, (0.58 * (1.0 - bitDepthNorm)) + (0.42 * downNorm)))
        let severity = max(0.45, baseSeverity)
        let crushMix = min(1.0, 0.88 + (0.12 * severity))
        let aliased = mode3State.holdSmoothed + ((quantized - mode3State.holdSmoothed) * (0.08 + (0.72 * downNorm)))
        return ((1.0 - crushMix) * input) + (crushMix * aliased)
    }

    private func processMode3SafetyShaping(input: Float) -> Float {
        let tone = max(0, min(1, Float(controlCurrent.exciteAmount)))
        let hfCutoff = 1_700.0 + (5_200.0 * (0.35 + (0.65 * tone)))
        let hfAlpha = onePoleAlpha(cutoffHz: hfCutoff, sampleRate: sampleRate)
        mode3State.hfClampY += hfAlpha * (input - mode3State.hfClampY)
        let hf = input - mode3State.hfClampY

        mode3State.deEssEnv += 0.009 * (abs(hf) - mode3State.deEssEnv)
        let deEss = min(0.55, max(0.0, (mode3State.deEssEnv - 0.08) * (3.6 - (1.2 * tone))))
        let hfSafe = hf * (1.0 - deEss)

        let lowMidCutoff = 240.0 + (280.0 * (1.0 - tone))
        let lowMidAlpha = onePoleAlpha(cutoffHz: lowMidCutoff, sampleRate: sampleRate)
        mode3State.lowMidLP += lowMidAlpha * (input - mode3State.lowMidLP)
        let lowMidControl = 0.04 + (0.14 * Float(controlCurrent.resonance)) + (0.05 * mode3State.env)
        var shaped = (mode3State.hfClampY + hfSafe) - (mode3State.lowMidLP * lowMidControl)

        let tilt = -0.30 + (0.70 * tone)
        shaped += hfSafe * tilt * 0.20

        let dcBlocked = shaped - mode3State.dcPrevX + (0.995 * mode3State.dcPrevY)
        mode3State.dcPrevX = shaped
        mode3State.dcPrevY = dcBlocked
        return dcBlocked
    }

    private func processMode3ReverbClamp(input: Float) -> Float {
        let tone = max(0, min(1, Float(controlCurrent.exciteAmount)))
        let cutoff = 1_400.0 + (3_600.0 * tone)
        let alpha = onePoleAlpha(cutoffHz: cutoff, sampleRate: sampleRate)
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

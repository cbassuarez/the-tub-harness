//
//  AudioInputAnalyzer.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreAudio
import AudioToolbox

enum AudioInStatus: Equatable {
    case stopped
    case starting
    case running
    case permissionDenied
    case noDevice
    case failed(String)

    var fallbackReason: String? {
        switch self {
        case .stopped: return "audio_input_stopped"
        case .starting: return "audio_input_starting"
        case .running: return nil
        case .permissionDenied: return "permissionDenied"
        case .noDevice: return "noDevice"
        case .failed(let msg): return "audioInputError:\(msg)"
        }
    }

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .permissionDenied: return "permissionDenied"
        case .noDevice: return "noDevice"
        case .failed(let msg): return "error: \(msg)"
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
}

struct FeaturePacketSnapshot {
    let features: Features
    let source: String
    let fallbackReason: String?
}

/// Captures audio input and computes a bounded feature frame at ~10 Hz.
final class AudioInputAnalyzer: ObservableObject {
    private let lock = NSLock()
    private let analysisQueue = DispatchQueue(label: "tub.audio.analysis", qos: .userInitiated)

    private let audioIn = AudioInService()
    private var extractor = FeatureExtractor(sampleRate: 48_000)
    private var timer: DispatchSourceTimer?
    private var cancellables: Set<AnyCancellable> = []

    private var latestStorage = FeaturePacketSnapshot(
        features: .silence,
        source: "dummy",
        fallbackReason: "audio_input_stopped"
    )

    @Published private(set) var latestFeatures: Features = .silence
    @Published private(set) var inputStatus: AudioInStatus = .stopped
    @Published private(set) var fallbackReason: String? = "audio_input_stopped"
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedInputUID: String = ""
    @Published private(set) var activeInputName: String = "System Default"

    init() {
        audioIn.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.inputStatus = status
            }
            .store(in: &cancellables)

        audioIn.$activeInputName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.activeInputName = name
            }
            .store(in: &cancellables)

        refreshInputDevices()
    }

    func start() {
        guard timer == nil else { return }

        refreshInputDevices()
        audioIn.start()

        let t = DispatchSource.makeTimerSource(queue: analysisQueue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(100), leeway: .milliseconds(8))
        t.setEventHandler { [weak self] in
            self?.computeTick()
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        audioIn.stop()

        publish(
            FeaturePacketSnapshot(
                features: .silence,
                source: "dummy",
                fallbackReason: AudioInStatus.stopped.fallbackReason
            )
        )
    }

    /// Safe to call from any thread.
    func snapshot() -> Features {
        lock.lock(); defer { lock.unlock() }
        return latestStorage.features
    }

    /// Safe to call from UDP queue.
    func snapshotFrame() -> FeaturePacketSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latestStorage
    }

    func refreshInputDevices() {
        let devices = CoreAudioInputCatalog.listInputDevices()
        let selected = audioIn.selectedInputUID() ?? CoreAudioInputCatalog.defaultInputUID() ?? devices.first?.uid ?? ""

        DispatchQueue.main.async {
            self.inputDevices = devices
            self.selectedInputUID = selected
            if let d = devices.first(where: { $0.uid == selected }) {
                self.activeInputName = d.name
            } else if devices.isEmpty {
                self.activeInputName = "No Input Device"
            }
        }
    }

    func selectInputDevice(uid: String) {
        guard !uid.isEmpty else { return }

        do {
            try audioIn.selectInputDevice(uid: uid)
            DispatchQueue.main.async {
                self.selectedInputUID = uid
            }
            refreshInputDevices()
        } catch {
            DispatchQueue.main.async {
                self.fallbackReason = "audio_input_select_failed:\(error.localizedDescription)"
            }
        }
    }

    private func computeTick() {
        let status = audioIn.status
        guard status == .running else {
            publish(
                FeaturePacketSnapshot(
                    features: .silence,
                    source: "dummy",
                    fallbackReason: status.fallbackReason ?? "audio_input_unavailable"
                )
            )
            return
        }

        if let staleMs = audioIn.msSinceLastInput, staleMs > 750 {
            publish(
                FeaturePacketSnapshot(
                    features: .silence,
                    source: "dummy",
                    fallbackReason: "audio_input_stale_\(Int(staleMs))ms"
                )
            )
            return
        }

        let sampleRate = audioIn.sampleRate
        extractor.updateSampleRate(sampleRate)

        let sampleCount = max(256, Int(sampleRate * 0.1))
        let mono = audioIn.snapshotLastSamples(count: sampleCount)
        let features = extractor.extract(samples: mono)

        publish(
            FeaturePacketSnapshot(
                features: features,
                source: "audio_in",
                fallbackReason: nil
            )
        )
    }

    private func publish(_ frame: FeaturePacketSnapshot) {
        lock.lock()
        latestStorage = frame
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.latestFeatures = frame.features
            self?.fallbackReason = frame.fallbackReason
        }
    }
}

private final class AudioInService: ObservableObject {
    @Published private(set) var status: AudioInStatus = .stopped
    @Published private(set) var activeInputName: String = "System Default"

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private let ringSeconds: Double = 2.0
    private var ring: [Float] = Array(repeating: 0, count: 96_000)
    private var writeIndex: Int = 0
    private var filled: Bool = false
    private var sampleRateStorage: Double = 48_000
    private var lastIngestNs: UInt64 = 0
    private var preferredInputUID: String?

    var sampleRate: Double {
        lock.lock(); defer { lock.unlock() }
        return sampleRateStorage
    }

    var msSinceLastInput: Double? {
        lock.lock()
        let last = lastIngestNs
        lock.unlock()
        guard last > 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now - last) / 1_000_000.0
    }

    func start() {
        refreshActiveInputName()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()

        case .notDetermined:
            DispatchQueue.main.async { self.status = .starting }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startEngine()
                } else {
                    DispatchQueue.main.async {
                        self.status = .permissionDenied
                    }
                }
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                self.status = .permissionDenied
            }

        @unknown default:
            DispatchQueue.main.async {
                self.status = .failed("unknown authorization state")
            }
        }
    }

    func selectedInputUID() -> String? {
        lock.lock()
        let preferred = preferredInputUID
        lock.unlock()
        return preferred ?? CoreAudioInputCatalog.defaultInputUID()
    }

    func selectInputDevice(uid: String) throws {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "AudioInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "Input UID is empty"])
        }

        lock.lock()
        preferredInputUID = uid
        lock.unlock()

        refreshActiveInputName()

        if status == .running || status == .starting {
            startEngine()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async {
            self.status = .stopped
        }
    }

    func snapshotLastSamples(count: Int) -> [Float] {
        guard count > 0 else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var out = [Float](repeating: 0, count: count)

        let cap = ring.count
        let available = filled ? cap : writeIndex
        guard available > 0 else { return out }

        let take = min(count, available)
        let end = writeIndex
        var start = end - take
        if start < 0 { start += cap }

        if start + take <= cap {
            out.replaceSubrange((count - take)..<count, with: ring[start..<(start + take)])
        } else {
            let firstLen = cap - start
            out.replaceSubrange((count - take)..<(count - take + firstLen), with: ring[start..<cap])
            let secondLen = take - firstLen
            out.replaceSubrange((count - secondLen)..<count, with: ring[0..<secondLen])
        }

        return out
    }

    private func startEngine() {
        DispatchQueue.main.async {
            self.status = .starting
        }

        if engine.isRunning {
            engine.stop()
        }

        let input = engine.inputNode
        lock.lock()
        let preferredUID = preferredInputUID
        lock.unlock()

        if let preferredUID, !preferredUID.isEmpty {
            do {
                try CoreAudioInputCatalog.setCurrentInputDevice(on: input, uid: preferredUID)
            } catch {
                print("[audio_in] warning: failed to bind input device \(preferredUID): \(error)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        let channels = Int(format.channelCount)

        guard channels > 0 else {
            DispatchQueue.main.async {
                self.status = .noDevice
            }
            return
        }

        lock.lock()
        sampleRateStorage = max(8_000, format.sampleRate)
        let cap = max(8_192, Int(sampleRateStorage * ringSeconds))
        ring = Array(repeating: 0, count: cap)
        writeIndex = 0
        filled = false
        lastIngestNs = 0
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }

        do {
            try engine.start()
            DispatchQueue.main.async {
                self.status = .running
            }
        } catch {
            DispatchQueue.main.async {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)

        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: channels[0], count: frameCount)
            }
        } else {
            for c in 0..<channelCount {
                let src = channels[c]
                for i in 0..<frameCount {
                    mono[i] += src[i]
                }
            }
            var inv = 1.0 / Float(channelCount)
            vDSP_vsmul(mono, 1, &inv, &mono, 1, vDSP_Length(frameCount))
        }

        let now = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let cap = ring.count
        var w = writeIndex
        for s in mono {
            ring[w] = s
            w += 1
            if w >= cap {
                w = 0
                filled = true
            }
        }
        writeIndex = w
        lastIngestNs = now
        lock.unlock()
    }

    private func refreshActiveInputName() {
        lock.lock()
        let preferred = preferredInputUID
        lock.unlock()

        let name: String
        if let preferred,
           let id = CoreAudioInputCatalog.deviceID(forUID: preferred),
           let preferredName = CoreAudioInputCatalog.deviceName(id) {
            name = preferredName
        } else {
            name = CoreAudioInputCatalog.defaultInputName() ?? "Unknown"
        }

        DispatchQueue.main.async {
            self.activeInputName = name
        }
    }
}

enum CoreAudioInputCatalog {
    static func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sysObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObject, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard hasInputChannels(id) else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Input \(id)"
            return AudioInputDevice(id: uid, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputUID() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return deviceUID(id)
    }

    static func defaultInputName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return deviceName(id)
    }

    static func setCurrentInputDevice(on inputNode: AVAudioInputNode, uid: String) throws {
        guard let id = deviceID(forUID: uid) else {
            throw NSError(domain: "AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input device not found"])
        }
        guard let au = inputNode.audioUnit else {
            throw NSError(domain: "AudioInput", code: 4, userInfo: [NSLocalizedDescriptionKey: "Input node audio unit unavailable"])
        }

        var selected = id
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selected,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind input device to engine (OSStatus \(status))"]
            )
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        )
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        listInputDevices()
            .first(where: { $0.uid == uid })
            .flatMap { _ in
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size: UInt32 = 0
                let sysObject = AudioObjectID(kAudioObjectSystemObject)
                guard AudioObjectGetPropertyDataSize(sysObject, &address, 0, nil, &size) == noErr else {
                    return nil
                }

                let count = Int(size) / MemoryLayout<AudioDeviceID>.size
                var ids = [AudioDeviceID](repeating: 0, count: count)
                guard AudioObjectGetPropertyData(sysObject, &address, 0, nil, &size, &ids) == noErr else {
                    return nil
                }

                return ids.first(where: { deviceUID($0) == uid })
            }
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value as String
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value as String
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }

        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}

final class FeatureExtractor {
    private var sampleRate: Double
    private let fftSize: Int
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]

    private var prevEnergy: Float = 0
    private var positiveFluxHistory: [Float] = []
    private let fluxHistoryCapacity: Int
    private var pitchHzState: Double?
    private var pitchConfState: Double = 0.0
    private var keyChromaState: [Double] = Array(repeating: 0.0, count: 12)
    private var keyEstimateState: String = "unknown"
    private var keyConfState: Double = 0.0
    private let pitchNameByClass = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    init(sampleRate: Double, fftSize: Int = 2048, tickHz: Double = 10.0) {
        self.sampleRate = max(8_000, sampleRate)
        self.fftSize = max(256, fftSize)
        self.log2n = vDSP_Length(round(log2(Double(max(256, fftSize)))))
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))
        self.window = Array(repeating: 0, count: max(256, fftSize))
        vDSP_hann_window(&self.window, vDSP_Length(self.window.count), Int32(vDSP_HANN_NORM))
        self.fluxHistoryCapacity = max(1, Int(tickHz.rounded()))
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func updateSampleRate(_ sampleRate: Double) {
        self.sampleRate = max(8_000, sampleRate)
    }

    func extract(samples: [Float]) -> Features {
        let frame = samples.isEmpty ? [Float](repeating: 0, count: 1) : samples

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        let loudness = clamp(20.0 * log10(Double(max(rms, 1e-6))), min: -80.0, max: 0.0)

        var energy: Float = 0
        vDSP_measqv(frame, 1, &energy, vDSP_Length(frame.count))
        let flux = max(0, energy - prevEnergy)
        prevEnergy = energy

        positiveFluxHistory.append(flux)
        if positiveFluxHistory.count > fluxHistoryCapacity {
            positiveFluxHistory.removeFirst(positiveFluxHistory.count - fluxHistoryCapacity)
        }

        let meanFlux = positiveFluxHistory.isEmpty ? 0.0 : positiveFluxHistory.reduce(0, +) / Float(positiveFluxHistory.count)
        let fluxThreshold = max(1e-7, meanFlux * 1.5)
        let peaks = positiveFluxHistory.reduce(0) { partial, v in
            partial + (v > fluxThreshold ? 1 : 0)
        }
        let onsetRate = clamp(Double(peaks), min: 0.0, max: 30.0)

        let spectralWindow = prepareSpectralWindow(from: frame)
        let spectral = spectralFeatures(from: spectralWindow)
        let pitchEstimate = estimatePitch(samples: spectralWindow, rms: rms)
        let smoothedPitch = smoothPitch(hz: pitchEstimate.hz, confidence: pitchEstimate.confidence)
        let smoothedKey = smoothKey(chroma: spectral.chroma)

        return Features(
            loudnessLufs: finite(loudness, fallback: -80),
            onsetRateHz: finite(onsetRate, fallback: 0),
            specCentroidHz: finite(clamp(spectral.centroidHz, min: 0, max: sampleRate / 2), fallback: 0),
            bandLow: finite(clamp(spectral.bandLow, min: 0, max: 1), fallback: 0),
            bandMid: finite(clamp(spectral.bandMid, min: 0, max: 1), fallback: 0),
            bandHigh: finite(clamp(spectral.bandHigh, min: 0, max: 1), fallback: 0),
            noisiness: finite(clamp(spectral.flatness, min: 0, max: 1), fallback: 0),
            pitchHz: smoothedPitch.hz,
            pitchConf: finite(clamp(smoothedPitch.confidence, min: 0, max: 1), fallback: 0),
            keyEstimate: smoothedKey.name,
            keyConf: finite(clamp(smoothedKey.confidence, min: 0, max: 1), fallback: 0)
        )
    }

    private func prepareSpectralWindow(from frame: [Float]) -> [Float] {
        if frame.count == fftSize {
            return frame
        }

        if frame.count > fftSize {
            return Array(frame.suffix(fftSize))
        }

        var padded = [Float](repeating: 0, count: fftSize)
        padded.replaceSubrange((fftSize - frame.count)..<fftSize, with: frame)
        return padded
    }

    private func spectralFeatures(from samples: [Float]) -> (centroidHz: Double, bandLow: Double, bandMid: Double, bandHigh: Double, flatness: Double, chroma: [Double]) {
        guard let fftSetup else {
            return (0, 0, 0, 0, 0, Array(repeating: 0.0, count: 12))
        }

        var x = samples
        vDSP_vmul(x, 1, window, 1, &x, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var complex = [DSPComplex](repeating: DSPComplex(), count: half)

        for i in 0..<half {
            complex[i] = DSPComplex(real: x[2 * i], imag: x[2 * i + 1])
        }

        complex.withUnsafeBufferPointer { interPtr in
            realp.withUnsafeMutableBufferPointer { rPtr in
                imagp.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    interPtr.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: half) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_ztoc(&split, 1, &complex, 2, vDSP_Length(half))
                }
            }
        }

        var mags = [Double](repeating: 0, count: half)
        for i in 1..<half {
            let re = Double(complex[i].real)
            let im = Double(complex[i].imag)
            mags[i] = sqrt(max(1e-12, (re * re) + (im * im)))
        }

        let binHz = sampleRate / Double(fftSize)
        let nyquist = sampleRate / 2.0

        var sumMag = 0.0
        var sumFreqMag = 0.0
        var eLow = 0.0
        var eMid = 0.0
        var eHigh = 0.0

        var logSum = 0.0
        var arithSum = 0.0
        var flatCount = 0.0
        var chroma = [Double](repeating: 0, count: 12)

        for k in 1..<half {
            let f = Double(k) * binHz
            let m = mags[k]
            sumMag += m
            sumFreqMag += f * m

            if f <= 200 {
                eLow += m
            } else if f <= 2_000 {
                eMid += m
            } else if f <= nyquist {
                eHigh += m
            }

            if f >= 50, f <= nyquist {
                let safe = max(m, 1e-12)
                logSum += log(safe)
                arithSum += safe
                flatCount += 1

                let midi = 69.0 + (12.0 * log2(f / 440.0))
                let pc = ((Int(lround(midi)) % 12) + 12) % 12
                chroma[pc] += safe
            }
        }

        let centroid = sumMag > 0 ? (sumFreqMag / sumMag) : 0
        let total = eLow + eMid + eHigh
        let low = total > 0 ? (eLow / total) : 0
        let mid = total > 0 ? (eMid / total) : 0
        let high = total > 0 ? (eHigh / total) : 0

        let flatness: Double
        if flatCount > 0, arithSum > 0 {
            let geo = exp(logSum / flatCount)
            let ar = arithSum / flatCount
            flatness = geo / ar
        } else {
            flatness = 0
        }

        return (centroid, low, mid, high, flatness, chroma)
    }

    private func estimatePitch(samples: [Float], rms: Float) -> (hz: Double?, confidence: Double) {
        guard samples.count >= 32 else { return (nil, 0.0) }
        guard rms > 1e-4 else { return (nil, 0.0) }

        let minHz = 70.0
        let maxHz = 800.0
        let minInterval = Int(sampleRate / maxHz)
        let maxInterval = Int(sampleRate / minHz)

        var intervals: [Int] = []
        intervals.reserveCapacity(16)
        var prev = samples[0]
        var lastCross: Int?
        for i in 1..<samples.count {
            let s = samples[i]
            if prev <= 0, s > 0 {
                if let last = lastCross {
                    let interval = i - last
                    if interval >= minInterval, interval <= maxInterval {
                        intervals.append(interval)
                    }
                }
                lastCross = i
            }
            prev = s
        }

        guard intervals.count >= 3 else {
            return (nil, 0.0)
        }

        let mean = Double(intervals.reduce(0, +)) / Double(intervals.count)
        let variance = intervals.reduce(0.0) { partial, value in
            let d = Double(value) - mean
            return partial + (d * d)
        } / Double(intervals.count)
        let std = sqrt(max(0, variance))
        let hz = sampleRate / mean
        let confidence = clamp((1.0 - (std / max(1.0, mean))) * Double(min(1.0, rms * 12.0)), min: 0.0, max: 1.0)

        if !hz.isFinite || hz < minHz || hz > maxHz {
            return (nil, 0.0)
        }
        return (hz, confidence)
    }

    private func smoothPitch(hz: Double?, confidence: Double) -> (hz: Double?, confidence: Double) {
        if let hz, confidence > 0.05 {
            if let existing = pitchHzState {
                pitchHzState = existing + (0.24 * (hz - existing))
            } else {
                pitchHzState = hz
            }
            pitchConfState += 0.32 * (confidence - pitchConfState)
        } else {
            pitchConfState *= 0.86
        }

        if pitchConfState < 0.18 {
            return (nil, pitchConfState)
        }
        return (pitchHzState, pitchConfState)
    }

    private func smoothKey(chroma: [Double]) -> (name: String?, confidence: Double) {
        let total = chroma.reduce(0, +)
        if total > 1e-8 {
            let norm = 1.0 / total
            for i in 0..<12 {
                let target = chroma[i] * norm
                keyChromaState[i] += 0.15 * (target - keyChromaState[i])
            }
        } else {
            for i in 0..<12 {
                keyChromaState[i] *= 0.92
            }
        }

        let ordered = keyChromaState.enumerated().sorted { $0.element > $1.element }
        guard let best = ordered.first else {
            keyEstimateState = "unknown"
            keyConfState = 0
            return ("unknown", 0)
        }
        let second = ordered.dropFirst().first?.element ?? 0.0
        let confidence = clamp((best.element - second) / max(1e-6, best.element + second), min: 0.0, max: 1.0)
        keyConfState += 0.20 * (confidence - keyConfState)

        if keyConfState > 0.16 {
            keyEstimateState = pitchNameByClass[best.offset]
        } else if keyConfState < 0.08 {
            keyEstimateState = "unknown"
        }
        return (keyEstimateState, keyConfState)
    }

    private func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        if !value.isFinite { return lo }
        return Swift.max(lo, Swift.min(hi, value))
    }
}

private extension Features {
    static let silence = Features(
        loudnessLufs: -80,
        onsetRateHz: 0,
        specCentroidHz: 0,
        bandLow: 0,
        bandMid: 0,
        bandHigh: 0,
        noisiness: 0,
        pitchHz: nil,
        pitchConf: 0,
        keyEstimate: "unknown",
        keyConf: 0
    )
}

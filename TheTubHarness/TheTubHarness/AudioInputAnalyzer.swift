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
    let inputChannels: Int
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
    let outputChannels: Int
    let isDefault: Bool
}

enum OutputRouteMode: String, Codable, CaseIterable {
    case gallery6Locked = "gallery6_locked"
    case stereoFallback = "stereo_fallback"
}

struct OutputChannelCalibration: Codable, Equatable {
    var hardwareOutput: Int
    var gainDb: Double
    var delayMs: Double
    var polarityInverted: Bool
    var muted: Bool
    var solo: Bool

    static func makeDefault(index: Int) -> OutputChannelCalibration {
        OutputChannelCalibration(
            hardwareOutput: max(1, index + 1),
            gainDb: 0,
            delayMs: 0,
            polarityInverted: false,
            muted: false,
            solo: false
        )
    }
}

struct OutputRoutingProfile: Codable, Equatable {
    static let virtualChannelCount = 6
    static let minGainDb: Double = -24
    static let maxGainDb: Double = 12
    static let minDelayMs: Double = 0
    static let maxDelayMs: Double = 250
    static let minMasterGainDb: Double = -24
    static let maxMasterGainDb: Double = 6
    static let minTestLevelDb: Double = -30
    static let maxTestLevelDb: Double = -3

    var deviceUID: String
    var preferredMode: OutputRouteMode
    var channels: [OutputChannelCalibration]
    var masterGainDb: Double
    var testLevelDb: Double

    static func defaultProfile(for deviceUID: String, hardwareChannels: Int) -> OutputRoutingProfile {
        let hwCount = max(1, hardwareChannels)
        var chans: [OutputChannelCalibration] = []
        chans.reserveCapacity(virtualChannelCount)
        for idx in 0..<virtualChannelCount {
            var ch = OutputChannelCalibration.makeDefault(index: idx)
            ch.hardwareOutput = max(1, min(idx + 1, hwCount))
            chans.append(ch)
        }
        return OutputRoutingProfile(
            deviceUID: deviceUID,
            preferredMode: .gallery6Locked,
            channels: chans,
            masterGainDb: 0,
            testLevelDb: -18
        )
    }

    mutating func sanitize(for hardwareChannels: Int) {
        let hwCount = max(1, hardwareChannels)
        if channels.count < Self.virtualChannelCount {
            for idx in channels.count..<Self.virtualChannelCount {
                channels.append(OutputChannelCalibration.makeDefault(index: idx))
            }
        } else if channels.count > Self.virtualChannelCount {
            channels = Array(channels.prefix(Self.virtualChannelCount))
        }

        for idx in channels.indices {
            channels[idx].hardwareOutput = max(1, min(channels[idx].hardwareOutput, hwCount))
            channels[idx].gainDb = max(Self.minGainDb, min(Self.maxGainDb, channels[idx].gainDb))
            channels[idx].delayMs = max(Self.minDelayMs, min(Self.maxDelayMs, channels[idx].delayMs))
        }

        masterGainDb = max(Self.minMasterGainDb, min(Self.maxMasterGainDb, masterGainDb))
        testLevelDb = max(Self.minTestLevelDb, min(Self.maxTestLevelDb, testLevelDb))
    }

    func mappingSummary() -> String {
        channels.enumerated().map { idx, ch in
            "\(idx + 1)->\(ch.hardwareOutput)"
        }.joined(separator: ",")
    }
}

struct OutputRoutingStore: Codable, Equatable {
    var selectedOutputUID: String?
    var profilesByUID: [String: OutputRoutingProfile]
}

struct InputRoutingProfile: Codable, Equatable {
    static let primaryChannelIndex = 0
    static let minChannelGainDb: Double = -24
    static let maxChannelGainDb: Double = 24

    var deviceUID: String
    var activeChannels: [Bool]
    var channelGainDb: [Double]

    init(deviceUID: String, activeChannels: [Bool], channelGainDb: [Double] = []) {
        self.deviceUID = deviceUID
        self.activeChannels = activeChannels
        self.channelGainDb = channelGainDb
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID
        case activeChannels
        case channelGainDb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try container.decode(String.self, forKey: .deviceUID)
        activeChannels = try container.decode([Bool].self, forKey: .activeChannels)
        channelGainDb = try container.decodeIfPresent([Double].self, forKey: .channelGainDb) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(activeChannels, forKey: .activeChannels)
        try container.encode(channelGainDb, forKey: .channelGainDb)
    }

    static func defaultProfile(for deviceUID: String, inputChannels: Int) -> InputRoutingProfile {
        let count = max(0, inputChannels)
        var active = Array(repeating: false, count: count)
        if !active.isEmpty {
            active[primaryChannelIndex] = true
        }
        return InputRoutingProfile(
            deviceUID: deviceUID,
            activeChannels: active,
            channelGainDb: Array(repeating: 0, count: count)
        )
    }

    mutating func sanitize(for inputChannels: Int) -> String? {
        let channelCount = max(0, inputChannels)
        var warning: String?
        if activeChannels.count > channelCount {
            warning = "input_channel_shortfall_\(channelCount)"
            activeChannels = Array(activeChannels.prefix(channelCount))
        } else if activeChannels.count < channelCount {
            activeChannels.append(contentsOf: Array(repeating: false, count: channelCount - activeChannels.count))
        }
        if channelGainDb.count > channelCount {
            channelGainDb = Array(channelGainDb.prefix(channelCount))
        } else if channelGainDb.count < channelCount {
            channelGainDb.append(contentsOf: Array(repeating: 0, count: channelCount - channelGainDb.count))
        }

        if channelCount > 0 {
            if activeChannels[Self.primaryChannelIndex] == false {
                warning = warning ?? "input_primary_restored"
            }
            activeChannels[Self.primaryChannelIndex] = true
        }
        for idx in channelGainDb.indices {
            channelGainDb[idx] = max(Self.minChannelGainDb, min(Self.maxChannelGainDb, channelGainDb[idx]))
        }

        if channelCount > 0 && !activeChannels.contains(true) {
            warning = warning ?? "input_no_active_channels"
        }
        return warning
    }

    var activeCount: Int {
        activeChannels.filter { $0 }.count
    }

    func activeSummary() -> String {
        let channels = activeChannels.enumerated().compactMap { idx, active in
            active ? String(idx + 1) : nil
        }
        return channels.isEmpty ? "none" : channels.joined(separator: ",")
    }
}

struct InputRoutingStore: Codable, Equatable {
    var selectedInputUID: String?
    var profilesByUID: [String: InputRoutingProfile]
}

struct InputRouteInfo: Equatable {
    var inputUID: String
    var inputName: String
    var inputChannels: Int
    var activeCount: Int
    var activeSummary: String
    var warning: String?
}

enum InputChannelRouter {
    static func sanitizedMask(_ mask: [Bool], channelCount: Int) -> [Bool] {
        let count = max(0, channelCount)
        var out = Array(repeating: false, count: count)
        for idx in 0..<count where idx < mask.count {
            out[idx] = mask[idx]
        }
        if count > InputRoutingProfile.primaryChannelIndex {
            out[InputRoutingProfile.primaryChannelIndex] = true
        }
        return out
    }

    static func sanitizedChannelGains(_ channelGainDb: [Double], channelCount: Int) -> [Float] {
        let count = max(0, channelCount)
        var out = Array(repeating: Float(1.0), count: count)
        for idx in 0..<count where idx < channelGainDb.count {
            let clamped = max(InputRoutingProfile.minChannelGainDb, min(InputRoutingProfile.maxChannelGainDb, channelGainDb[idx]))
            out[idx] = powf(10.0, Float(clamped) / 20.0)
        }
        return out
    }

    static func mixedSample(channelCount: Int, activeMask: [Bool], channelGainDb: [Double] = [], sampleAt: (Int) -> Float) -> Float {
        guard channelCount > 0 else { return 0 }
        let mask = sanitizedMask(activeMask, channelCount: channelCount)
        let gains = sanitizedChannelGains(channelGainDb, channelCount: channelCount)
        var mixed: Float = 0
        var activeCount = 0
        for ch in 0..<channelCount where mask[ch] {
            mixed += sampleAt(ch) * gains[ch]
            activeCount += 1
        }
        guard activeCount > 0 else { return 0 }
        return mixed / Float(activeCount)
    }

    static func mixChannels(_ channels: [[Float]], activeMask: [Bool], channelGainDb: [Double] = []) -> [Float] {
        let channelCount = channels.count
        guard channelCount > 0 else { return [] }
        let frameCount = channels.first?.count ?? 0
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            out[i] = mixedSample(channelCount: channelCount, activeMask: activeMask, channelGainDb: channelGainDb) { ch in
                channels[ch][i]
            }
        }
        return out
    }
}

enum InputRoutingPersistence {
    static func loadState(appName: String = "TheTubHarness", fileURL: URL? = nil) -> InputRoutingStore {
        let url: URL?
        if let fileURL {
            url = fileURL
        } else {
            url = try? SessionPaths.appSupportBaseDirectory(appName: appName)
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("input_routing.json")
        }
        guard let url else {
            return InputRoutingStore(selectedInputUID: nil, profilesByUID: [:])
        }
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(InputRoutingStore.self, from: data) else {
            return InputRoutingStore(selectedInputUID: nil, profilesByUID: [:])
        }
        return store
    }

    static func saveState(_ state: InputRoutingStore, appName: String = "TheTubHarness", fileURL: URL? = nil) {
        let url: URL?
        if let fileURL {
            url = fileURL
        } else {
            url = try? SessionPaths.appSupportBaseDirectory(appName: appName)
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("input_routing.json")
        }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            if #available(macOS 13.0, *) {
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                enc.outputFormatting = [.prettyPrinted]
            }
            let data = try enc.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort persistence only.
        }
    }
}

struct OutputRouteDecision: Equatable {
    let mode: OutputRouteMode
    let locked: Bool
    let warning: String?
}

enum OutputRoutePlanner {
    static func decide(
        preferredMode: OutputRouteMode,
        hardwareChannels: Int,
        bindSucceeded: Bool
    ) -> OutputRouteDecision {
        if preferredMode == .stereoFallback {
            return OutputRouteDecision(mode: .stereoFallback, locked: false, warning: nil)
        }
        guard bindSucceeded else {
            return OutputRouteDecision(mode: .stereoFallback, locked: false, warning: "output_bind_failed")
        }
        if hardwareChannels < OutputRoutingProfile.virtualChannelCount {
            return OutputRouteDecision(
                mode: .stereoFallback,
                locked: false,
                warning: "output_channel_shortfall_\(hardwareChannels)"
            )
        }
        return OutputRouteDecision(mode: .gallery6Locked, locked: true, warning: nil)
    }
}

enum OutputRoutingPersistence {
    static func loadState(appName: String = "TheTubHarness", fileURL: URL? = nil) -> OutputRoutingStore {
        let url: URL?
        if let fileURL {
            url = fileURL
        } else {
            url = try? SessionPaths.appSupportBaseDirectory(appName: appName)
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("output_routing.json")
        }
        guard let url else {
            return OutputRoutingStore(selectedOutputUID: nil, profilesByUID: [:])
        }
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(OutputRoutingStore.self, from: data) else {
            return OutputRoutingStore(selectedOutputUID: nil, profilesByUID: [:])
        }
        return store
    }

    static func saveState(_ state: OutputRoutingStore, appName: String = "TheTubHarness", fileURL: URL? = nil) {
        let url: URL?
        if let fileURL {
            url = fileURL
        } else {
            url = try? SessionPaths.appSupportBaseDirectory(appName: appName)
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("output_routing.json")
        }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            if #available(macOS 13.0, *) {
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                enc.outputFormatting = [.prettyPrinted]
            }
            let data = try enc.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort persistence only.
        }
    }
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
    private var inputProfilesByUID: [String: InputRoutingProfile] = [:]
    private var inputRouteState = InputRouteInfo(
        inputUID: "",
        inputName: "System Default",
        inputChannels: 0,
        activeCount: 0,
        activeSummary: "none",
        warning: "input_route_uninitialized"
    )

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
    @Published private(set) var inputRouteProfile: InputRoutingProfile = InputRoutingProfile.defaultProfile(for: "default", inputChannels: 1)
    @Published private(set) var inputRouteWarning: String?
    @Published private(set) var inputChannelLevels: [Float] = []
    var onLiveInputBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)? {
        didSet {
            audioIn.onInputBuffer = onLiveInputBuffer
        }
    }

    init() {
        let store = InputRoutingPersistence.loadState()
        inputProfilesByUID = store.profilesByUID
        audioIn.setSelectedInputUID(store.selectedInputUID)

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

    func startExternalFeed() {
        guard timer == nil else { return }

        refreshInputDevices()
        audioIn.startExternalFeed()

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
        DispatchQueue.main.async {
            self.inputChannelLevels = Array(repeating: 0, count: self.inputRouteProfile.activeChannels.count)
        }
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

    func currentCaptureInfo() -> (sampleRate: Double, channels: Int, format: String) {
        let channels = max(0, inputRouteState.inputChannels)
        return (sampleRate: audioIn.sampleRate, channels: channels, format: "caf")
    }

    func ingestExternalBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        audioIn.ingestExternalBuffer(buffer, time: time)
    }

    func refreshInputDevices() {
        let devices = CoreAudioInputCatalog.listInputDevices()
        let selected = audioIn.selectedInputUID() ?? CoreAudioInputCatalog.defaultInputUID() ?? devices.first?.uid ?? ""
        let route = resolveInputRoute(uid: selected, devices: devices)

        DispatchQueue.main.async {
            self.inputDevices = devices
            self.selectedInputUID = selected
            if let d = devices.first(where: { $0.uid == selected }) {
                self.activeInputName = d.name
            } else if devices.isEmpty {
                self.activeInputName = "No Input Device"
            }
            self.inputRouteProfile = route.profile
            self.inputRouteWarning = route.warning
            self.inputRouteState = route.info
        }
        audioIn.setInputRouteProfile(route.profile)
        persistInputRoutingStore(selectedUID: selected)
    }

    func selectInputDevice(uid: String) {
        guard !uid.isEmpty else { return }

        do {
            try audioIn.selectInputDevice(uid: uid)
            let devices = CoreAudioInputCatalog.listInputDevices()
            let route = resolveInputRoute(uid: uid, devices: devices)
            audioIn.setInputRouteProfile(route.profile)
            DispatchQueue.main.async {
                self.inputDevices = devices
                self.selectedInputUID = uid
                self.inputRouteProfile = route.profile
                self.inputRouteWarning = route.warning
                self.inputRouteState = route.info
            }
            persistInputRoutingStore(selectedUID: uid)
        } catch {
            DispatchQueue.main.async {
                self.fallbackReason = "audio_input_select_failed:\(error.localizedDescription)"
            }
        }
    }


    func setInputChannelActive(channelIndex index: Int, active: Bool) {
        let uid = selectedInputUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        guard index >= 0, index < device.inputChannels else { return }

        var profile = profileForInputUID(uid, inputChannels: device.inputChannels)
        if index == InputRoutingProfile.primaryChannelIndex {
            profile.activeChannels[index] = true
        } else {
            profile.activeChannels[index] = active
        }
        let warning = profile.sanitize(for: device.inputChannels)
        inputProfilesByUID[uid] = profile
        audioIn.setInputRouteProfile(profile)
        let info = InputRouteInfo(
            inputUID: uid,
            inputName: device.name,
            inputChannels: device.inputChannels,
            activeCount: profile.activeCount,
            activeSummary: profile.activeSummary(),
            warning: warning
        )
        DispatchQueue.main.async {
            self.inputRouteProfile = profile
            self.inputRouteWarning = warning
            self.inputRouteState = info
        }
        persistInputRoutingStore(selectedUID: uid)
    }

    func updateInputChannelGain(channelIndex index: Int, gainDb: Double) {
        let uid = selectedInputUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        guard index >= 0, index < device.inputChannels else { return }

        var profile = profileForInputUID(uid, inputChannels: device.inputChannels)
        if index >= profile.channelGainDb.count {
            profile.channelGainDb.append(contentsOf: Array(repeating: 0, count: index - profile.channelGainDb.count + 1))
        }
        profile.channelGainDb[index] = gainDb
        let warning = profile.sanitize(for: device.inputChannels)
        inputProfilesByUID[uid] = profile
        audioIn.setInputRouteProfile(profile)
        let info = InputRouteInfo(
            inputUID: uid,
            inputName: device.name,
            inputChannels: device.inputChannels,
            activeCount: profile.activeCount,
            activeSummary: profile.activeSummary(),
            warning: warning
        )
        DispatchQueue.main.async {
            self.inputRouteProfile = profile
            self.inputRouteWarning = warning
            self.inputRouteState = info
        }
        persistInputRoutingStore(selectedUID: uid)
    }

    func resetInputRouteProfileToDefault() {
        let uid = selectedInputUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        let channels = inputDevices.first(where: { $0.uid == uid })?.inputChannels ?? 0
        var profile = InputRoutingProfile.defaultProfile(for: uid, inputChannels: channels)
        let warning = profile.sanitize(for: channels)
        inputProfilesByUID[uid] = profile
        audioIn.setInputRouteProfile(profile)
        let name = inputDevices.first(where: { $0.uid == uid })?.name ?? activeInputName
        let info = InputRouteInfo(
            inputUID: uid,
            inputName: name,
            inputChannels: channels,
            activeCount: profile.activeCount,
            activeSummary: profile.activeSummary(),
            warning: warning
        )
        DispatchQueue.main.async {
            self.inputRouteProfile = profile
            self.inputRouteWarning = warning
            self.inputRouteState = info
        }
        persistInputRoutingStore(selectedUID: uid)
    }

    func currentInputRouteInfo() -> InputRouteInfo {
        inputRouteState
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
        let meters = audioIn.snapshotChannelLevels(channelCountHint: inputRouteState.inputChannels)

        publish(
            FeaturePacketSnapshot(
                features: features,
                source: "audio_in",
                fallbackReason: nil
            )
        )
        DispatchQueue.main.async { [weak self] in
            self?.inputChannelLevels = meters
        }
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

    private func profileForInputUID(_ uid: String, inputChannels: Int) -> InputRoutingProfile {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedUID.isEmpty ? "default" : normalizedUID
        var profile = inputProfilesByUID[key] ?? InputRoutingProfile.defaultProfile(for: key, inputChannels: inputChannels)
        profile.deviceUID = key
        _ = profile.sanitize(for: inputChannels)
        inputProfilesByUID[key] = profile
        return profile
    }

    private func resolveInputRoute(uid: String, devices: [AudioInputDevice]) -> (profile: InputRoutingProfile, warning: String?, info: InputRouteInfo) {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = devices.first(where: { $0.uid == normalizedUID })
        let deviceName = device?.name ?? (devices.isEmpty ? "No Input Device" : "System Default")
        let channels = max(0, device?.inputChannels ?? 0)
        var profile = profileForInputUID(normalizedUID, inputChannels: channels)
        let warning = profile.sanitize(for: channels)
        inputProfilesByUID[profile.deviceUID] = profile
        let info = InputRouteInfo(
            inputUID: normalizedUID,
            inputName: deviceName,
            inputChannels: channels,
            activeCount: profile.activeCount,
            activeSummary: profile.activeSummary(),
            warning: warning
        )
        return (profile, warning, info)
    }

    private func persistInputRoutingStore(selectedUID: String) {
        let normalized = selectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        InputRoutingPersistence.saveState(
            InputRoutingStore(
                selectedInputUID: normalized.isEmpty ? nil : normalized,
                profilesByUID: inputProfilesByUID
            )
        )
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
    private var usesExternalFeed: Bool = false
    private var activeChannelMask: [Bool] = [true]
    private var activeChannelGainDb: [Double] = [0]
    private var channelLevelsStorage: [Float] = []
    var onInputBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?

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
        lock.lock()
        usesExternalFeed = false
        lock.unlock()
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

    func setSelectedInputUID(_ uid: String?) {
        let normalized = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        preferredInputUID = normalized.isEmpty ? nil : normalized
        lock.unlock()
        refreshActiveInputName()
    }

    func selectInputDevice(uid: String) throws {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "AudioInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "Input UID is empty"])
        }

        lock.lock()
        preferredInputUID = uid
        lock.unlock()

        refreshActiveInputName()

        let shouldRestartEngine = lock.withLock {
            !usesExternalFeed && (status == .running || status == .starting)
        }
        if shouldRestartEngine {
            startEngine()
        }
    }

    func setInputRouteProfile(_ profile: InputRoutingProfile) {
        lock.lock()
        activeChannelMask = profile.activeChannels
        activeChannelGainDb = profile.channelGainDb
        lock.unlock()
    }

    func stop() {
        lock.lock()
        usesExternalFeed = false
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async {
            self.status = .stopped
        }
    }

    func startExternalFeed() {
        lock.lock()
        usesExternalFeed = true
        lastIngestNs = 0
        lock.unlock()
        refreshActiveInputName()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async {
            self.status = .running
        }
    }

    func ingestExternalBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        lock.lock()
        let allowed = usesExternalFeed
        lock.unlock()
        guard allowed else { return }
        ingest(buffer, time: time)
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

    func snapshotChannelLevels(channelCountHint: Int? = nil) -> [Float] {
        lock.lock()
        let levels = channelLevelsStorage
        lock.unlock()
        if let channelCountHint, channelCountHint > 0 {
            if levels.count == channelCountHint { return levels }
            if levels.count > channelCountHint { return Array(levels.prefix(channelCountHint)) }
            return levels + Array(repeating: 0, count: channelCountHint - levels.count)
        }
        return levels
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
        channelLevelsStorage = Array(repeating: 0, count: channels)
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.ingest(buffer, time: time)
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

    private func ingest(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        guard let channels = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        var absSums = [Float](repeating: 0, count: channelCount)
        lock.lock()
        let configuredMask = activeChannelMask
        let configuredGains = activeChannelGainDb
        lock.unlock()
        let effectiveMask = InputChannelRouter.sanitizedMask(configuredMask, channelCount: channelCount)

        for i in 0..<frameCount {
            for ch in 0..<channelCount {
                let sample = channels[ch][i]
                absSums[ch] += abs(sample)
            }
            mono[i] = InputChannelRouter.mixedSample(
                channelCount: channelCount,
                activeMask: effectiveMask,
                channelGainDb: configuredGains
            ) { ch in
                channels[ch][i]
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let cap = ring.count
        var w = writeIndex
        sampleRateStorage = max(8_000, buffer.format.sampleRate)
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
        if channelLevelsStorage.count != channelCount {
            channelLevelsStorage = Array(repeating: 0, count: channelCount)
        }
        for ch in 0..<channelCount {
            let avgAbs = absSums[ch] / Float(frameCount)
            let previous = channelLevelsStorage[ch]
            channelLevelsStorage[ch] = max(avgAbs, previous * 0.90)
        }
        lock.unlock()
        onInputBuffer?(buffer, time)
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
    private static func copyCFStringProperty(
        id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

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
            let inputChannels = inputChannelCount(id)
            guard inputChannels > 0 else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Input \(id)"
            return AudioInputDevice(id: uid, uid: uid, name: name, inputChannels: inputChannels)
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

    static func deviceName(forUID uid: String) -> String? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return deviceName(id)
    }

    static func inputChannels(forUID uid: String) -> Int? {
        guard let id = deviceID(forUID: uid) else { return nil }
        let count = inputChannelCount(id)
        return count > 0 ? count : nil
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
        copyCFStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        copyCFStringProperty(id: id, selector: kAudioObjectPropertyName)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }

        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

enum CoreAudioOutputCatalog {
    private static func copyCFStringProperty(
        id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func listOutputDevices() -> [AudioOutputDevice] {
        let defaultID = defaultOutputDeviceID()
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
            let outputChannels = outputChannelCount(id)
            guard outputChannels > 0 else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Output \(id)"
            return AudioOutputDevice(
                id: uid,
                uid: uid,
                name: name,
                outputChannels: outputChannels,
                isDefault: id == defaultID
            )
        }
        .sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func defaultOutputUID() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return deviceUID(id)
    }

    static func defaultOutputName() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return deviceName(id)
    }

    static func defaultOutputChannelCount() -> Int {
        guard let id = defaultOutputDeviceID() else { return 0 }
        return outputChannelCount(id)
    }

    static func setCurrentOutputDevice(on outputNode: AVAudioOutputNode, uid: String) throws {
        guard let id = deviceID(forUID: uid) else {
            throw NSError(domain: "AudioOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output device not found"])
        }
        guard let au = outputNode.audioUnit else {
            throw NSError(domain: "AudioOutput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output node audio unit unavailable"])
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
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind output device to engine (OSStatus \(status))"]
            )
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        listOutputDevices()
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

    static func deviceName(forUID uid: String) -> String? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return deviceName(id)
    }

    static func outputChannels(forUID uid: String) -> Int? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return outputChannelCount(id)
    }

    static func nominalSampleRate(forUID uid: String) -> Double? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return nominalSampleRate(id)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr, rate.isFinite, rate >= 8_000, rate <= 384_000 else { return nil }
        return rate
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        copyCFStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        copyCFStringProperty(id: id, selector: kAudioObjectPropertyName)
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

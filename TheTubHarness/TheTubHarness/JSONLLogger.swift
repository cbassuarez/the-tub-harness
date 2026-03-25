//
//  JSONLLogger.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import Foundation
import Darwin
import CryptoKit

@inline(__always)
private func currentEpochMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

enum HumanLabel: String, Codable, CaseIterable {
    case good
    case tooMuch = "too_much"
    case tooFlat = "too_flat"
}

struct RunBundleMetadata: Codable, Equatable {
    let bundleId: String
    let createdAt: String
    let policyVersion: String
    let bankManifestVersion: String
    let contractVersion: String
    let harnessRepoSha: String?
    let modelRepoSha: String?
}

struct LabelChangeEvent: Codable, Equatable {
    let tsMs: Int
    let event: String
    let from: HumanLabel?
    let to: HumanLabel?
    let bundleId: String
    let sessionId: String

    init(tsMs: Int, from: HumanLabel?, to: HumanLabel?, bundleId: String, sessionId: String) {
        self.tsMs = tsMs
        self.event = "label_change"
        self.from = from
        self.to = to
        self.bundleId = bundleId
        self.sessionId = sessionId
    }
}

struct BundleHeaderEvent: Codable, Equatable {
    let tsMs: Int
    let event: String
    let bundleId: String
    let sessionId: String
    let bundle: RunBundleMetadata

    init(tsMs: Int, bundle: RunBundleMetadata, sessionId: String) {
        self.tsMs = tsMs
        self.event = "bundle_header"
        self.bundleId = bundle.bundleId
        self.sessionId = sessionId
        self.bundle = bundle
    }
}

struct FrameInterventions: Codable, Equatable {
    let limiterHit: Bool
    let densityCap: Bool
    let voiceCap: Bool
    let cpuGuard: Bool
    let resetVoices: Bool
    let timeout: Bool
    let decodeError: Bool
    let contractViolation: Bool
    let pickFallback: Bool
    let featureFallback: Bool
    let extras: [String]

    static func from(_ interventions: [String]) -> FrameInterventions {
        FrameInterventions(
            limiterHit: interventions.contains(where: { $0 == "limiter_hit" }),
            densityCap: interventions.contains(where: { $0.contains("density_cap") || $0.contains("param_clamped_high:density") }),
            voiceCap: interventions.contains(where: { $0.contains("voice_cap") }),
            cpuGuard: interventions.contains(where: { $0 == "cpu_guard" }),
            resetVoices: interventions.contains(where: { $0 == "reset_voices" }),
            timeout: interventions.contains(where: { $0 == "timeout" }),
            decodeError: interventions.contains(where: { $0.hasPrefix("decode_error") }),
            contractViolation: interventions.contains(where: { $0.hasPrefix("contract_violation:") }),
            pickFallback: interventions.contains(where: { $0.hasPrefix("pick_resolution:") }),
            featureFallback: interventions.contains(where: { $0.hasPrefix("feature_fallback:") }),
            extras: interventions
        )
    }
}

enum FrameInputSource: String, Codable, Equatable {
    case live
    case replayFile = "replay_file"
}

struct TrainingFrameLogLine: Codable, Equatable {
    let tsMs: Int
    let frameIndex: Int
    let sessionId: String
    let frameHz: Int
    let replayMode: Bool
    let inputSource: FrameInputSource
    let mode: Int
    let buttons: Buttons
    let features: Features
    let state: HarnessState?
    let modelIn: ModelIn
    let modelOut: ModelOut?
    let diagnostics: TraceDiagnostics
    let interventions: FrameInterventions
    let label: HumanLabel?
    let bundleId: String

    init(
        tsMs: Int,
        frameIndex: Int,
        sessionId: String,
        frameHz: Int,
        replayMode: Bool = false,
        inputSource: FrameInputSource = .live,
        mode: Int,
        buttons: Buttons,
        features: Features,
        state: HarnessState?,
        modelIn: ModelIn,
        modelOut: ModelOut?,
        diagnostics: TraceDiagnostics,
        interventions: FrameInterventions,
        label: HumanLabel?,
        bundleId: String
    ) {
        self.tsMs = tsMs
        self.frameIndex = frameIndex
        self.sessionId = sessionId
        self.frameHz = frameHz
        self.replayMode = replayMode
        self.inputSource = inputSource
        self.mode = mode
        self.buttons = buttons
        self.features = features
        self.state = state
        self.modelIn = modelIn
        self.modelOut = modelOut
        self.diagnostics = diagnostics
        self.interventions = interventions
        self.label = label
        self.bundleId = bundleId
    }

    enum CodingKeys: String, CodingKey {
        case tsMs
        case frameIndex
        case sessionId
        case frameHz
        case replayMode
        case inputSource
        case mode
        case buttons
        case features
        case state
        case modelIn
        case modelOut
        case diagnostics
        case interventions
        case label
        case bundleId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tsMs, forKey: .tsMs)
        try c.encode(frameIndex, forKey: .frameIndex)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(frameHz, forKey: .frameHz)
        try c.encode(replayMode, forKey: .replayMode)
        try c.encode(inputSource, forKey: .inputSource)
        try c.encode(mode, forKey: .mode)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encode(modelIn, forKey: .modelIn)
        if let modelOut {
            try c.encode(modelOut, forKey: .modelOut)
        } else {
            try c.encodeNil(forKey: .modelOut)
        }
        try c.encode(diagnostics, forKey: .diagnostics)
        try c.encode(interventions, forKey: .interventions)
        if let label {
            try c.encode(label, forKey: .label)
        } else {
            try c.encodeNil(forKey: .label)
        }
        try c.encode(bundleId, forKey: .bundleId)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tsMs = try c.decode(Int.self, forKey: .tsMs)
        frameIndex = try c.decode(Int.self, forKey: .frameIndex)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        frameHz = try c.decode(Int.self, forKey: .frameHz)
        replayMode = try c.decodeIfPresent(Bool.self, forKey: .replayMode) ?? false
        inputSource = try c.decodeIfPresent(FrameInputSource.self, forKey: .inputSource) ?? .live
        mode = try c.decode(Int.self, forKey: .mode)
        buttons = try c.decode(Buttons.self, forKey: .buttons)
        features = try c.decode(Features.self, forKey: .features)
        state = try c.decodeIfPresent(HarnessState.self, forKey: .state)
        modelIn = try c.decode(ModelIn.self, forKey: .modelIn)
        modelOut = try c.decodeIfPresent(ModelOut.self, forKey: .modelOut)
        diagnostics = try c.decode(TraceDiagnostics.self, forKey: .diagnostics)
        interventions = try c.decode(FrameInterventions.self, forKey: .interventions)
        label = try c.decodeIfPresent(HumanLabel.self, forKey: .label)
        bundleId = try c.decode(String.self, forKey: .bundleId)
    }
}

final class AsyncJSONLWriter {
    let url: URL

    private let queue: DispatchQueue
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private let maxPending: Int
    private var pending: Int = 0
    private var dropped: Int = 0

    init(url: URL, maxPending: Int = 2_048, queueLabel: String) throws {
        self.url = url
        self.maxPending = max(128, maxPending)
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func append<T: Encodable>(_ value: T) {
        lock.lock()
        if pending >= maxPending {
            dropped += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()

        queue.async {
            defer {
                self.lock.lock()
                self.pending -= 1
                self.lock.unlock()
            }
            do {
                let data = try self.encoder.encode(value)
                self.handle.write(data)
                self.handle.write(Data([0x0A]))
            } catch {
                // Keep logging path non-fatal.
            }
        }
    }

    func close() {
        queue.sync {}
        try? handle.close()
    }

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}

struct SessionAlignment: Codable, Equatable {
    var startTsMs: Int
    var audioStartHostTime: UInt64
    var audioStartSampleIndex: Int64
}

struct SessionMetadata: Codable, Equatable {
    var sessionId: String
    var bundleId: String
    var createdAt: String
    var sampleRate: Double
    var channels: Int
    var inputAudioFormat: String
    var inputAudioPath: String?
    var framesPath: String
    var eventsPath: String
    var frameHz: Int
    var recordInputAudioEnabled: Bool
    var replayMode: Bool
    var replayedSessionId: String?
    var replayAudioMissing: Bool
    var alignment: SessionAlignment
}

final class TrainingLogSession {
    let bundle: RunBundleMetadata
    let sessionId: String
    let sessionDirectoryURL: URL
    let frameURL: URL
    let eventURL: URL
    let metaURL: URL
    let inputAudioURL: URL?

    private let frameWriter: AsyncJSONLWriter
    private let eventWriter: AsyncJSONLWriter
    private let metadataLock = NSLock()
    private var metadata: SessionMetadata

    init(
        bundle: RunBundleMetadata,
        sessionId: String,
        recordInputAudioEnabled: Bool = false,
        inputAudioFormat: String = "caf",
        replayMode: Bool = false,
        replayedSessionId: String? = nil,
        appName: String = "TheTubHarness",
        baseDirectory: URL? = nil
    ) throws {
        self.bundle = bundle
        self.sessionId = sessionId

        let baseDir: URL
        if let baseDirectory {
            baseDir = baseDirectory
        } else {
            baseDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(appName, isDirectory: true)
        }
        let sessionsDir = baseDir.appendingPathComponent("sessions", isDirectory: true)
        self.sessionDirectoryURL = sessionsDir.appendingPathComponent(sessionId, isDirectory: true)

        let frameURL = sessionDirectoryURL.appendingPathComponent("frames_\(sessionId).jsonl")
        let eventURL = sessionDirectoryURL.appendingPathComponent("events_\(sessionId).jsonl")
        let metaURL = sessionDirectoryURL.appendingPathComponent("session_meta_\(sessionId).json")
        let normalizedFormat = TrainingLogSession.normalizedInputAudioFormat(inputAudioFormat)
        let inputAudioURL = recordInputAudioEnabled
            ? sessionDirectoryURL.appendingPathComponent("input_\(sessionId).\(normalizedFormat)")
            : nil
        self.frameURL = frameURL
        self.eventURL = eventURL
        self.metaURL = metaURL
        self.inputAudioURL = inputAudioURL

        self.metadata = SessionMetadata(
            sessionId: sessionId,
            bundleId: bundle.bundleId,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sampleRate: 0,
            channels: 0,
            inputAudioFormat: normalizedFormat,
            inputAudioPath: inputAudioURL?.path,
            framesPath: frameURL.path,
            eventsPath: eventURL.path,
            frameHz: 10,
            recordInputAudioEnabled: recordInputAudioEnabled,
            replayMode: replayMode,
            replayedSessionId: replayedSessionId,
            replayAudioMissing: false,
            alignment: SessionAlignment(startTsMs: 0, audioStartHostTime: 0, audioStartSampleIndex: 0)
        )

        self.frameWriter = try AsyncJSONLWriter(
            url: self.frameURL,
            queueLabel: "tub.training.frames.writer"
        )
        self.eventWriter = try AsyncJSONLWriter(
            url: self.eventURL,
            queueLabel: "tub.training.events.writer"
        )

        writeMetadata()
        eventWriter.append(BundleHeaderEvent(tsMs: currentEpochMs(), bundle: bundle, sessionId: sessionId))
    }

    func appendFrame(_ line: TrainingFrameLogLine) {
        metadataLock.lock()
        if metadata.alignment.startTsMs == 0 {
            metadata.alignment.startTsMs = line.tsMs
        }
        metadataLock.unlock()
        frameWriter.append(line)
    }

    func appendLabelChange(from oldLabel: HumanLabel?, to newLabel: HumanLabel?) {
        eventWriter.append(
            LabelChangeEvent(
                tsMs: currentEpochMs(),
                from: oldLabel,
                to: newLabel,
                bundleId: bundle.bundleId,
                sessionId: sessionId
            )
        )
    }

    func setAudioCaptureInfo(sampleRate: Double, channels: Int, inputAudioFormat: String, inputAudioPath: String?) {
        metadataLock.lock()
        metadata.sampleRate = sampleRate
        metadata.channels = channels
        metadata.inputAudioFormat = TrainingLogSession.normalizedInputAudioFormat(inputAudioFormat)
        metadata.inputAudioPath = inputAudioPath
        metadata.recordInputAudioEnabled = (inputAudioPath != nil)
        metadataLock.unlock()
    }

    func setReplayContext(replayMode: Bool, replayedSessionId: String?) {
        metadataLock.lock()
        metadata.replayMode = replayMode
        metadata.replayedSessionId = replayedSessionId
        metadataLock.unlock()
    }

    func setReplayAudioMissing(_ missing: Bool) {
        metadataLock.lock()
        metadata.replayAudioMissing = missing
        metadataLock.unlock()
    }

    func noteAudioAlignment(hostTime: UInt64, sampleIndex: Int64) {
        metadataLock.lock()
        if metadata.alignment.audioStartHostTime == 0 && hostTime > 0 {
            metadata.alignment.audioStartHostTime = hostTime
        }
        if metadata.alignment.audioStartSampleIndex == 0 && sampleIndex != 0 {
            metadata.alignment.audioStartSampleIndex = sampleIndex
        }
        metadataLock.unlock()
    }

    func snapshotMetadata() -> SessionMetadata {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return metadata
    }

    func close() {
        frameWriter.close()
        eventWriter.close()
        writeMetadata()
    }

    private func writeMetadata() {
        let enc = JSONEncoder.sortedSnakeCase
        let data: Data
        do {
            data = try enc.encode(snapshotMetadata())
        } catch {
            return
        }

        do {
            try FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            // Metadata write is best-effort and should not crash logging.
        }
    }

    private static func normalizedInputAudioFormat(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "wav" { return "wav" }
        return "caf"
    }

    private static func timestampForFileName(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

enum RunBundleFactory {
    static func create(
        appName: String = "TheTubHarness",
        manifestCatalog: ManifestCatalog = .shared,
        now: Date = Date(),
        overrideBundleId: String? = nil,
        policyConfigPath: String? = nil,
        baseDirectory: URL? = nil
    ) throws -> (bundle: RunBundleMetadata, fileURL: URL) {
        let policyVersion = resolvedPolicyVersion(policyConfigPath: policyConfigPath)
        let bankManifestVersion = resolvedManifestVersion(catalog: manifestCatalog)
        let harnessSha = resolvedRepoShortSha(startingAt: URL(fileURLWithPath: #filePath))
        let modelSha = ProcessInfo.processInfo.environment["TUB_ML_GIT_SHA"]
        let bundleId = overrideBundleId ?? makeBundleId(
            date: now,
            harnessSha: harnessSha,
            policyVersion: policyVersion
        )

        let createdAt = ISO8601DateFormatter().string(from: now)
        let bundle = RunBundleMetadata(
            bundleId: bundleId,
            createdAt: createdAt,
            policyVersion: policyVersion,
            bankManifestVersion: bankManifestVersion,
            contractVersion: ModeContract.contractVersion,
            harnessRepoSha: harnessSha,
            modelRepoSha: modelSha
        )

        let bundlesDir: URL
        if let baseDirectory {
            bundlesDir = baseDirectory.appendingPathComponent("bundles", isDirectory: true)
        } else {
            bundlesDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("bundles", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true)
        let outURL = bundlesDir.appendingPathComponent("\(bundleId).json")
        let payload = try JSONEncoder.sortedSnakeCase.encode(bundle)
        try payload.write(to: outURL, options: .atomic)
        return (bundle, outURL)
    }

    static func startupBanner(bundle: RunBundleMetadata) -> String {
        "running bundle \(bundle.bundleId) (policy=\(bundle.policyVersion.prefix(12)), banks=\(bundle.bankManifestVersion.prefix(12)), contract=\(bundle.contractVersion))"
    }

    private static func resolvedPolicyVersion(policyConfigPath: String?) -> String {
        if let env = ProcessInfo.processInfo.environment["TUB_POLICY_VERSION"], !env.isEmpty {
            return env
        }
        let defaultPath = "/Users/seb/the-tub-ml/configs/stub_policy_v1.yaml"
        let path = policyConfigPath
            ?? ProcessInfo.processInfo.environment["TUB_POLICY_CONFIG_PATH"]
            ?? defaultPath
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            return "unknown_policy_version"
        }
        return data.sha256Hex
    }

    private static func resolvedManifestVersion(catalog: ManifestCatalog) -> String {
        guard let dir = catalog.sourceDirectory else {
            return "unknown_manifest_version"
        }
        var merged = Data()
        for file in ["banks.json", "instruments.json", "spatial_patterns.json"] {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else {
                return "unknown_manifest_version"
            }
            merged.append(data)
        }
        return merged.sha256Hex
    }

    private static func makeBundleId(date: Date, harnessSha: String?, policyVersion: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let datePart = f.string(from: date)
        let harnessPart = harnessSha.map { String($0.prefix(7)) } ?? "nogit"
        let policyPart = String(policyVersion.prefix(8))
        return "bundle_\(datePart)_\(harnessPart)-\(policyPart)"
    }

    private static func resolvedRepoShortSha(startingAt fileURL: URL) -> String? {
        var cursor = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        while cursor.path.count > 1 {
            let gitDir = cursor.appendingPathComponent(".git", isDirectory: true)
            if fm.fileExists(atPath: gitDir.path),
               let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: ") {
                    let ref = String(trimmed.dropFirst(5))
                    let refURL = gitDir.appendingPathComponent(ref)
                    if let sha = try? String(contentsOf: refURL, encoding: .utf8) {
                        return String(sha.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
                    }
                } else {
                    return String(trimmed.prefix(7))
                }
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}

private extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var sortedSnakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if #available(macOS 13.0, *) {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.prettyPrinted]
        }
        return encoder
    }
}

struct TraceDiagnostics: Codable, Equatable {
    let requestId: Int
    let sendTsMs: Int
    let recvTsMs: Int?
    let roundTripMs: Int?
    let timedOut: Bool
    let decodeError: String?
    let interventions: [String]
}

struct TraceRecord: Codable, Equatable {
    let schemaVersion: Int
    let recordedAtMs: Int
    let modelIn: ModelIn
    let modelOut: ModelOut?
    let diagnostics: TraceDiagnostics
    let featureSource: String
    let fallbackReason: String?
    let sentPacketJson: String?
    let bundleId: String?
    let label: HumanLabel?

    init(
        schemaVersion: Int = 1,
        recordedAtMs: Int,
        modelIn: ModelIn,
        modelOut: ModelOut?,
        diagnostics: TraceDiagnostics,
        featureSource: String,
        fallbackReason: String?,
        sentPacketJson: String?,
        bundleId: String? = nil,
        label: HumanLabel? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.recordedAtMs = recordedAtMs
        self.modelIn = modelIn
        self.modelOut = modelOut
        self.diagnostics = diagnostics
        self.featureSource = featureSource
        self.fallbackReason = fallbackReason
        self.sentPacketJson = sentPacketJson
        self.bundleId = bundleId
        self.label = label
    }

    init(
        schemaVersion: Int = 1,
        recordedAtMs: Int,
        modelIn: ModelIn,
        modelOut: ModelOut?,
        diagnostics: TraceDiagnostics,
        featureSource: String,
        fallbackReason: String?,
        sentPacketJson: String?
    ) {
        self.init(
            schemaVersion: schemaVersion,
            recordedAtMs: recordedAtMs,
            modelIn: modelIn,
            modelOut: modelOut,
            diagnostics: diagnostics,
            featureSource: featureSource,
            fallbackReason: fallbackReason,
            sentPacketJson: sentPacketJson,
            bundleId: nil,
            label: nil
        )
    }
}

struct ReplayFrame {
    let modelIn: ModelIn
    let delayMs: Int
    let bundleId: String?
    let label: HumanLabel?
}

struct ReplayScheduledFrame {
    let frameIndex: Int
    let tsMs: Int
    let modelIn: ModelIn
    let bundleId: String?
    let label: HumanLabel?
}

struct ReplaySessionData {
    let metadata: SessionMetadata
    let frames: [ReplayScheduledFrame]
    let events: [String]
    let inputAudioURL: URL?
}

enum ReplaySessionLoaderError: Error {
    case missingMeta(URL)
    case invalidMeta(URL)
    case missingFrames(URL)
    case emptyFrames(URL)
}

enum SessionPaths {
    static func appSupportBaseDirectory(appName: String = "TheTubHarness") throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(appName, isDirectory: true)
    }
}

final class ReplaySessionLoader {
    static func load(
        sessionId: String,
        appName: String = "TheTubHarness",
        baseDirectory: URL? = nil
    ) throws -> ReplaySessionData {
        let baseDir = try baseDirectory ?? SessionPaths.appSupportBaseDirectory(appName: appName)
        let sessionDir = baseDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        let metaURL = sessionDir.appendingPathComponent("session_meta_\(sessionId).json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw ReplaySessionLoaderError.missingMeta(metaURL)
        }

        let metadataData = try Data(contentsOf: metaURL)
        let metadata: SessionMetadata
        do {
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            metadata = try dec.decode(SessionMetadata.self, from: metadataData)
        } catch {
            throw ReplaySessionLoaderError.invalidMeta(metaURL)
        }

        let framesURL = URL(fileURLWithPath: metadata.framesPath)
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw ReplaySessionLoaderError.missingFrames(framesURL)
        }

        let eventsURL = URL(fileURLWithPath: metadata.eventsPath)
        let eventLines: [String]
        if let text = try? String(contentsOf: eventsURL, encoding: .utf8) {
            eventLines = text
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            eventLines = []
        }

        let frameLines = try String(contentsOf: framesURL, encoding: .utf8)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !frameLines.isEmpty else {
            throw ReplaySessionLoaderError.emptyFrames(framesURL)
        }

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase

        var frames: [ReplayScheduledFrame] = []
        frames.reserveCapacity(frameLines.count)
        for (idx, raw) in frameLines.enumerated() {
            guard let data = raw.data(using: .utf8) else { continue }
            if let line = try? dec.decode(TrainingFrameLogLine.self, from: data) {
                frames.append(
                    ReplayScheduledFrame(
                        frameIndex: line.frameIndex,
                        tsMs: line.tsMs,
                        modelIn: line.modelIn,
                        bundleId: line.bundleId,
                        label: line.label
                    )
                )
            } else if let rec = try? dec.decode(TraceRecord.self, from: data) {
                frames.append(
                    ReplayScheduledFrame(
                        frameIndex: idx + 1,
                        tsMs: rec.modelIn.tsMs,
                        modelIn: rec.modelIn,
                        bundleId: rec.bundleId,
                        label: rec.label
                    )
                )
            } else if let input = try? dec.decode(ModelIn.self, from: data) {
                frames.append(
                    ReplayScheduledFrame(
                        frameIndex: idx + 1,
                        tsMs: input.tsMs,
                        modelIn: input,
                        bundleId: nil,
                        label: nil
                    )
                )
            }
        }
        frames.sort { lhs, rhs in
            if lhs.tsMs == rhs.tsMs {
                return lhs.frameIndex < rhs.frameIndex
            }
            return lhs.tsMs < rhs.tsMs
        }
        guard !frames.isEmpty else {
            throw ReplaySessionLoaderError.emptyFrames(framesURL)
        }

        let inputAudioURL = metadata.inputAudioPath.map(URL.init(fileURLWithPath:))
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return ReplaySessionData(
            metadata: metadata,
            frames: frames,
            events: eventLines,
            inputAudioURL: inputAudioURL
        )
    }
}

final class TraceRecorder {
    let url: URL
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(appName: String = "TheTubHarness", sessionId: String, directory: URL? = nil) throws {
        let fm = FileManager.default
        let baseDir: URL
        if let directory {
            baseDir = directory
        } else {
            baseDir = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
        }

        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        self.url = baseDir.appendingPathComponent("\(sessionId)_\(stamp).jsonl")

        fm.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.encoder = TraceRecorder.makeEncoder()
    }

    init(outputURL: URL) throws {
        let fm = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        self.url = outputURL
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        fm.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.encoder = TraceRecorder.makeEncoder()
    }

    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        return enc
    }

    func append(_ record: TraceRecord) {
        do {
            let data = try encoder.encode(record)
            handle.write(data)
            handle.write(Data([0x0A]))
        } catch {
            // Do not crash trace path due logging error.
        }
    }

    func close() {
        try? handle.close()
    }

    static func loadReplayFrames(from url: URL) throws -> [ReplayFrame] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase

        var frames: [ReplayFrame] = []
        var previousTs: Int?

        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }

            let modelIn: ModelIn
            var bundleId: String?
            var label: HumanLabel?
            if let rec = try? dec.decode(TraceRecord.self, from: data) {
                modelIn = rec.modelIn
                bundleId = rec.bundleId
                label = rec.label
            } else {
                if let raw = try? dec.decode(ModelIn.self, from: data) {
                    modelIn = raw
                } else {
                    if let training = try? dec.decode(TrainingFrameLogLine.self, from: data) {
                        modelIn = training.modelIn
                        bundleId = training.bundleId
                        label = training.label
                    } else {
                        let compat = try dec.decode(TraceReplayCompatLine.self, from: data)
                        if let m = compat.modelIn ?? compat.input {
                            modelIn = m
                            bundleId = compat.bundleId
                            label = compat.label
                        } else {
                            continue
                        }
                    }
                }
            }

            let delay: Int
            if let previousTs {
                delay = max(0, modelIn.tsMs - previousTs)
            } else {
                delay = 0
            }

            previousTs = modelIn.tsMs
            frames.append(ReplayFrame(modelIn: modelIn, delayMs: delay, bundleId: bundleId, label: label))
        }

        return frames
    }

    private struct TraceReplayCompatLine: Decodable {
        let modelIn: ModelIn?
        let input: ModelIn?
        let bundleId: String?
        let label: HumanLabel?
    }
}

enum TraceReplayError: Error {
    case emptyTrace
    case invalidHost(String)
    case cancelled
}

final class TraceReplayer {
    static func replay(
        inputURL: URL,
        host: String,
        port: UInt16,
        speed: Double = 1.0,
        timeoutMs: Int = 500,
        outputURL: URL? = nil,
        appName: String = "TheTubHarness"
    ) throws -> URL {
        try replay(
            inputURL: inputURL,
            host: host,
            port: port,
            speed: speed,
            timeoutMs: timeoutMs,
            bundleIdOverride: nil,
            outputURL: outputURL,
            appName: appName
        )
    }

    static func replay(
        inputURL: URL,
        host: String,
        port: UInt16,
        speed: Double = 1.0,
        timeoutMs: Int = 500,
        bundleIdOverride: String? = nil,
        outputURL: URL? = nil,
        appName: String = "TheTubHarness"
    ) throws -> URL {
        let frames = try TraceRecorder.loadReplayFrames(from: inputURL)
        guard !frames.isEmpty else { throw TraceReplayError.emptyTrace }

        let recorder: TraceRecorder
        if let outputURL {
            recorder = try TraceRecorder(outputURL: outputURL)
        } else {
            recorder = try TraceRecorder(appName: appName, sessionId: "replay")
        }
        defer { recorder.close() }

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { _ = Darwin.close(sock) }

        var timeout = timeval(tv_sec: __darwin_time_t(timeoutMs / 1000), tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian

        let parsed = host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        guard parsed == 1 else {
            throw TraceReplayError.invalidHost(host)
        }

        let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            return e
        }()

        let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return d
        }()
        let manifests = ManifestCatalog.shared
        var lastModeForPickFallback: Int?
        var pickFallbackLoggedForMode: Int?

        for (index, frame) in frames.enumerated() {
            if lastModeForPickFallback != frame.modelIn.mode {
                lastModeForPickFallback = frame.modelIn.mode
                pickFallbackLoggedForMode = nil
            }
            let replayDelay = adjustedDelayMs(frame.delayMs, speed: speed)
            if replayDelay > 0 {
                usleep(UInt32(min(replayDelay * 1000, Int(UInt32.max))))
            }

            let sendTsMs = nowMs()
            let payload = try encoder.encode(frame.modelIn)
            let sentPacketJson = String(data: payload, encoding: .utf8)
            let frameBundleId = bundleIdOverride ?? frame.bundleId

            var interventions: [String] = []
            var timedOut = false
            var recvTsMs: Int?
            var roundTripMs: Int?
            var decodeError: String?
            var modelOut: ModelOut?

            let sendResult: Int = payload.withUnsafeBytes { ptr in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.sendto(sock, ptr.baseAddress, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            if sendResult < 0 {
                timedOut = true
                decodeError = "send_error_errno_\(errno)"
                interventions.append("send_error")
            } else {
                var from = sockaddr_in()
                var fromLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
                var buf = [UInt8](repeating: 0, count: 65_535)

                let recvLen: Int = buf.withUnsafeMutableBytes { rawBuf in
                    withUnsafeMutablePointer(to: &from) { fromPtr in
                        fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.recvfrom(sock, rawBuf.baseAddress, rawBuf.count, 0, sockPtr, &fromLen)
                        }
                    }
                }

                if recvLen <= 0 {
                    timedOut = true
                    interventions.append("timeout")
                    decodeError = "recv_error_errno_\(errno)"
                } else {
                    recvTsMs = nowMs()
                    roundTripMs = recvTsMs.map { $0 - sendTsMs }

                    let data = Data(buf.prefix(recvLen))
                    do {
                        let decoded = try decoder.decode(ModelOut.self, from: data)
                        let enforced = ModeContract.enforceIncoming(modelOut: decoded, currentMode: frame.modelIn.mode)
                        let resolved = manifests.resolve(mode: enforced.0.mode, picks: enforced.0.picks)
                        modelOut = ModelOut(
                            protocolVersion: enforced.0.protocolVersion,
                            tsMs: enforced.0.tsMs,
                            mode: enforced.0.mode,
                            params: enforced.0.params,
                            picks: resolved.picks,
                            flags: enforced.0.flags
                        )
                        if !enforced.1.isEmpty {
                            interventions.append(contentsOf: enforced.1.map { "contract_violation:\($0)" })
                        }
                        if !resolved.notes.isEmpty, pickFallbackLoggedForMode != frame.modelIn.mode {
                            interventions.append(contentsOf: resolved.notes.map { "pick_resolution:\($0)" })
                            pickFallbackLoggedForMode = frame.modelIn.mode
                        }
                    } catch {
                        decodeError = error.localizedDescription
                        interventions.append("decode_error")
                        interventions.append("fallback_safe_defaults")
                        var fallback = ModeContract.protocolViolationFallback(mode: frame.modelIn.mode, tsMs: recvTsMs ?? nowMs())
                        let resolved = manifests.resolve(mode: fallback.mode, picks: fallback.picks)
                        fallback = ModelOut(
                            protocolVersion: fallback.protocolVersion,
                            tsMs: fallback.tsMs,
                            mode: fallback.mode,
                            params: fallback.params,
                            picks: resolved.picks,
                            flags: fallback.flags
                        )
                        modelOut = fallback
                        if !resolved.notes.isEmpty, pickFallbackLoggedForMode != frame.modelIn.mode {
                            interventions.append(contentsOf: resolved.notes.map { "pick_resolution:\($0)" })
                            pickFallbackLoggedForMode = frame.modelIn.mode
                        }
                    }
                }
            }

            let record = TraceRecord(
                recordedAtMs: nowMs(),
                modelIn: frame.modelIn,
                modelOut: modelOut,
                diagnostics: TraceDiagnostics(
                    requestId: index + 1,
                    sendTsMs: sendTsMs,
                    recvTsMs: recvTsMs,
                    roundTripMs: roundTripMs,
                    timedOut: timedOut,
                    decodeError: decodeError,
                    interventions: interventions
                ),
                featureSource: "replay",
                fallbackReason: nil,
                sentPacketJson: sentPacketJson,
                bundleId: frameBundleId,
                label: frame.label
            )
            recorder.append(record)
        }

        return recorder.url
    }

    static func replaySession(
        session: ReplaySessionData,
        host: String,
        port: UInt16,
        timeoutMs: Int = 500,
        outputURL: URL? = nil,
        appName: String = "TheTubHarness",
        timingProvider: (() -> Double)? = nil,
        toleranceSeconds: Double = 0.010,
        baseInterventions: [String] = [],
        shouldCancel: (() -> Bool)? = nil,
        onFrameResult: ((ReplayScheduledFrame, ModelOut?) -> Void)? = nil
    ) throws -> URL {
        guard !session.frames.isEmpty else { throw TraceReplayError.emptyTrace }

        let recorder: TraceRecorder
        if let outputURL {
            recorder = try TraceRecorder(outputURL: outputURL)
        } else {
            recorder = try TraceRecorder(appName: appName, sessionId: "replay_\(session.metadata.sessionId)")
        }
        defer { recorder.close() }

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { _ = Darwin.close(sock) }

        var timeout = timeval(tv_sec: __darwin_time_t(timeoutMs / 1000), tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian

        let parsed = host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        guard parsed == 1 else {
            throw TraceReplayError.invalidHost(host)
        }

        let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            return e
        }()

        let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return d
        }()
        let manifests = ManifestCatalog.shared
        var lastModeForPickFallback: Int?
        var pickFallbackLoggedForMode: Int?

        let startTsMs = session.metadata.alignment.startTsMs != 0
            ? session.metadata.alignment.startTsMs
            : (session.frames.first?.tsMs ?? 0)
        var previousTsMs: Int?

        for frame in session.frames {
            if shouldCancel?() == true {
                throw TraceReplayError.cancelled
            }

            if lastModeForPickFallback != frame.modelIn.mode {
                lastModeForPickFallback = frame.modelIn.mode
                pickFallbackLoggedForMode = nil
            }

            if let timingProvider {
                let targetTimeS = max(0, Double(frame.tsMs - startTsMs) / 1000.0)
                while timingProvider() + toleranceSeconds < targetTimeS {
                    if shouldCancel?() == true {
                        throw TraceReplayError.cancelled
                    }
                    usleep(2_000)
                }
            } else if let previousTsMs {
                let delayMs = max(0, frame.tsMs - previousTsMs)
                if delayMs > 0 {
                    usleep(UInt32(min(delayMs * 1000, Int(UInt32.max))))
                }
            }
            previousTsMs = frame.tsMs

            let sendTsMs = nowMs()
            let payload = try encoder.encode(frame.modelIn)
            let sentPacketJson = String(data: payload, encoding: .utf8)

            var interventions: [String] = baseInterventions
            var timedOut = false
            var recvTsMs: Int?
            var roundTripMs: Int?
            var decodeError: String?
            var modelOut: ModelOut?

            let sendResult: Int = payload.withUnsafeBytes { ptr in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.sendto(sock, ptr.baseAddress, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            if sendResult < 0 {
                timedOut = true
                decodeError = "send_error_errno_\(errno)"
                interventions.append("send_error")
            } else {
                var from = sockaddr_in()
                var fromLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
                var buf = [UInt8](repeating: 0, count: 65_535)

                let recvLen: Int = buf.withUnsafeMutableBytes { rawBuf in
                    withUnsafeMutablePointer(to: &from) { fromPtr in
                        fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.recvfrom(sock, rawBuf.baseAddress, rawBuf.count, 0, sockPtr, &fromLen)
                        }
                    }
                }

                if recvLen <= 0 {
                    timedOut = true
                    interventions.append("timeout")
                    decodeError = "recv_error_errno_\(errno)"
                } else {
                    recvTsMs = nowMs()
                    roundTripMs = recvTsMs.map { $0 - sendTsMs }

                    let data = Data(buf.prefix(recvLen))
                    do {
                        let decoded = try decoder.decode(ModelOut.self, from: data)
                        let enforced = ModeContract.enforceIncoming(modelOut: decoded, currentMode: frame.modelIn.mode)
                        let resolved = manifests.resolve(mode: enforced.0.mode, picks: enforced.0.picks)
                        modelOut = ModelOut(
                            protocolVersion: enforced.0.protocolVersion,
                            tsMs: enforced.0.tsMs,
                            mode: enforced.0.mode,
                            params: enforced.0.params,
                            picks: resolved.picks,
                            flags: enforced.0.flags
                        )
                        if !enforced.1.isEmpty {
                            interventions.append(contentsOf: enforced.1.map { "contract_violation:\($0)" })
                        }
                        if !resolved.notes.isEmpty, pickFallbackLoggedForMode != frame.modelIn.mode {
                            interventions.append(contentsOf: resolved.notes.map { "pick_resolution:\($0)" })
                            pickFallbackLoggedForMode = frame.modelIn.mode
                        }
                    } catch {
                        decodeError = error.localizedDescription
                        interventions.append("decode_error")
                        interventions.append("fallback_safe_defaults")
                        var fallback = ModeContract.protocolViolationFallback(mode: frame.modelIn.mode, tsMs: recvTsMs ?? nowMs())
                        let resolved = manifests.resolve(mode: fallback.mode, picks: fallback.picks)
                        fallback = ModelOut(
                            protocolVersion: fallback.protocolVersion,
                            tsMs: fallback.tsMs,
                            mode: fallback.mode,
                            params: fallback.params,
                            picks: resolved.picks,
                            flags: fallback.flags
                        )
                        modelOut = fallback
                        if !resolved.notes.isEmpty, pickFallbackLoggedForMode != frame.modelIn.mode {
                            interventions.append(contentsOf: resolved.notes.map { "pick_resolution:\($0)" })
                            pickFallbackLoggedForMode = frame.modelIn.mode
                        }
                    }
                }
            }

            let record = TraceRecord(
                recordedAtMs: nowMs(),
                modelIn: frame.modelIn,
                modelOut: modelOut,
                diagnostics: TraceDiagnostics(
                    requestId: max(1, frame.frameIndex),
                    sendTsMs: sendTsMs,
                    recvTsMs: recvTsMs,
                    roundTripMs: roundTripMs,
                    timedOut: timedOut,
                    decodeError: decodeError,
                    interventions: interventions
                ),
                featureSource: "replay",
                fallbackReason: nil,
                sentPacketJson: sentPacketJson,
                bundleId: frame.bundleId ?? session.metadata.bundleId,
                label: frame.label
            )
            recorder.append(record)
            onFrameResult?(frame, modelOut)
        }

        return recorder.url
    }

    static func replay(
        inputURL: URL,
        host: String,
        port: UInt16,
        fasterThanRealtime: Bool,
        speedMultiplier: Double = 8.0,
        timeoutMs: Int = 500,
        appName: String = "TheTubHarness"
    ) throws -> URL {
        try replay(
            inputURL: inputURL,
            host: host,
            port: port,
            fasterThanRealtime: fasterThanRealtime,
            speedMultiplier: speedMultiplier,
            timeoutMs: timeoutMs,
            bundleIdOverride: nil,
            appName: appName
        )
    }

    static func replay(
        inputURL: URL,
        host: String,
        port: UInt16,
        fasterThanRealtime: Bool,
        speedMultiplier: Double = 8.0,
        timeoutMs: Int = 500,
        bundleIdOverride: String? = nil,
        appName: String = "TheTubHarness"
    ) throws -> URL {
        let speed = fasterThanRealtime ? max(1.0, speedMultiplier) : 1.0
        return try replay(
            inputURL: inputURL,
            host: host,
            port: port,
            speed: speed,
            timeoutMs: timeoutMs,
            bundleIdOverride: bundleIdOverride,
            outputURL: nil,
            appName: appName
        )
    }

    private static func adjustedDelayMs(_ ms: Int, speed: Double) -> Int {
        guard speed > 0 else { return 0 }
        return max(0, Int(Double(ms) / max(0.000_001, speed)))
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

func encodableToJSONObject<T: Encodable>(_ value: T, encoder: JSONEncoder) -> Any? {
    do {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        return nil
    }
}

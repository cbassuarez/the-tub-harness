//
//  SpeechTranscriber.swift
//  TheTubHarness
//
//  Wraps Apple's SFSpeechRecognizer to produce transcription fragments
//  from live audio input. Results are published for integration into
//  the thought log display. Purely local — never sent over UDP.
//

import Foundation
import Speech
import Combine
import AVFoundation

@MainActor
final class SpeechTranscriber: ObservableObject {

    @Published private(set) var latestTranscription: String?
    @Published private(set) var isAuthorized: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var remoteModerationTask: Task<Void, Never>?
    private var isRunning = false

    /// Thread-safe reference to the active recognition request for buffer appending.
    /// SFSpeechAudioBufferRecognitionRequest.append is documented as thread-safe.
    nonisolated(unsafe) private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    /// Minimum interval between publishing new transcription results.
    private let publishInterval: TimeInterval = 2.0
    private var lastPublishDate: Date = .distantPast

    /// Minimum confidence to accept a transcription segment.
    private let minConfidence: Float = 0.4

    /// Maximum duration before restarting the recognition task (Apple caps at ~60s).
    private let restartInterval: TimeInterval = 50.0
    private var taskStartDate: Date = .distantPast
    private let segmentLookbackWindow: TimeInterval = 10.0
    private let fallbackSegmentCount: Int = 14
    private let maxPublishedWordCount: Int = 18

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Authorization

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthorized = (status == .authorized)
                // If start() was called before auth resolved, kick it off now.
                if self.isAuthorized && self.wantsRunning && !self.isRunning {
                    self.isRunning = true
                    self.startRecognitionTask()
                }
            }
        }
    }

    // MARK: - Start / Stop

    /// Whether the caller has requested running (may be waiting on auth).
    private var wantsRunning = false

    func start() {
        wantsRunning = true
        guard !isRunning else { return }
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        guard let recognizer, recognizer.isAvailable else { return }

        isRunning = true
        startRecognitionTask()
    }

    func stop() {
        wantsRunning = false
        isRunning = false
        remoteModerationTask?.cancel()
        remoteModerationTask = nil
        activeRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    // MARK: - Audio Buffer Input

    /// Mono 16 kHz float format expected by SFSpeechRecognizer.
    private nonisolated static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Feed raw CoreAudio buffers. Downmixes to mono, resamples to 16 kHz, appends.
    /// Call from any thread — SFSpeechAudioBufferRecognitionRequest.append is thread-safe.
    nonisolated func appendRawAudio(_ audioBufferList: UnsafePointer<AudioBufferList>, frameCount: Int, sampleRate: Double) {
        guard let request = activeRequest else { return }

        // Build a mono float buffer from the raw input.
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        monoBuf.frameLength = AVAudioFrameCount(frameCount)

        guard let dst = monoBuf.floatChannelData?[0] else { return }
        let abl = audioBufferList.pointee
        let bufCount = Int(abl.mNumberBuffers)
        // Access first buffer to get channel layout.
        withUnsafePointer(to: abl.mBuffers) { ptr in
            let bufs = UnsafeBufferPointer(start: ptr, count: bufCount)
            if bufCount == 1 {
                // Single interleaved buffer — may be multi-channel.
                let channels = Int(bufs[0].mNumberChannels)
                if let src = bufs[0].mData?.assumingMemoryBound(to: Float.self) {
                    if channels <= 1 {
                        memcpy(dst, src, frameCount * MemoryLayout<Float>.size)
                    } else {
                        for i in 0..<frameCount {
                            var sum: Float = 0
                            for ch in 0..<channels { sum += src[i * channels + ch] }
                            dst[i] = sum / Float(channels)
                        }
                    }
                }
            } else {
                // Deinterleaved — one buffer per channel.
                if let src = bufs[0].mData?.assumingMemoryBound(to: Float.self) {
                    memcpy(dst, src, frameCount * MemoryLayout<Float>.size)
                }
                for b in 1..<bufCount {
                    if let src = bufs[b].mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0..<frameCount { dst[i] += src[i] }
                    }
                }
                if bufCount > 1 {
                    let scale = 1.0 / Float(bufCount)
                    for i in 0..<frameCount { dst[i] *= scale }
                }
            }
        }

        // Resample to 16 kHz.
        guard let resampled = Self.resampleTo16k(monoBuf) else { return }
        request.append(resampled)
    }

    private nonisolated static func resampleTo16k(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == speechFormat.sampleRate {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: speechFormat) else { return nil }
        let ratio = speechFormat.sampleRate / buffer.format.sampleRate
        let outFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: outFrameCount) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }

    // MARK: - Internal

    private func startRecognitionTask() {
        guard let recognizer, recognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request
        self.activeRequest = request
        self.taskStartDate = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }

                if let result {
                    self.handleResult(result)
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Restart the task for continuous recognition.
                    self.activeRequest = nil
                    self.recognitionRequest?.endAudio()
                    self.recognitionRequest = nil
                    self.recognitionTask = nil

                    if self.isRunning {
                        // Brief delay before restarting to avoid thrashing.
                        try? await Task.sleep(for: .milliseconds(500))
                        if self.isRunning {
                            self.startRecognitionTask()
                        }
                    }
                }
            }
        }
    }

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        let now = Date()

        // Rate limit.
        guard now.timeIntervalSince(lastPublishDate) >= publishInterval else { return }

        let bestTranscription = result.bestTranscription
        let segments = bestTranscription.segments
        guard !segments.isEmpty else { return }

        // Check confidence of the most recent segment.
        if let lastSegment = segments.last {
            guard lastSegment.confidence >= minConfidence || lastSegment.confidence == 0 else { return }
        }

        // Prefer the recent phrase window so we don't keep latching the first words.
        let recentSegments: [SFTranscriptionSegment]
        if let last = segments.last {
            let cutoff = max(0, last.timestamp - segmentLookbackWindow)
            let filtered = segments.filter { $0.timestamp >= cutoff }
            recentSegments = filtered.isEmpty ? Array(segments.suffix(fallbackSegmentCount)) : filtered
        } else {
            recentSegments = Array(segments.suffix(fallbackSegmentCount))
        }

        let text = recentSegments
            .map(\.substring)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return }

        // Only publish if we have substantial text (at least 2 words).
        let wordCount = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        guard wordCount >= 2 else { return }

        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let trimmed = words.count > maxPublishedWordCount
            ? words.suffix(maxPublishedWordCount).joined(separator: " ")
            : text
        let moderated = StageTextModeration.sanitizeSpeechLine(trimmed)

        if latestTranscription == moderated {
            return
        }

        latestTranscription = moderated
        lastPublishDate = now
        scheduleRemoteModerationIfNeeded(sourceText: trimmed, localModerated: moderated)

        // Restart the task periodically to avoid Apple's recognition timeout.
        if now.timeIntervalSince(taskStartDate) > restartInterval {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            startRecognitionTask()
        }
    }

    private func scheduleRemoteModerationIfNeeded(sourceText: String, localModerated: String) {
        remoteModerationTask?.cancel()
        remoteModerationTask = Task { [weak self] in
            guard let self else { return }
            let refined = await StageTextModeration.sanitizeSpeechLineUsingBedrockIfAvailable(sourceText)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isRunning else { return }
                // Prevent stale network responses from overriding newer transcriptions.
                guard self.latestTranscription == localModerated else { return }
                guard refined != localModerated else { return }
                self.latestTranscription = refined
            }
        }
    }
}

/// Centralized moderation for speech-driven and display-facing text.
/// Default list intentionally focuses on high-confidence profanity.
/// Additional project-specific terms can be supplied with:
/// `TUB_SPEECH_BLOCKLIST=term1,term2,term3`
enum StageTextModeration {
    static let redactionToken = "[REDACTED]"
    static let thoughtFallback = "content_redacted"
    private static let customTermsEnvironmentKey = "TUB_SPEECH_BLOCKLIST"

    private static let builtInBlockedTerms: Set<String> = [
        "asshole",
        "bastard",
        "bitch",
        "bullshit",
        "crap",
        "cunt",
        "dammit",
        "fucker",
        "fucking",
        "fuck",
        "goddamn",
        "motherfucker",
        "pussy",
        "shit",
        "shitty",
        "slut",
        "whore"
    ]

    private static let blockedTerms: Set<String> = {
        let configured = ProcessInfo.processInfo.environment[customTermsEnvironmentKey] ?? ""
        let customTerms = configured
            .split(separator: ",")
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
        return builtInBlockedTerms.union(customTerms)
    }()

    static func sanitizeSpeechLine(_ line: String) -> String {
        sanitizeDisplayLine(line)
    }

    static func sanitizeSpeechLineUsingBedrockIfAvailable(_ line: String) async -> String {
        let local = sanitizeSpeechLine(line)
        guard !local.contains(redactionToken) else { return local }

        guard let remote = await BedrockGuardrailModerator.shared.moderate(line: line) else {
            return local
        }

        let cleanedRemote = sanitizeDisplayLine(remote)
        if cleanedRemote == line {
            return local
        }
        return cleanedRemote
    }

    static func sanitizeDisplayLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var result = ""
        var currentWord = ""
        var didRedactWord = false

        func flushWord() {
            guard !currentWord.isEmpty else { return }
            if shouldRedact(word: currentWord) {
                result.append(redactionToken)
                didRedactWord = true
            } else {
                result.append(currentWord)
            }
            currentWord.removeAll(keepingCapacity: true)
        }

        for character in trimmed {
            if character.isLetter || character.isNumber {
                currentWord.append(character)
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()

        if didRedactWord {
            return result
        }

        // Catch obfuscated patterns spread over punctuation (example: f.u.c.k).
        let collapsed = normalizeToken(trimmed)
        for term in blockedTerms where term.count >= 4 {
            if collapsed.contains(term) {
                return redactionToken
            }
        }

        return result
    }

    static func sanitizeThoughtToken(_ token: String) -> String {
        let normalized = normalizeToken(token)
        guard !normalized.isEmpty else { return token }
        return blockedTerms.contains(normalized) ? thoughtFallback : token
    }

    static func sanitizeThoughtLog(_ lines: [String]) -> [String] {
        Array(
            lines
                .map(sanitizeDisplayLine)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(5)
        )
    }

    static func sanitizeVisual(_ visual: VisualOut) -> VisualOut {
        let sanitizedThought = sanitizeThoughtToken(visual.thought)
        let sanitizedLog = sanitizeThoughtLog(visual.thoughtLog)
        guard sanitizedThought != visual.thought || sanitizedLog != visual.thoughtLog else {
            return visual
        }
        return VisualOut(
            sceneId: visual.sceneId,
            density: visual.density,
            cohesion: visual.cohesion,
            disruption: visual.disruption,
            tokenSalience: visual.tokenSalience,
            wordmarkIntegrity: visual.wordmarkIntegrity,
            decayMs: visual.decayMs,
            flashBias: visual.flashBias,
            anchorWeights: visual.anchorWeights,
            thought: sanitizedThought,
            thoughtLog: sanitizedLog
        )
    }

    private static func shouldRedact(word: String) -> Bool {
        let normalized = normalizeToken(word)
        guard !normalized.isEmpty else { return false }
        if blockedTerms.contains(normalized) {
            return true
        }
        // Handle elongated profanity like "fuuuck".
        return blockedTerms.contains(normalizeRepeatedCharacters(normalized))
    }

    private static func normalizeToken(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: .current
        )
        let mapped = folded.lowercased().map(mapLeetCharacter(_:))
        let alnum = mapped.filter { $0.isLetter || $0.isNumber }
        return normalizeRepeatedCharacters(String(alnum))
    }

    private static func mapLeetCharacter(_ character: Character) -> Character {
        switch character {
        case "0":
            return "o"
        case "1", "!", "|":
            return "i"
        case "2":
            return "z"
        case "3":
            return "e"
        case "4", "@":
            return "a"
        case "5", "$":
            return "s"
        case "6", "9":
            return "g"
        case "7":
            return "t"
        case "8":
            return "b"
        default:
            return character
        }
    }

    private static func normalizeRepeatedCharacters(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        var normalized = ""
        var previous: Character?
        for character in token {
            if previous == character { continue }
            normalized.append(character)
            previous = character
        }
        return normalized
    }
}

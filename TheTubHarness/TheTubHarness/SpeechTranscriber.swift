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

        // Check for new transcription text.
        let bestTranscription = result.bestTranscription
        let text = bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Check confidence of the most recent segment.
        if let lastSegment = bestTranscription.segments.last {
            guard lastSegment.confidence >= minConfidence || lastSegment.confidence == 0 else { return }
        }

        // Only publish if we have substantial text (at least 2 words).
        let wordCount = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        guard wordCount >= 2 else { return }

        // Take the last ~60 chars to keep it concise.
        let trimmed: String
        if text.count > 80 {
            let suffix = String(text.suffix(80))
            if let spaceIdx = suffix.firstIndex(of: " ") {
                trimmed = String(suffix[suffix.index(after: spaceIdx)...])
            } else {
                trimmed = suffix
            }
        } else {
            trimmed = text
        }

        latestTranscription = trimmed
        lastPublishDate = now

        // Restart the task periodically to avoid Apple's recognition timeout.
        if now.timeIntervalSince(taskStartDate) > restartInterval {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            startRecognitionTask()
        }
    }
}

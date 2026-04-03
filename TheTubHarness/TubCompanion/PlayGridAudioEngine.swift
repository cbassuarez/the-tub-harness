//
//  PlayGridAudioEngine.swift
//  TubCompanion
//
//  Lightweight one-shot audio engine for the Play grid.
//

import AVFAudio
import Foundation

final class PlayGridAudioEngine {
    private enum LongPlaybackSlot: Int {
        case a = 0
        case b = 1

        var alternate: LongPlaybackSlot {
            self == .a ? .b : .a
        }
    }

    private let queue = DispatchQueue(label: "tub.play.grid.audio", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueKeyValue: UInt8 = 1
    private let session = AVAudioSession.sharedInstance()

    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoiceIndex = 0
    private var longVoices: [AVAudioPlayerNode] = []
    private var longMixer: AVAudioMixerNode?
    private var activeLongSlot: LongPlaybackSlot?
    private var activeLongURL: URL?
    private var retainedLongFiles: [Int: AVAudioFile] = [:]
    private var longTransitionGeneration = 0
    private var longDuckGeneration = 0
    private let longDuckFloor: Float = 0.5
    private let longMixBaseVolume: Float = 1

    private var bufferCache: [URL: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [URL] = []
    private let cacheLimit = 96

    init() {
        queue.setSpecific(key: queueKey, value: queueKeyValue)
        queue.async { [weak self] in
            self?.configureEngineLocked()
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == queueKeyValue {
            teardownLocked()
        } else {
            queue.sync {
                teardownLocked()
            }
        }
    }

    func setOutputPolicy(allowSpeakerFallback: Bool, prefersExternal: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            do {
                var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowAirPlay]
                if allowSpeakerFallback {
                    options.insert(.defaultToSpeaker)
                }

                try self.session.setCategory(.playAndRecord, mode: .default, options: options)
                try self.session.setActive(true, options: [])

                if allowSpeakerFallback && !prefersExternal {
                    try self.session.overrideOutputAudioPort(.speaker)
                } else {
                    try self.session.overrideOutputAudioPort(.none)
                }
            } catch {
                // Non-fatal; graph may still operate.
            }

            _ = self.ensureEngineRunningLocked()
        }
    }

    func trigger(url: URL, pan: Float, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard let buffer = self.loadBufferLocked(url: url) else { return }
            guard !self.voices.isEmpty else { return }

            let voice = self.voices[self.nextVoiceIndex % self.voices.count]
            self.nextVoiceIndex = (self.nextVoiceIndex + 1) % max(self.voices.count, 1)

            if voice.isPlaying {
                voice.stop()
            }

            voice.pan = max(-1, min(1, pan))
            voice.volume = max(0, min(1, gain))
            voice.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            voice.play()
            self.duckLongLayerLocked()
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for voice in self.voices where voice.isPlaying {
                voice.stop()
            }
        }
    }

    func triggerLong(url: URL, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !self.longVoices.isEmpty else { return }
            guard self.scheduleLongFileLocked(on: .a, url: url) else { return }

            self.longTransitionGeneration += 1
            self.longDuckGeneration += 1
            self.activeLongSlot = .a
            self.activeLongURL = url
            self.longVoices[LongPlaybackSlot.a.rawValue].volume = max(0, min(1, gain))
            self.longVoices[LongPlaybackSlot.b.rawValue].stop()
            self.longVoices[LongPlaybackSlot.b.rawValue].volume = 0
            self.longMixer?.volume = self.longMixBaseVolume
        }
    }

    func transitionLong(to url: URL, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !self.longVoices.isEmpty else { return }

            if self.activeLongURL == url, self.isLongPlaybackActiveLocked {
                return
            }

            let fromSlot = self.activeLongSlot ?? .a
            let toSlot = fromSlot.alternate
            guard self.scheduleLongFileLocked(on: toSlot, url: url) else { return }
            self.crossfadeLongLocked(from: fromSlot, to: toSlot, targetGain: gain, duration: 0.24)
            self.activeLongSlot = toSlot
            self.activeLongURL = url
        }
    }

    func stopLong() {
        queue.async { [weak self] in
            guard let self else { return }
            self.longTransitionGeneration += 1
            self.longDuckGeneration += 1
            for (index, node) in self.longVoices.enumerated() {
                node.stop()
                node.volume = 0
                self.retainedLongFiles.removeValue(forKey: index)
            }
            self.activeLongSlot = nil
            self.activeLongURL = nil
            self.longMixer?.volume = self.longMixBaseVolume
        }
    }

    func duckLongLayerForGridHit() {
        queue.async { [weak self] in
            self?.duckLongLayerLocked()
        }
    }

    private func configureEngineLocked() {
        let newEngine = AVAudioEngine()
        let outputMixer = newEngine.mainMixerNode
        var newVoices: [AVAudioPlayerNode] = []
        let newLongMixer = AVAudioMixerNode()
        var newLongVoices: [AVAudioPlayerNode] = []

        for _ in 0..<12 {
            let node = AVAudioPlayerNode()
            newEngine.attach(node)
            newEngine.connect(node, to: outputMixer, format: nil)
            newVoices.append(node)
        }

        newEngine.attach(newLongMixer)
        newEngine.connect(newLongMixer, to: outputMixer, format: nil)
        newLongMixer.outputVolume = longMixBaseVolume

        for _ in 0..<2 {
            let node = AVAudioPlayerNode()
            newEngine.attach(node)
            newEngine.connect(node, to: newLongMixer, format: nil)
            node.volume = 0
            newLongVoices.append(node)
        }

        newEngine.prepare()
        engine = newEngine
        voices = newVoices
        longMixer = newLongMixer
        longVoices = newLongVoices
        _ = ensureEngineRunningLocked()
    }

    @discardableResult
    private func ensureEngineRunningLocked() -> Bool {
        if engine == nil {
            configureEngineLocked()
        }
        guard let engine else { return false }

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

    private func loadBufferLocked(url: URL) -> AVAudioPCMBuffer? {
        if let cached = bufferCache[url] {
            return cached
        }

        guard let loaded = loadBufferFromDisk(url: url) else {
            return nil
        }

        bufferCache[url] = loaded
        cacheOrder.append(url)
        evictCacheIfNeededLocked()

        return loaded
    }

    private func loadBufferFromDisk(url: URL) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0 else { return nil }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                return nil
            }
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    private func evictCacheIfNeededLocked() {
        guard bufferCache.count > cacheLimit else { return }
        while bufferCache.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            bufferCache.removeValue(forKey: oldest)
        }
    }

    private var isLongPlaybackActiveLocked: Bool {
        guard let slot = activeLongSlot else { return false }
        guard slot.rawValue < longVoices.count else { return false }
        return longVoices[slot.rawValue].isPlaying
    }

    private func scheduleLongFileLocked(on slot: LongPlaybackSlot, url: URL) -> Bool {
        guard slot.rawValue < longVoices.count else { return false }
        let node = longVoices[slot.rawValue]

        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { return false }
            node.stop()
            node.scheduleFile(file, at: nil, completionHandler: nil)
            retainedLongFiles[slot.rawValue] = file
            node.play()
            return true
        } catch {
            return false
        }
    }

    private func crossfadeLongLocked(from fromSlot: LongPlaybackSlot, to toSlot: LongPlaybackSlot, targetGain: Float, duration: TimeInterval) {
        guard fromSlot.rawValue < longVoices.count, toSlot.rawValue < longVoices.count else { return }

        longTransitionGeneration += 1
        let generation = longTransitionGeneration
        let toNode = longVoices[toSlot.rawValue]
        let fromNode = longVoices[fromSlot.rawValue]
        let clampedGain = max(0, min(1, targetGain))
        toNode.volume = 0
        let steps = 8
        let stepDuration = max(0.015, duration / Double(steps))

        for step in 1...steps {
            queue.asyncAfter(deadline: .now() + (Double(step) * stepDuration)) { [weak self] in
                guard let self else { return }
                guard generation == self.longTransitionGeneration else { return }
                let progress = Float(step) / Float(steps)
                toNode.volume = clampedGain * progress
                fromNode.volume = clampedGain * (1 - progress)
                if step == steps {
                    fromNode.stop()
                    fromNode.volume = 0
                    self.retainedLongFiles.removeValue(forKey: fromSlot.rawValue)
                }
            }
        }
    }

    private func duckLongLayerLocked() {
        guard isLongPlaybackActiveLocked else { return }
        guard let longMixer else { return }

        longDuckGeneration += 1
        let generation = longDuckGeneration
        let attackStart = longMixer.volume
        animateLongMixerVolumeLocked(
            from: attackStart,
            to: longDuckFloor,
            duration: 0.045,
            steps: 3,
            generation: generation
        )

        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard generation == self.longDuckGeneration else { return }
            let current = self.longMixer?.volume ?? self.longDuckFloor
            self.animateLongMixerVolumeLocked(
                from: current,
                to: self.longMixBaseVolume,
                duration: 0.34,
                steps: 9,
                generation: generation
            )
        }
    }

    private func animateLongMixerVolumeLocked(
        from start: Float,
        to end: Float,
        duration: TimeInterval,
        steps: Int,
        generation: Int
    ) {
        guard let longMixer else { return }
        let clampedSteps = max(1, steps)
        let stepDuration = max(0.01, duration / Double(clampedSteps))
        for step in 1...clampedSteps {
            queue.asyncAfter(deadline: .now() + (Double(step) * stepDuration)) { [weak self] in
                guard let self else { return }
                guard generation == self.longDuckGeneration else { return }
                let progress = Float(step) / Float(clampedSteps)
                longMixer.volume = start + ((end - start) * progress)
            }
        }
    }

    private func teardownLocked() {
        for node in voices {
            node.stop()
        }
        for node in longVoices {
            node.stop()
        }
        engine?.stop()
        voices.removeAll()
        longVoices.removeAll()
        longMixer = nil
        engine = nil
        retainedLongFiles.removeAll(keepingCapacity: false)
        activeLongSlot = nil
        activeLongURL = nil
        bufferCache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
    }
}

extension PlayGridAudioEngine {
    nonisolated static func sampleDuration(url: URL) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            return Double(file.length) / sampleRate
        } catch {
            return nil
        }
    }

    nonisolated static func discoverSampleLibrary() -> [URL] {
        let allowedExtensions = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
        let preferredSubdirectories: [String?] = ["Samples", "Assets/Samples", nil]
        var discovered: [URL] = []
        var seen = Set<String>()

        for subdirectory in preferredSubdirectories {
            for ext in allowedExtensions {
                let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: subdirectory) ?? []
                for url in urls {
                    let key = url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
                    if seen.insert(key).inserted {
                        discovered.append(url)
                    }
                }
            }
            if !discovered.isEmpty, subdirectory != nil {
                // Prefer explicit sample folders when present.
                break
            }
        }

        return discovered.sorted {
            let left = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if left != .orderedSame {
                return left == .orderedAscending
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

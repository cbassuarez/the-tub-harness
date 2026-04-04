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
    private let preloadQueue = DispatchQueue(
        label: "tub.play.grid.audio.preload",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueKeyValue: UInt8 = 1
    private let session = AVAudioSession.sharedInstance()
    private let meterLock = NSLock()

    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var shortMixer: AVAudioMixerNode?
    private var nextVoiceIndex = 0
    private var longVoices: [AVAudioPlayerNode] = []
    private var longMixer: AVAudioMixerNode?
    private var activeLongSlot: LongPlaybackSlot?
    private var activeLongURL: URL?
    private var longSlotURLs: [URL?] = [nil, nil]
    private var longLoopGenerations: [Int] = [0, 0]
    private var retainedLongFiles: [Int: AVAudioFile] = [:]
    private var retainedOneShotFiles: [UUID: AVAudioFile] = [:]
    private var longTransitionGeneration = 0
    private var longDuckGeneration = 0
    private let longDuckFloor: Float = 0.5
    private let longMixBaseVolume: Float = 1
    private var shortMeterLevel: Float = 0
    private var longMeterLevel: Float = 0
    private var shortMeterPeakHold: Float = 0
    private var longMeterPeakHold: Float = 0

    private var bufferCache: [URL: AVAudioPCMBuffer] = [:]
    private var inflightPreloadURLs: Set<URL> = []
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

                try self.session.setPreferredSampleRate(48_000)
                try self.session.setPreferredIOBufferDuration(0.0029)
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

    func preload(urls: [URL], limit: Int = 72) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !urls.isEmpty else { return }

            var seen = Set<URL>()
            var queued = 0
            for url in urls {
                guard queued < max(1, limit) else { break }
                guard seen.insert(url).inserted else { continue }
                self.startPreloadLocked(url: url)
                queued += 1
            }
        }
    }

    func trigger(url: URL, pan: Float, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !self.voices.isEmpty else { return }

            let voice = self.voices[self.nextVoiceIndex % self.voices.count]
            self.nextVoiceIndex = (self.nextVoiceIndex + 1) % max(self.voices.count, 1)

            if voice.isPlaying {
                voice.stop()
            }

            voice.pan = max(-1, min(1, pan))
            voice.volume = max(0, min(1, gain))
            if let cached = self.bufferCache[url] {
                voice.scheduleBuffer(cached, at: nil, options: [], completionHandler: nil)
            } else if !self.scheduleOneShotFileLocked(on: voice, url: url) {
                guard let fallbackBuffer = self.loadBufferLocked(url: url) else { return }
                voice.scheduleBuffer(fallbackBuffer, at: nil, options: [], completionHandler: nil)
            }
            self.startPreloadLocked(url: url)
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

    func blendLong(primaryURL: URL, secondaryURL: URL?, mix: Float, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !self.longVoices.isEmpty else { return }
            guard self.applyLongBlendSourcesLocked(
                primaryURL: primaryURL,
                secondaryURL: secondaryURL,
                mix: mix,
                gain: gain
            ) else { return }

            self.longTransitionGeneration += 1
            self.longDuckGeneration += 1
            self.longMixer?.volume = self.longMixBaseVolume
        }
    }

    func transitionLongBlend(primaryURL: URL, secondaryURL: URL?, mix: Float, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ensureEngineRunningLocked() else { return }
            guard !self.longVoices.isEmpty else { return }

            self.longTransitionGeneration += 1
            self.longDuckGeneration += 1
            let generation = self.longDuckGeneration
            let fadeOutDuration = 0.075
            let fadeInDuration = 0.16
            let priorVolume = self.longMixer?.volume ?? self.longMixBaseVolume

            self.animateLongMixerVolumeLocked(
                from: priorVolume,
                to: 0,
                duration: fadeOutDuration,
                steps: 4,
                generation: generation
            )

            self.queue.asyncAfter(deadline: .now() + fadeOutDuration + 0.01) { [weak self] in
                guard let self else { return }
                guard generation == self.longDuckGeneration else { return }

                guard self.applyLongBlendSourcesLocked(
                    primaryURL: primaryURL,
                    secondaryURL: secondaryURL,
                    mix: mix,
                    gain: gain
                ) else {
                    self.animateLongMixerVolumeLocked(
                        from: self.longMixer?.volume ?? 0,
                        to: priorVolume,
                        duration: 0.08,
                        steps: 4,
                        generation: generation
                    )
                    return
                }

                self.longMixer?.volume = 0
                self.animateLongMixerVolumeLocked(
                    from: 0,
                    to: self.longMixBaseVolume,
                    duration: fadeInDuration,
                    steps: 7,
                    generation: generation
                )
            }
        }
    }

    func stopLong() {
        queue.async { [weak self] in
            guard let self else { return }
            self.longTransitionGeneration += 1
            self.longDuckGeneration += 1
            for (index, node) in self.longVoices.enumerated() {
                if index < self.longLoopGenerations.count {
                    self.longLoopGenerations[index] += 1
                }
                node.stop()
                node.volume = 0
                self.retainedLongFiles.removeValue(forKey: index)
                if index < self.longSlotURLs.count {
                    self.longSlotURLs[index] = nil
                }
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

    func currentMeterLevels() -> (short: Double, long: Double) {
        meterLock.lock()
        let short = max(shortMeterLevel, shortMeterPeakHold)
        let long = max(longMeterLevel, longMeterPeakHold)
        shortMeterPeakHold = max(0, shortMeterPeakHold * 0.92)
        longMeterPeakHold = max(0, longMeterPeakHold * 0.94)
        if shortMeterPeakHold < 0.001 { shortMeterPeakHold = 0 }
        if longMeterPeakHold < 0.001 { longMeterPeakHold = 0 }
        meterLock.unlock()
        return (Double(short), Double(long))
    }

    private func configureEngineLocked() {
        let newEngine = AVAudioEngine()
        let outputMixer = newEngine.mainMixerNode
        let newShortMixer = AVAudioMixerNode()
        var newVoices: [AVAudioPlayerNode] = []
        let newLongMixer = AVAudioMixerNode()
        var newLongVoices: [AVAudioPlayerNode] = []

        newEngine.attach(newShortMixer)
        newEngine.connect(newShortMixer, to: outputMixer, format: nil)

        for _ in 0..<12 {
            let node = AVAudioPlayerNode()
            newEngine.attach(node)
            newEngine.connect(node, to: newShortMixer, format: nil)
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
        shortMixer = newShortMixer
        longMixer = newLongMixer
        longVoices = newLongVoices
        installMeterTapLocked(on: newShortMixer, lane: .short)
        installMeterTapLocked(on: newLongMixer, lane: .long)
        _ = ensureEngineRunningLocked()
    }

    private enum MeterLane {
        case short
        case long
    }

    private func installMeterTapLocked(on node: AVAudioMixerNode, lane: MeterLane) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 128, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let measured = Self.computeMeterLevel(from: buffer)
            self.storeMeterLevel(measured, lane: lane)
        }
    }

    private func storeMeterLevel(_ level: Float, lane: MeterLane) {
        let clamped = max(0, min(1, level))
        meterLock.lock()
        switch lane {
        case .short:
            shortMeterLevel = clamped
            shortMeterPeakHold = max(shortMeterPeakHold, clamped)
        case .long:
            longMeterLevel = clamped
            longMeterPeakHold = max(longMeterPeakHold, clamped)
        }
        meterLock.unlock()
    }

    private static func computeMeterLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channelCount = max(1, Int(buffer.format.channelCount))

        var peak: Float = 0
        var energy: Double = 0
        var sampleCount = 0

        if let channels = buffer.floatChannelData {
            for ch in 0..<channelCount {
                let channel = channels[ch]
                for index in 0..<frameCount {
                    let value = abs(channel[index])
                    peak = max(peak, value)
                    energy += Double(value * value)
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let norm: Float = 1.0 / Float(Int16.max)
            for ch in 0..<channelCount {
                let channel = channels[ch]
                for index in 0..<frameCount {
                    let value = abs(Float(channel[index]) * norm)
                    peak = max(peak, value)
                    energy += Double(value * value)
                    sampleCount += 1
                }
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = Float(sqrt(energy / Double(sampleCount)))
        let blended = max(peak, rms * 1.35)
        let boosted = min(1, blended * 5.1)
        // Non-linear lift keeps quiet sounds visible while preserving contrast.
        return max(0, min(1, pow(boosted, 0.42)))
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

        node.stop()
        longLoopGenerations[slot.rawValue] += 1
        let generation = longLoopGenerations[slot.rawValue]
        if slot.rawValue < longSlotURLs.count {
            longSlotURLs[slot.rawValue] = url
        }
        retainedLongFiles.removeValue(forKey: slot.rawValue)
        return scheduleLongLoopLocked(on: slot, generation: generation)
    }

    private func applyLongBlendSourcesLocked(primaryURL: URL, secondaryURL: URL?, mix: Float, gain: Float) -> Bool {
        let clampedMix = max(0, min(1, mix))
        let clampedGain = max(0, min(1, gain))

        guard ensureLongFilePlayingLocked(on: .a, url: primaryURL) else { return false }
        let hasSecondary = secondaryURL != nil && secondaryURL != primaryURL
        if hasSecondary {
            guard ensureLongFilePlayingLocked(on: .b, url: secondaryURL) else { return false }
        } else {
            longLoopGenerations[LongPlaybackSlot.b.rawValue] += 1
            longVoices[LongPlaybackSlot.b.rawValue].stop()
            longVoices[LongPlaybackSlot.b.rawValue].volume = 0
            retainedLongFiles.removeValue(forKey: LongPlaybackSlot.b.rawValue)
            longSlotURLs[LongPlaybackSlot.b.rawValue] = nil
        }

        let leftGain: Float
        let rightGain: Float
        if hasSecondary {
            leftGain = (1 - clampedMix) * clampedGain
            rightGain = clampedMix * clampedGain
        } else {
            leftGain = clampedGain
            rightGain = 0
        }

        longVoices[LongPlaybackSlot.a.rawValue].volume = leftGain
        longVoices[LongPlaybackSlot.b.rawValue].volume = rightGain
        activeLongSlot = hasSecondary && rightGain > leftGain ? .b : .a
        activeLongURL = hasSecondary && rightGain > leftGain ? secondaryURL : primaryURL
        return true
    }

    private func ensureLongFilePlayingLocked(on slot: LongPlaybackSlot, url: URL?) -> Bool {
        guard slot.rawValue < longVoices.count else { return false }
        guard let url else {
            longLoopGenerations[slot.rawValue] += 1
            longVoices[slot.rawValue].stop()
            longVoices[slot.rawValue].volume = 0
            retainedLongFiles.removeValue(forKey: slot.rawValue)
            if slot.rawValue < longSlotURLs.count {
                longSlotURLs[slot.rawValue] = nil
            }
            return true
        }
        if slot.rawValue < longSlotURLs.count,
           longSlotURLs[slot.rawValue] == url,
           longVoices[slot.rawValue].isPlaying {
            return true
        }
        return scheduleLongFileLocked(on: slot, url: url)
    }

    @discardableResult
    private func scheduleLongLoopLocked(on slot: LongPlaybackSlot, generation: Int) -> Bool {
        guard slot.rawValue < longVoices.count else { return false }
        guard generation == longLoopGenerations[slot.rawValue] else { return false }
        guard slot.rawValue < longSlotURLs.count else { return false }
        guard let url = longSlotURLs[slot.rawValue] else { return false }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { return false }
        } catch {
            return false
        }

        let node = longVoices[slot.rawValue]
        retainedLongFiles[slot.rawValue] = file
        node.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                guard slot.rawValue < self.longLoopGenerations.count else { return }
                guard generation == self.longLoopGenerations[slot.rawValue] else { return }
                guard self.longSlotURLs[slot.rawValue] != nil else { return }
                self.scheduleLongLoopLocked(on: slot, generation: generation)
                if !node.isPlaying {
                    node.play()
                }
            }
        }
        if !node.isPlaying {
            node.play()
        }
        return true
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
                    self.longLoopGenerations[fromSlot.rawValue] += 1
                    fromNode.stop()
                    fromNode.volume = 0
                    self.retainedLongFiles.removeValue(forKey: fromSlot.rawValue)
                    if fromSlot.rawValue < self.longSlotURLs.count {
                        self.longSlotURLs[fromSlot.rawValue] = nil
                    }
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

    private func scheduleOneShotFileLocked(on voice: AVAudioPlayerNode, url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { return false }
            let token = UUID()
            retainedOneShotFiles[token] = file
            voice.scheduleFile(file, at: nil) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.retainedOneShotFiles.removeValue(forKey: token)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func startPreloadLocked(url: URL) {
        guard bufferCache[url] == nil else { return }
        guard inflightPreloadURLs.insert(url).inserted else { return }
        preloadQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.loadBufferFromDisk(url: url)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.inflightPreloadURLs.remove(url)
                guard self.bufferCache[url] == nil else { return }
                guard let loaded else { return }
                self.bufferCache[url] = loaded
                self.cacheOrder.append(url)
                self.evictCacheIfNeededLocked()
            }
        }
    }

    private func teardownLocked() {
        shortMixer?.removeTap(onBus: 0)
        longMixer?.removeTap(onBus: 0)
        for node in voices {
            node.stop()
        }
        for node in longVoices {
            node.stop()
        }
        engine?.stop()
        voices.removeAll()
        shortMixer = nil
        longVoices.removeAll()
        longMixer = nil
        engine = nil
        retainedLongFiles.removeAll(keepingCapacity: false)
        longSlotURLs = [nil, nil]
        longLoopGenerations = [0, 0]
        activeLongSlot = nil
        activeLongURL = nil
        retainedOneShotFiles.removeAll(keepingCapacity: false)
        bufferCache.removeAll(keepingCapacity: false)
        inflightPreloadURLs.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        meterLock.lock()
        shortMeterLevel = 0
        longMeterLevel = 0
        shortMeterPeakHold = 0
        longMeterPeakHold = 0
        meterLock.unlock()
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
        let preferredSubdirectories: [String?] = [
            "Samples/grid",
            "Assets/Samples/grid",
            "Samples",
            "Assets/Samples",
            nil
        ]
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

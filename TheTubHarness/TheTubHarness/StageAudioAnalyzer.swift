import Foundation
import AVFoundation

struct StageAudioSnapshot: Equatable {
    let peak: Double
    let rms: Double
    let transientFlux: Double
    let lowBand: Double
    let midBand: Double
    let highBand: Double
    let brightness: Double
    let zeroCrossDensity: Double
    let silenceConfidence: Double
    let overloadPulse: Double
    let channelEnergy: [Double]
    let updatedAt: Date

    static let standby = StageAudioSnapshot(
        peak: 0,
        rms: 0,
        transientFlux: 0,
        lowBand: 0,
        midBand: 0,
        highBand: 0,
        brightness: 0,
        zeroCrossDensity: 0,
        silenceConfidence: 1,
        overloadPulse: 0,
        channelEnergy: [],
        updatedAt: .distantPast
    )

    func materiallyDiffers(from other: StageAudioSnapshot) -> Bool {
        abs(peak - other.peak) > 0.03
            || abs(rms - other.rms) > 0.02
            || abs(transientFlux - other.transientFlux) > 0.05
            || abs(lowBand - other.lowBand) > 0.05
            || abs(midBand - other.midBand) > 0.05
            || abs(highBand - other.highBand) > 0.05
            || abs(brightness - other.brightness) > 0.05
            || abs(zeroCrossDensity - other.zeroCrossDensity) > 0.06
            || abs(silenceConfidence - other.silenceConfidence) > 0.05
            || abs(overloadPulse - other.overloadPulse) > 0.05
            || channelEnergy != other.channelEnergy
    }
}

enum StageAudioAnalyzer {
    static func summarize(
        buffer: AVAudioPCMBuffer,
        activeMask: [Bool],
        channelGainDb: [Double]
    ) -> StageAudioSnapshot {
        guard let channelData = buffer.floatChannelData else { return .standby }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return .standby }

        let mask = InputChannelRouter.sanitizedMask(activeMask, channelCount: channelCount)
        let gains = InputChannelRouter.sanitizedChannelGains(channelGainDb, channelCount: channelCount)

        var perChannel = Array(repeating: 0.0, count: channelCount)
        var mixed = [Double](repeating: 0, count: frameCount)

        for frameIndex in 0..<frameCount {
            var sum: Double = 0
            var activeCount = 0
            for channel in 0..<channelCount where mask[channel] {
                let sample = Double(channelData[channel][frameIndex]) * Double(gains[channel])
                sum += sample
                perChannel[channel] += abs(sample)
                activeCount += 1
            }
            mixed[frameIndex] = activeCount > 0 ? (sum / Double(activeCount)) : 0
        }

        return summarizeMixedSamples(
            mixed,
            perChannelAbs: perChannel,
            activeMask: mask
        )
    }

    static func summarize(
        audioBufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        activeMask: [Bool],
        channelGainDb: [Double],
        sampleRate: Double
    ) -> StageAudioSnapshot {
        let binding = RawInputChannelBinding(audioBuffers: audioBufferList)
        let channelCount = binding.channelCount
        guard frameCount > 0, channelCount > 0 else { return .standby }

        let mask = InputChannelRouter.sanitizedMask(activeMask, channelCount: channelCount)
        let gains = InputChannelRouter.sanitizedChannelGains(channelGainDb, channelCount: channelCount)

        var perChannel = Array(repeating: 0.0, count: channelCount)
        var mixed = [Double](repeating: 0, count: frameCount)

        for frameIndex in 0..<frameCount {
            var sum: Double = 0
            var activeCount = 0
            for channel in 0..<channelCount where mask[channel] {
                let sample = Double(binding.sample(channelIndex: channel, frameIndex: frameIndex)) * Double(gains[channel])
                sum += sample
                perChannel[channel] += abs(sample)
                activeCount += 1
            }
            mixed[frameIndex] = activeCount > 0 ? (sum / Double(activeCount)) : 0
        }

        let snapshot = summarizeMixedSamples(
            mixed,
            perChannelAbs: perChannel,
            activeMask: mask
        )
        if sampleRate <= 0 {
            return snapshot
        }
        return snapshot
    }

    private static func summarizeMixedSamples(
        _ mixed: [Double],
        perChannelAbs: [Double],
        activeMask: [Bool]
    ) -> StageAudioSnapshot {
        guard !mixed.isEmpty else { return .standby }

        var peak = 0.0
        var sumSquares = 0.0
        var transientFlux = 0.0
        var zeroCrossCount = 0
        var previous = mixed[0]

        var slowLP = 0.0
        var fastLP = 0.0
        var lowEnergy = 0.0
        var midEnergy = 0.0
        var highEnergy = 0.0

        for sample in mixed {
            let absSample = abs(sample)
            peak = max(peak, absSample)
            sumSquares += sample * sample
            transientFlux += max(0, absSample - abs(previous))
            if (sample >= 0) != (previous >= 0) {
                zeroCrossCount += 1
            }
            previous = sample

            slowLP = (slowLP * 0.985) + (sample * 0.015)
            fastLP = (fastLP * 0.88) + (sample * 0.12)
            let low = abs(slowLP)
            let mid = abs(fastLP - slowLP)
            let high = abs(sample - fastLP)
            lowEnergy += low
            midEnergy += mid
            highEnergy += high
        }

        let frameCount = Double(mixed.count)
        let rms = sqrt(sumSquares / frameCount)
        let totalBandEnergy = max(1e-6, lowEnergy + midEnergy + highEnergy)

        let lowNorm = clamp(lowEnergy / totalBandEnergy)
        let midNorm = clamp(midEnergy / totalBandEnergy)
        let highNorm = clamp(highEnergy / totalBandEnergy)
        let brightness = clamp((highNorm * 0.75) + (midNorm * 0.25))
        let zeroCrossDensity = clamp(Double(zeroCrossCount) / max(1.0, frameCount * 0.5))
        let silenceConfidence = clamp(1.0 - (rms / 0.08))
        let overloadPulse = peak >= 0.98 ? 1.0 : clamp((peak - 0.78) / 0.20)
        let fluxNorm = clamp(transientFlux / max(0.001, frameCount * 0.08))

        let channelEnergy = perChannelAbs.enumerated().compactMap { index, totalAbs -> Double? in
            guard index < activeMask.count, activeMask[index] else { return nil }
            return clamp(totalAbs / frameCount / 0.22)
        }

        return StageAudioSnapshot(
            peak: clamp(peak),
            rms: clamp(rms / 0.14),
            transientFlux: fluxNorm,
            lowBand: lowNorm,
            midBand: midNorm,
            highBand: highNorm,
            brightness: brightness,
            zeroCrossDensity: zeroCrossDensity,
            silenceConfidence: silenceConfidence,
            overloadPulse: overloadPulse,
            channelEnergy: channelEnergy,
            updatedAt: Date()
        )
    }

    private static func clamp(_ value: Double, min lo: Double = 0.0, max hi: Double = 1.0) -> Double {
        Swift.max(lo, Swift.min(hi, value))
    }
}

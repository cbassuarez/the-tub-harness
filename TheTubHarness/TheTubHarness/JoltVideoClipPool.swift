import AVFoundation
import Foundation

/// Manages local video clips for jolt playback in modes 4–7.
/// Scans a directory at startup, loads durations, and provides
/// a muted AVPlayer seeked to a random point on demand.
@MainActor
final class JoltVideoClipPool {

    private struct ClipEntry {
        let asset: AVAsset
        let url: URL
        let duration: Double // seconds
    }

    private var clips: [ClipEntry] = []
    private var activePlayer: AVPlayer?

    private static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    // MARK: - Public

    var hasClips: Bool { !clips.isEmpty }

    /// Scan directory for supported video files and load their durations.
    func load(from directoryURL: URL) async {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            Self.log("Directory not found: \(directoryURL.path)")
            return
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch {
            Self.log("Failed to scan directory: \(error.localizedDescription)")
            return
        }

        let videoURLs = contents.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }

        var loaded: [ClipEntry] = []
        for url in videoURLs {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                guard seconds > 10 else { continue } // skip very short clips
                loaded.append(ClipEntry(asset: asset, url: url, duration: seconds))
                Self.log("Loaded: \(url.lastPathComponent) (\(Int(seconds))s)")
            } catch {
                Self.log("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        clips = loaded
        Self.log("Ready: \(clips.count) clips")
    }

    /// Deterministic 50/50 decision: should this jolt use video or webcam?
    func shouldUseVideo(seed: UInt64) -> Bool {
        guard !clips.isEmpty else { return false }
        let prng = StagePRNG(seed: seed ^ 0x71DE0)
        return prng.value(at: 0) < 0.5
    }

    /// Create a muted AVPlayer seeked to a random point in a random clip.
    /// Returns nil if no clips are loaded.
    func playerForSeed(_ seed: UInt64) -> AVPlayer? {
        guard !clips.isEmpty else { return nil }

        let prng = StagePRNG(seed: seed ^ 0xC11B5)
        let clipIndex = Int(prng.value(at: 1) * Double(clips.count)) % clips.count
        let clip = clips[clipIndex]

        let safeDuration = max(0, clip.duration - 10.0)
        let seekSeconds = prng.value(at: 2) * safeDuration
        let seekTime = CMTime(seconds: seekSeconds, preferredTimescale: 600)

        let item = AVPlayerItem(asset: clip.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        activePlayer = player
        Self.log("Playing \(clip.url.lastPathComponent) at \(Int(seekSeconds))s")
        return player
    }

    /// Stop playback and release the active player.
    func deactivate() {
        activePlayer?.pause()
        activePlayer = nil
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        print("[JoltVideoClipPool] \(message)")
    }
}

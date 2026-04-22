import AVFoundation
import Foundation

/// Manages local video clips for jolt playback in modes 4–7.
/// Scans a directory at startup, loads durations, and provides
/// a muted AVPlayer seeked to a random point on demand.
@MainActor
final class JoltVideoClipPool {

    private struct ClipEntry {
        let url: URL
        let duration: Double // seconds
    }

    private struct ClipScanEntry: Sendable {
        let url: URL
        let duration: Double
    }

    private struct ClipScanResult: Sendable {
        let entries: [ClipScanEntry]
        let logs: [String]
    }

    private var clips: [ClipEntry] = []
    private var activePlayer: AVPlayer?
    private var loadTask: Task<Void, Never>?

    private nonisolated static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private nonisolated static let bundledClipSubdirectories: [String] = [
        "Assets/JoltClips",
        "JoltClips",
        "Assets/Video/JoltClips",
        "Assets/Videos/JoltClips",
        "Video/JoltClips",
        "Videos/JoltClips",
    ]

    // MARK: - Public

    var hasClips: Bool { !clips.isEmpty }

    /// Resolve the startup directory for jolt clips.
    ///
    /// Order:
    /// 1. `TUB_JOLT_CLIP_DIR` override (if set)
    /// 2. Bundled clip directories
    /// 3. Bundle resource root (flattened-bundle fallback)
    nonisolated static func resolveStartupClipDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL?, source: String) {
        if let override = environment["TUB_JOLT_CLIP_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return (url, "env:TUB_JOLT_CLIP_DIR")
        }

        let fileManager = FileManager.default
        var seen: Set<String> = []
        let bundles: [Bundle] = [Bundle.main, Bundle(for: JoltVideoClipPool.self)]
        for bundle in bundles {
            guard let resourceRoot = bundle.resourceURL else { continue }
            let candidates = bundledClipSubdirectories.map { resourceRoot.appendingPathComponent($0, isDirectory: true) } + [resourceRoot]
            for candidate in candidates {
                let key = candidate.standardizedFileURL.path
                if seen.contains(key) { continue }
                seen.insert(key)
                if containsSupportedClip(in: candidate, fileManager: fileManager) {
                    return (candidate, "bundle:\(candidate.lastPathComponent)")
                }
            }
        }

        return (nil, "none")
    }

    /// Scan directory for supported video files and load their durations.
    func load(from directoryURL: URL) async {
        let result = await Self.scanClips(directoryURL: directoryURL)
        clips = result.entries.map { entry in
            ClipEntry(url: entry.url, duration: entry.duration)
        }
        for logLine in result.logs {
            Self.log(logLine)
        }
        Self.log("Ready: \(clips.count) clips")
    }

    /// Launches clip loading without blocking app startup.
    func loadInBackground(from directoryURL: URL) {
        loadTask?.cancel()
        loadTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.load(from: directoryURL)
        }
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

        let item = AVPlayerItem(url: clip.url)
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

    private nonisolated static func scanClips(directoryURL: URL) async -> ClipScanResult {
        let fileManager = FileManager.default
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return ClipScanResult(
                entries: [],
                logs: ["Directory not found: \(directoryURL.path)"]
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ClipScanResult(
                entries: [],
                logs: ["Failed to scan directory: \(directoryURL.path)"]
            )
        }

        let videoURLs: [URL] = enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
        .sorted { lhs, rhs in
            lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        var loaded: [ClipScanEntry] = []
        var logs: [String] = []
        loaded.reserveCapacity(videoURLs.count)

        for url in videoURLs {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                guard seconds > 10 else { continue } // skip very short clips
                loaded.append(ClipScanEntry(url: url, duration: seconds))
                logs.append("Loaded: \(url.lastPathComponent) (\(Int(seconds))s)")
            } catch {
                logs.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return ClipScanResult(entries: loaded, logs: logs)
    }

    private nonisolated static func containsSupportedClip(in directoryURL: URL, fileManager: FileManager) -> Bool {
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator {
            if supportedExtensions.contains(url.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    // MARK: - Logging

    private nonisolated static func log(_ message: String) {
        print("[JoltVideoClipPool] \(message)")
    }
}

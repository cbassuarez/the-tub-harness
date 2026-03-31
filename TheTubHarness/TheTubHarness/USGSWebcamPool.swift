import Foundation
import ImageIO
import os

/// Pre-fetches and caches USGS webcam images for jolt display in modes 4–7.
/// Thread-safe: the render loop reads synchronously at 60fps via `imageForSeed`,
/// while background Tasks fill and refresh the pool.
final class USGSWebcamPool: @unchecked Sendable {

    private let pool = OSAllocatedUnfairLock<[CGImage]>(initialState: [])
    private var fillTask: Task<Void, Never>?

    // MARK: - Public

    /// Synchronous, lock-protected read. Returns nil if pool is empty.
    func imageForSeed(_ seed: UInt64) -> CGImage? {
        let current = pool.withLock { $0 }
        guard !current.isEmpty else { return nil }
        return current[Int(seed % UInt64(current.count))]
    }

    var count: Int { pool.withLock { $0.count } }

    /// Starts background image fetching. Call once at app launch.
    func startFilling() {
        guard fillTask == nil else { return }
        fillTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Phase 1: volcano cams (fast, reliable, dramatic)
            await self.fetchVolcanoCams()
            Self.log("Volcano fill complete: \(self.count) images")

            // Phase 2: NIMS water resource cams (large variety)
            await self.fetchNIMSCams(target: 40)
            Self.log("NIMS fill complete: \(self.count) total images")

            // Phase 3: periodic refresh every 5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await self.refreshSubset(count: 8)
            }
        }
    }

    func stopRefreshing() {
        fillTask?.cancel()
        fillTask = nil
    }

    // MARK: - Volcano Webcams

    private static let volcanoIDs = [
        "V1cam", "V2cam", "V3cam", "B1cam",
        "KWcam", "F1cam", "K2cam", "KPcam"
    ]

    private func fetchVolcanoCams() async {
        await withTaskGroup(of: CGImage?.self) { group in
            for id in Self.volcanoIDs {
                group.addTask {
                    let url = "https://volcanoes.usgs.gov/observatories/hvo/cams/\(id)/images/M.jpg"
                    return await Self.fetchAndDecode(urlString: url)
                }
            }
            for await image in group {
                if let image {
                    pool.withLock { $0.append(image) }
                }
            }
        }
    }

    // MARK: - NIMS Water Resource Webcams

    private struct NIMSCamera: Decodable {
        let camId: String?
        let hideCam: Bool?
        let smallDir: String?
        let overlayDir: String?
    }

    private func fetchNIMSCams(target: Int) async {
        guard let cameras = await discoverNIMSCameras() else { return }
        guard !cameras.isEmpty else { return }

        // Pick a large random subset — fetch extra to compensate for failures
        let shuffled = cameras.shuffled()
        let candidates = shuffled.prefix(target * 3)

        await withTaskGroup(of: CGImage?.self) { group in
            var launched = 0
            for cam in candidates {
                guard launched < target * 2 else { break }
                guard let camId = cam.camId else { continue }
                // Prefer smallDir (720px, ~60KB), fall back to overlayDir (3840px)
                let imageDir = cam.smallDir ?? cam.overlayDir
                guard let imageDir else { continue }
                launched += 1
                group.addTask {
                    await Self.fetchNIMSLatestImage(camId: camId, imageDir: imageDir)
                }
            }
            var added = 0
            for await image in group {
                guard added < target else { break }
                if let image {
                    pool.withLock { $0.append(image) }
                    added += 1
                }
            }
        }
    }

    private func discoverNIMSCameras() async -> [NIMSCamera]? {
        guard let url = URL(string: "https://api.waterdata.usgs.gov/nims/v0/cameras") else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Self.log("NIMS cameras: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let decoder = JSONDecoder()
            if let cameras = try? decoder.decode([NIMSCamera].self, from: data) {
                let visible = cameras.filter { $0.hideCam != true && $0.camId != nil }
                Self.log("NIMS discovery: \(cameras.count) total, \(visible.count) visible")
                return visible
            }
            if let envelope = try? decoder.decode([String: [NIMSCamera]].self, from: data),
               let cameras = envelope.values.first {
                let visible = cameras.filter { $0.hideCam != true && $0.camId != nil }
                return visible
            }
            Self.log("NIMS cameras: unexpected JSON format")
            return nil
        } catch {
            Self.log("NIMS discovery failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchNIMSLatestImage(camId: String, imageDir: String) async -> CGImage? {
        // Step 1: Get newest filename
        guard let listURL = URL(string: "https://api.waterdata.usgs.gov/nims/v0/listFiles?camId=\(camId)&limit=1&recent=true") else {
            return nil
        }
        do {
            let request = URLRequest(url: listURL, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let filename = extractFilename(from: data) else { return nil }

            // Step 2: Construct image URL and fetch
            let sep = imageDir.hasSuffix("/") ? "" : "/"
            let imageURL = "\(imageDir)\(sep)\(filename)"
            return await fetchAndDecode(urlString: imageURL)
        } catch {
            return nil
        }
    }

    private static func extractFilename(from data: Data) -> String? {
        // JSON array of strings (most common)
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = arr.first {
            return first
        }
        // JSON array of objects with "filename" key
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let name = first["filename"] as? String ?? first["name"] as? String ?? first["file"] as? String {
            return name
        }
        // Envelope with "files" key
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = obj["files"] as? [String],
           let first = files.first {
            return first
        }
        return nil
    }

    // MARK: - Refresh

    private func refreshSubset(count: Int) async {
        let currentCount = self.count
        guard currentCount > 0 else {
            await fetchVolcanoCams()
            return
        }

        // Replace random slots with fresh NIMS images
        guard let cameras = await discoverNIMSCameras() else { return }
        let candidates = cameras.shuffled().prefix(count * 2)
        var replaced = 0
        for cam in candidates {
            guard replaced < count else { break }
            guard let camId = cam.camId else { continue }
            let imageDir = cam.smallDir ?? cam.overlayDir
            guard let imageDir else { continue }
            if let image = await Self.fetchNIMSLatestImage(camId: camId, imageDir: imageDir) {
                pool.withLock { images in
                    if images.isEmpty { return }
                    let idx = Int.random(in: 0..<images.count)
                    images[idx] = image
                }
                replaced += 1
            }
        }
        Self.log("Refreshed \(replaced) images (pool: \(self.count))")
    }

    // MARK: - Image Fetch & Decode

    private static func fetchAndDecode(urlString: String) async -> CGImage? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return decodeImage(data: data, maxPixels: 1920)
        } catch {
            return nil
        }
    }

    private static func decodeImage(data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        print("[USGSWebcamPool] \(message)")
    }
}

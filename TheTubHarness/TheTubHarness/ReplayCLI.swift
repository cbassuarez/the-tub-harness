import Foundation
import Darwin

enum ReplayCLI {
    static func runIfRequested(arguments: [String]) {
        guard let replayArgIndex = arguments.firstIndex(of: "--replay") else {
            return
        }

        guard replayArgIndex + 1 < arguments.count else {
            fputs("error: --replay requires a path\n", stderr)
            Darwin.exit(2)
        }

        let replayPath = arguments[replayArgIndex + 1]
        let speed = parseDouble(arguments: arguments, key: "--speed") ?? 1.0
        let outputPath = parseString(arguments: arguments, key: "--out")
        let bundleId = parseString(arguments: arguments, key: "--bundle-id")
        let host = parseString(arguments: arguments, key: "--host")
            ?? ProcessInfo.processInfo.environment["MODEL_HOST"]
            ?? "127.0.0.1"
        let port = parsePort(arguments: arguments)
            ?? UInt16(ProcessInfo.processInfo.environment["MODEL_PORT"] ?? "")
            ?? 9910

        let inputURL = URL(fileURLWithPath: replayPath)
        let outputURL = outputPath.map { URL(fileURLWithPath: $0) }

        do {
            ManifestCatalog.shared.logValidationSummary(context: "replay_cli")
            if let bundleBuild = try? RunBundleFactory.create(overrideBundleId: bundleId) {
                print("[replay_cli] \(RunBundleFactory.startupBanner(bundle: bundleBuild.bundle))")
                print("[replay_cli] bundle file: \(bundleBuild.fileURL.path)")
            }
            let out: URL
            do {
                out = try TraceReplayer.replay(
                    inputURL: inputURL,
                    host: host,
                    port: port,
                    speed: speed,
                    timeoutMs: 1_000,
                    bundleIdOverride: bundleId,
                    outputURL: outputURL
                )
            } catch {
                if outputURL != nil && isOutputPathAccessError(error) {
                    fputs("warn: cannot write requested --out path in current app sandbox; using app support logs path instead\n", stderr)
                    out = try TraceReplayer.replay(
                        inputURL: inputURL,
                        host: host,
                        port: port,
                        speed: speed,
                        timeoutMs: 1_000,
                        bundleIdOverride: bundleId,
                        outputURL: nil
                    )
                } else {
                    throw error
                }
            }
            print("{\"event\":\"replay_complete\",\"input\":\"\(inputURL.path)\",\"output\":\"\(out.path)\",\"speed\":\(speed),\"host\":\"\(host)\",\"port\":\(port)}")
            Darwin.exit(0)
        } catch {
            fputs("error: replay failed: \(error)\n", stderr)
            Darwin.exit(2)
        }
    }

    private static func parseString(arguments: [String], key: String) -> String? {
        guard let idx = arguments.firstIndex(of: key), idx + 1 < arguments.count else {
            return nil
        }
        return arguments[idx + 1]
    }

    private static func parseDouble(arguments: [String], key: String) -> Double? {
        guard let raw = parseString(arguments: arguments, key: key) else {
            return nil
        }
        return Double(raw)
    }

    private static func parsePort(arguments: [String]) -> UInt16? {
        guard let raw = parseString(arguments: arguments, key: "--port") else {
            return nil
        }
        return UInt16(raw)
    }

    private static func isOutputPathAccessError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return false }
        return ns.code == NSFileNoSuchFileError || ns.code == NSFileWriteNoPermissionError
    }
}

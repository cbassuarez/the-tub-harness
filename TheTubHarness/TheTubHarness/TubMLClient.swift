//
//  TubMLClient.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import Foundation
import Network
import SwiftUI
import Combine
import Darwin

final class TubMLClient: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var logPath: String?
    @Published var eventLogPath: String?
    @Published var bundlePath: String?
    @Published var sessionMetaPath: String?
    @Published var sessionDirectoryPath: String?
    @Published var inputAudioPath: String?
    @Published var activeSessionId: String?
    @Published var currentLabel: HumanLabel?

    @Published var sentCount: Int = 0
    @Published var recvCount: Int = 0
    @Published var timeoutCount: Int = 0

    @Published var lastOut: ModelOut?
    @Published var lastError: String?
    @Published var lastLatencyMs: Int?
    @Published var lastTickIntervalMs: Double?
    @Published var isReady: Bool = false

    private var timer: DispatchSourceTimer?
    private var trainingLogSession: TrainingLogSession?
    private var activeBundle: RunBundleMetadata?
    private var sessionId: String = "macos_harness_dev"
    private var frameIndex: Int = 0
    private let labelLock = NSLock()
    private var labelState: HumanLabel?

    private var inFlight: Bool = false
    private var activeRequestId: Int = 0
    private var timeoutWork: DispatchWorkItem?

    private var phase: Double = 0.0
    private let timeoutMs: Int = 500
    private var previousTickNs: UInt64?

    /// Called on reply decode success.
    /// - Parameters: (decoded out, latencyMs, buttons that were sent for that packet)
    var onModelOut: ((ModelOut, Int, Buttons) -> Void)?

    /// Safe to call from the UDP queue; implement your provider accordingly.
    var featuresProvider: (() -> FeaturePacketSnapshot)?
    var interventionsProvider: (() -> [String])?

    private let controlsLock = NSLock()
    private var controlsMode: Int = 0
    private var controlsButtons = Buttons(jolt: false, clear: false)
    private let manifests = ManifestCatalog.shared
    private var lastResolvedOutputMode: Int?
    private var picksFallbackLoggedForMode: Int?
    private var forceSocketTransport: Bool = false
    private var logReplayMode: Bool = false
    private var logInputSource: FrameInputSource = .live

    // MARK: - Config

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let hostString: String
    private let portValue: UInt16
    private let queue = DispatchQueue(label: "tub.ml.udp", qos: .userInitiated)

    // MARK: - Networking

    private var conn: NWConnection?

    // MARK: - JSON enc/dec

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(host: String = "127.0.0.1", port: UInt16 = 9910) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.hostString = host
        self.portValue = port
        start()
    }

    deinit {
        conn?.cancel()
        trainingLogSession?.close()
    }

    // MARK: - Controls

    func setMode(_ mode: Int) {
        controlsLock.lock(); defer { controlsLock.unlock() }
        controlsMode = max(0, min(10, mode))
    }

    /// Momentary: consumed on the next send tick.
    func pulseJolt() {
        controlsLock.lock(); defer { controlsLock.unlock() }
        controlsButtons = Buttons(jolt: true, clear: controlsButtons.clear)
    }

    /// Momentary: consumed on the next send tick.
    func pulseClear() {
        controlsLock.lock(); defer { controlsLock.unlock() }
        controlsButtons = Buttons(jolt: controlsButtons.jolt, clear: true)
    }

    func setHumanLabel(_ newLabel: HumanLabel?) {
        var oldLabel: HumanLabel?
        var changed = false
        labelLock.lock()
        oldLabel = labelState
        if oldLabel != newLabel {
            labelState = newLabel
            changed = true
        }
        labelLock.unlock()

        guard changed else { return }
        DispatchQueue.main.async {
            self.currentLabel = newLabel
        }
        trainingLogSession?.appendLabelChange(from: oldLabel, to: newLabel)
    }

    private func snapshotControlsAndConsumeMomentaries() -> (mode: Int, buttons: Buttons) {
        controlsLock.lock(); defer { controlsLock.unlock() }
        let m = controlsMode
        let b = controlsButtons
        controlsButtons = Buttons(jolt: false, clear: false)
        return (m, b)
    }

    // MARK: - Public API

    func startLoop(
        recordInputAudio: Bool = false,
        replayMode: Bool = false,
        replayedSessionId: String? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        previousTickNs = nil
        lastResolvedOutputMode = nil
        picksFallbackLoggedForMode = nil
        forceSocketTransport = false
        logReplayMode = replayMode
        logInputSource = replayMode ? .replayFile : .live
        frameIndex = 0
        sessionId = "session_\(nowMs())"
        activeSessionId = sessionId

        do {
            let bundleBuild = try RunBundleFactory.create()
            activeBundle = bundleBuild.bundle
            bundlePath = bundleBuild.fileURL.path
            print("[app] \(RunBundleFactory.startupBanner(bundle: bundleBuild.bundle))")
            print("[app] bundle file: \(bundleBuild.fileURL.path)")

            let logger = try TrainingLogSession(
                bundle: bundleBuild.bundle,
                sessionId: sessionId,
                recordInputAudioEnabled: recordInputAudio,
                inputAudioFormat: "caf",
                replayMode: replayMode,
                replayedSessionId: replayedSessionId
            )
            self.trainingLogSession = logger
            self.logPath = logger.frameURL.path
            self.eventLogPath = logger.eventURL.path
            self.sessionMetaPath = logger.metaURL.path
            self.sessionDirectoryPath = logger.sessionDirectoryURL.path
            self.inputAudioPath = logger.inputAudioURL?.path
        } catch {
            self.lastError = "trace init error: \(error)"
            self.trainingLogSession = nil
            self.activeBundle = nil
            self.logPath = nil
            self.eventLogPath = nil
            self.bundlePath = nil
            self.sessionMetaPath = nil
            self.sessionDirectoryPath = nil
            self.inputAudioPath = nil
            self.activeSessionId = nil
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))

        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.inFlight { return }
            self.sendTick()
        }

        self.timer = t
        t.resume()
    }

    func stopLoop() {
        isRunning = false
        timer?.cancel()
        timer = nil

        timeoutWork?.cancel()
        timeoutWork = nil
        inFlight = false
        activeRequestId = 0
        previousTickNs = nil
        lastResolvedOutputMode = nil
        picksFallbackLoggedForMode = nil
        forceSocketTransport = false
        logReplayMode = false
        logInputSource = .live

        DispatchQueue.main.async {
            self.lastTickIntervalMs = nil
        }

        trainingLogSession?.close()
        trainingLogSession = nil
        activeBundle = nil
    }

    func setLogInputSource(_ source: FrameInputSource, replayMode: Bool) {
        logInputSource = source
        logReplayMode = replayMode
        trainingLogSession?.setReplayContext(replayMode: replayMode, replayedSessionId: nil)
    }

    func setReplayContext(replayMode: Bool, replayedSessionId: String?) {
        logReplayMode = replayMode
        logInputSource = replayMode ? .replayFile : .live
        trainingLogSession?.setReplayContext(replayMode: replayMode, replayedSessionId: replayedSessionId)
    }

    func configureSessionInputAudio(sampleRate: Double, channels: Int, format: String, path: String?) {
        trainingLogSession?.setAudioCaptureInfo(
            sampleRate: sampleRate,
            channels: channels,
            inputAudioFormat: format,
            inputAudioPath: path
        )
        DispatchQueue.main.async {
            self.inputAudioPath = path
        }
    }

    func noteSessionAudioAlignment(hostTime: UInt64, sampleIndex: Int64) {
        trainingLogSession?.noteAudioAlignment(hostTime: hostTime, sampleIndex: sampleIndex)
    }

    func setReplayAudioMissing(_ missing: Bool) {
        trainingLogSession?.setReplayAudioMissing(missing)
    }

    func modelEndpoint() -> (host: String, port: UInt16) {
        (hostString, portValue)
    }

    func sendOnce(mode: Int, jolt: Bool = false, clear: Bool = false) {
        setMode(mode)
        if jolt { pulseJolt() }
        if clear { pulseClear() }
        sendTick()
    }

    func replayTrace(
        inputPath: String,
        fasterThanRealtime: Bool,
        speedMultiplier: Double = 8.0,
        bundleIdOverride: String? = nil,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        let url = URL(fileURLWithPath: inputPath)

        queue.async {
            do {
                let outURL = try TraceReplayer.replay(
                    inputURL: url,
                    host: self.hostString,
                    port: self.portValue,
                    fasterThanRealtime: fasterThanRealtime,
                    speedMultiplier: speedMultiplier,
                    timeoutMs: self.timeoutMs,
                    bundleIdOverride: bundleIdOverride
                )

                DispatchQueue.main.async {
                    self.lastError = nil
                    completion?(.success(outURL))
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "replay error: \(error)"
                    completion?(.failure(error))
                }
            }
        }
    }

    // MARK: - Connection lifecycle

    private func start() {
        let c = NWConnection(host: host, port: port, using: .udp)
        self.conn = c

        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.isReady = true
                    self.lastError = nil
                case .waiting(let err):
                    self.isReady = false
                    self.lastError = "UDP waiting: \(err)"
                case .failed(let err):
                    self.isReady = false
                    self.lastError = "UDP failed: \(err)"
                case .cancelled:
                    self.isReady = false
                default:
                    break
                }
            }
        }

        c.start(queue: queue)
    }

    // MARK: - Logging

    private func logFrame(
        input: ModelIn,
        output: ModelOut?,
        frameIndex: Int,
        requestId: Int,
        sendTsMs: Int,
        recvTsMs: Int?,
        latencyMs: Int?,
        timedOut: Bool,
        decodeError: String?,
        interventions: [String],
        featureSource: String,
        fallbackReason: String?,
        sentPacketJson: String?
    ) {
        guard let trainingLogSession, let bundle = activeBundle else { return }

        let diagnostics = TraceDiagnostics(
            requestId: requestId,
            sendTsMs: sendTsMs,
            recvTsMs: recvTsMs,
            roundTripMs: latencyMs,
            timedOut: timedOut,
            decodeError: decodeError,
            interventions: interventions
        )

        var extras = [String]()
        extras.append("feature_source:\(featureSource)")
        if let fallbackReason {
            extras.append("feature_fallback_reason:\(fallbackReason)")
        }
        if let sentPacketJson {
            extras.append("sent_packet_len:\(sentPacketJson.count)")
        }

        let allInterventions = interventions + extras
        let frameLine = TrainingFrameLogLine(
            tsMs: input.tsMs,
            frameIndex: frameIndex,
            sessionId: input.sessionId,
            frameHz: input.frameHz,
            replayMode: logReplayMode,
            inputSource: logInputSource,
            mode: input.mode,
            buttons: input.buttons,
            features: input.features,
            state: input.state,
            modelIn: input,
            modelOut: output,
            diagnostics: diagnostics,
            interventions: FrameInterventions.from(allInterventions),
            label: snapshotHumanLabel(),
            bundleId: bundle.bundleId
        )
        trainingLogSession.appendFrame(frameLine)
    }

    // MARK: - Tick send

    private func snapshotHumanLabel() -> HumanLabel? {
        labelLock.lock()
        defer { labelLock.unlock() }
        return labelState
    }

    private func sendTick() {
        let nowTickNs = DispatchTime.now().uptimeNanoseconds
        _ = noteTick(nowTickNs)

        let snap = snapshotControlsAndConsumeMomentaries()
        let mode = snap.mode
        let buttons = snap.buttons

        let featureFrame = featuresProvider?() ?? FeaturePacketSnapshot(
            features: makeDummyFeatures(),
            source: "dummy",
            fallbackReason: "no_features_provider"
        )
        let audioInterventions = interventionsProvider?() ?? []

        let inp = ModelIn(
            protocolVersion: 1,
            tsMs: nowMs(),
            sessionId: sessionId,
            frameHz: 10,
            mode: mode,
            buttons: buttons,
            features: featureFrame.features,
            state: HarnessState(overload: false, cooldown: 0.0, lastModeMs: 0)
        )

        inFlight = true
        frameIndex += 1
        let tickIndex = frameIndex
        activeRequestId += 1
        let requestId = activeRequestId

        let data: Data
        do {
            data = try encoder.encode(inp)
        } catch {
            DispatchQueue.main.async { self.lastError = "encode error: \(error)" }
            inFlight = false
            return
        }

        let sentPacketJson = String(data: data, encoding: .utf8)
        let sendTsMs = nowMs()

        if forceSocketTransport || conn == nil {
            if self.trySocketRecovery(
                payload: data,
                input: inp,
                mode: mode,
                buttons: buttons,
                tickIndex: tickIndex,
                requestId: requestId,
                sendTsMs: sendTsMs,
                audioInterventions: audioInterventions,
                featureFrame: featureFrame,
                sentPacketJson: sentPacketJson,
                interventionTag: "transport_socket"
            ) {
                inFlight = false
                return
            }
            forceSocketTransport = false
        }

        guard let conn else {
            inFlight = false
            DispatchQueue.main.async {
                self.lastError = "udp transport unavailable for \(self.hostString):\(self.portValue)"
            }
            return
        }

        timeoutWork?.cancel()
        let tw = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.inFlight, self.activeRequestId == requestId else { return }

            if self.trySocketRecovery(
                payload: data,
                input: inp,
                mode: mode,
                buttons: buttons,
                tickIndex: tickIndex,
                requestId: requestId,
                sendTsMs: sendTsMs,
                audioInterventions: audioInterventions,
                featureFrame: featureFrame,
                sentPacketJson: sentPacketJson
            ) {
                self.forceSocketTransport = true
                self.inFlight = false
                return
            }

            self.inFlight = false
            DispatchQueue.main.async {
                self.timeoutCount += 1
                self.lastError = "timeout (\(self.timeoutMs)ms) waiting for \(self.hostString):\(self.portValue)"
            }

            var interventions = ["timeout"]
            interventions.append(contentsOf: audioInterventions)
            if let reason = featureFrame.fallbackReason {
                interventions.append("feature_fallback:\(reason)")
            }

            self.logFrame(
                input: inp,
                output: nil,
                frameIndex: tickIndex,
                requestId: requestId,
                sendTsMs: sendTsMs,
                recvTsMs: nil,
                latencyMs: nil,
                timedOut: true,
                decodeError: nil,
                interventions: interventions,
                featureSource: featureFrame.source,
                fallbackReason: featureFrame.fallbackReason,
                sentPacketJson: sentPacketJson
            )
        }
        timeoutWork = tw
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: tw)

        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err {
                self.timeoutWork?.cancel()
                self.inFlight = false
                DispatchQueue.main.async { self.lastError = "send error: \(err)" }

                var interventions = ["send_error"]
                interventions.append(contentsOf: audioInterventions)
                if let reason = featureFrame.fallbackReason {
                    interventions.append("feature_fallback:\(reason)")
                }

                self.logFrame(
                    input: inp,
                    output: nil,
                    frameIndex: tickIndex,
                    requestId: requestId,
                    sendTsMs: sendTsMs,
                    recvTsMs: nil,
                    latencyMs: nil,
                    timedOut: true,
                    decodeError: err.localizedDescription,
                    interventions: interventions,
                    featureSource: featureFrame.source,
                    fallbackReason: featureFrame.fallbackReason,
                    sentPacketJson: sentPacketJson
                )
                return
            }

            DispatchQueue.main.async { self.sentCount += 1 }

            conn.receiveMessage { [weak self] content, _, _, recvErr in
                guard let self else { return }
                guard self.activeRequestId == requestId, self.inFlight else { return }

                self.timeoutWork?.cancel()
                self.inFlight = false

                if let recvErr {
                    DispatchQueue.main.async { self.lastError = "recv error: \(recvErr)" }

                    var interventions = ["recv_error"]
                    interventions.append(contentsOf: audioInterventions)
                    if let reason = featureFrame.fallbackReason {
                        interventions.append("feature_fallback:\(reason)")
                    }

                    self.logFrame(
                        input: inp,
                        output: nil,
                        frameIndex: tickIndex,
                        requestId: requestId,
                        sendTsMs: sendTsMs,
                        recvTsMs: nil,
                        latencyMs: nil,
                        timedOut: true,
                        decodeError: recvErr.localizedDescription,
                        interventions: interventions,
                        featureSource: featureFrame.source,
                        fallbackReason: featureFrame.fallbackReason,
                        sentPacketJson: sentPacketJson
                    )
                    return
                }
                guard let content else {
                    DispatchQueue.main.async { self.lastError = "recv empty" }

                    var interventions = ["recv_empty"]
                    interventions.append(contentsOf: audioInterventions)
                    if let reason = featureFrame.fallbackReason {
                        interventions.append("feature_fallback:\(reason)")
                    }

                    self.logFrame(
                        input: inp,
                        output: nil,
                        frameIndex: tickIndex,
                        requestId: requestId,
                        sendTsMs: sendTsMs,
                        recvTsMs: nil,
                        latencyMs: nil,
                        timedOut: true,
                        decodeError: "recv_empty",
                        interventions: interventions,
                        featureSource: featureFrame.source,
                        fallbackReason: featureFrame.fallbackReason,
                        sentPacketJson: sentPacketJson
                    )
                    return
                }

                let recvTsMs = nowMs()
                let latency = max(0, recvTsMs - sendTsMs)

                do {
                    let decoded = try self.decoder.decode(ModelOut.self, from: content)
                    let enforced = ModeContract.enforceIncoming(modelOut: decoded, currentMode: mode)
                    let manifestResolution = self.manifests.resolve(mode: enforced.0.mode, picks: enforced.0.picks)
                    let out = ModelOut(
                        protocolVersion: enforced.0.protocolVersion,
                        tsMs: enforced.0.tsMs,
                        mode: enforced.0.mode,
                        params: enforced.0.params,
                        picks: manifestResolution.picks,
                        flags: enforced.0.flags
                    )

                    var interventions = [String]()
                    interventions.append(contentsOf: audioInterventions)
                    if let reason = featureFrame.fallbackReason {
                        interventions.append("feature_fallback:\(reason)")
                    }
                    if !enforced.1.isEmpty {
                        interventions.append(contentsOf: enforced.1.map { "contract_violation:\($0)" })
                    }
                    interventions.append(contentsOf: self.pickResolutionInterventions(
                        mode: out.mode,
                        notes: manifestResolution.notes
                    ))

                    DispatchQueue.main.async {
                        self.lastOut = out
                        self.lastLatencyMs = latency
                        if !enforced.1.isEmpty {
                            self.lastError = "contract fallback for mode \(mode)"
                        } else if !manifestResolution.notes.isEmpty {
                            self.lastError = "pick fallback for mode \(mode)"
                        } else {
                            self.lastError = nil
                        }
                        self.recvCount += 1
                    }

                    self.onModelOut?(out, latency, buttons)

                    self.logFrame(
                        input: inp,
                        output: out,
                        frameIndex: tickIndex,
                        requestId: requestId,
                        sendTsMs: sendTsMs,
                        recvTsMs: recvTsMs,
                        latencyMs: latency,
                        timedOut: false,
                        decodeError: nil,
                        interventions: interventions,
                        featureSource: featureFrame.source,
                        fallbackReason: featureFrame.fallbackReason,
                        sentPacketJson: sentPacketJson
                    )
                } catch {
                    var fallback = ModeContract.protocolViolationFallback(mode: mode, tsMs: recvTsMs)
                    let manifestResolution = self.manifests.resolve(mode: fallback.mode, picks: fallback.picks)
                    fallback = ModelOut(
                        protocolVersion: fallback.protocolVersion,
                        tsMs: fallback.tsMs,
                        mode: fallback.mode,
                        params: fallback.params,
                        picks: manifestResolution.picks,
                        flags: fallback.flags
                    )
                    DispatchQueue.main.async {
                        self.lastOut = fallback
                        self.lastLatencyMs = latency
                        self.lastError = "decode/protocol fallback: \(error.localizedDescription)"
                    }

                    self.onModelOut?(fallback, latency, buttons)

                    var interventions = ["decode_error"]
                    interventions.append(contentsOf: audioInterventions)
                    if let reason = featureFrame.fallbackReason {
                        interventions.append("feature_fallback:\(reason)")
                    }
                    interventions.append("fallback_safe_defaults")
                    interventions.append(contentsOf: self.pickResolutionInterventions(
                        mode: fallback.mode,
                        notes: manifestResolution.notes
                    ))

                    self.logFrame(
                        input: inp,
                        output: fallback,
                        frameIndex: tickIndex,
                        requestId: requestId,
                        sendTsMs: sendTsMs,
                        recvTsMs: recvTsMs,
                        latencyMs: latency,
                        timedOut: false,
                        decodeError: error.localizedDescription,
                        interventions: interventions,
                        featureSource: featureFrame.source,
                        fallbackReason: featureFrame.fallbackReason,
                        sentPacketJson: sentPacketJson
                    )
                }
            }
        })
    }

    private enum SocketRoundTripError: Error {
        case invalidHost(String)
        case sendFailed(Int32)
        case recvFailed(Int32)
        case timeout
    }

    private func socketRoundTrip(payload: Data, timeoutMs: Int) throws -> Data {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw SocketRoundTripError.sendFailed(errno) }
        defer { Darwin.close(sock) }

        var timeout = timeval(tv_sec: __darwin_time_t(timeoutMs / 1000), tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(portValue).bigEndian

        let normalizedHost = hostString == "localhost" ? "127.0.0.1" : hostString
        let parsed = normalizedHost.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        guard parsed == 1 else { throw SocketRoundTripError.invalidHost(hostString) }

        let sendResult = payload.withUnsafeBytes { ptr in
            var copy = addr
            return withUnsafePointer(to: &copy) { sockPtr -> ssize_t in
                sockPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(sock, ptr.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult == payload.count else { throw SocketRoundTripError.sendFailed(errno) }

        var buffer = [UInt8](repeating: 0, count: 65_535)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received: ssize_t = buffer.withUnsafeMutableBytes { rawBuf in
            withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.recvfrom(sock, rawBuf.baseAddress, rawBuf.count, 0, sockPtr, &fromLen)
                }
            }
        }

        guard received >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw SocketRoundTripError.timeout
            }
            throw SocketRoundTripError.recvFailed(errno)
        }

        return Data(buffer.prefix(Int(received)))
    }

    private func trySocketRecovery(
        payload: Data,
        input: ModelIn,
        mode: Int,
        buttons: Buttons,
        tickIndex: Int,
        requestId: Int,
        sendTsMs: Int,
        audioInterventions: [String],
        featureFrame: FeaturePacketSnapshot,
        sentPacketJson: String?,
        interventionTag: String = "transport_recovery_socket"
    ) -> Bool {
        let recoveryTimeout = max(80, min(200, timeoutMs / 2))

        let content: Data
        do {
            content = try socketRoundTrip(payload: payload, timeoutMs: recoveryTimeout)
        } catch {
            return false
        }

        let recvTsMs = nowMs()
        let latency = max(0, recvTsMs - sendTsMs)

        do {
            let decoded = try self.decoder.decode(ModelOut.self, from: content)
            let enforced = ModeContract.enforceIncoming(modelOut: decoded, currentMode: mode)
            let manifestResolution = self.manifests.resolve(mode: enforced.0.mode, picks: enforced.0.picks)
            let out = ModelOut(
                protocolVersion: enforced.0.protocolVersion,
                tsMs: enforced.0.tsMs,
                mode: enforced.0.mode,
                params: enforced.0.params,
                picks: manifestResolution.picks,
                flags: enforced.0.flags
            )

            var interventions = [interventionTag]
            interventions.append(contentsOf: audioInterventions)
            if let reason = featureFrame.fallbackReason {
                interventions.append("feature_fallback:\(reason)")
            }
            if !enforced.1.isEmpty {
                interventions.append(contentsOf: enforced.1.map { "contract_violation:\($0)" })
            }
            interventions.append(contentsOf: self.pickResolutionInterventions(
                mode: out.mode,
                notes: manifestResolution.notes
            ))

            DispatchQueue.main.async {
                self.lastOut = out
                self.lastLatencyMs = latency
                if !enforced.1.isEmpty {
                    self.lastError = "contract fallback for mode \(mode)"
                } else if !manifestResolution.notes.isEmpty {
                    self.lastError = "pick fallback for mode \(mode)"
                } else {
                    self.lastError = nil
                }
                self.recvCount += 1
            }

            self.onModelOut?(out, latency, buttons)

            self.logFrame(
                input: input,
                output: out,
                frameIndex: tickIndex,
                requestId: requestId,
                sendTsMs: sendTsMs,
                recvTsMs: recvTsMs,
                latencyMs: latency,
                timedOut: false,
                decodeError: nil,
                interventions: interventions,
                featureSource: featureFrame.source,
                fallbackReason: featureFrame.fallbackReason,
                sentPacketJson: sentPacketJson
            )
            return true
        } catch {
            var fallback = ModeContract.protocolViolationFallback(mode: mode, tsMs: recvTsMs)
            let manifestResolution = self.manifests.resolve(mode: fallback.mode, picks: fallback.picks)
            fallback = ModelOut(
                protocolVersion: fallback.protocolVersion,
                tsMs: fallback.tsMs,
                mode: fallback.mode,
                params: fallback.params,
                picks: manifestResolution.picks,
                flags: fallback.flags
            )

            DispatchQueue.main.async {
                self.lastOut = fallback
                self.lastLatencyMs = latency
                self.lastError = "decode/protocol fallback: \(error.localizedDescription)"
            }

            self.onModelOut?(fallback, latency, buttons)

            var interventions = [interventionTag, "decode_error", "fallback_safe_defaults"]
            interventions.append(contentsOf: audioInterventions)
            if let reason = featureFrame.fallbackReason {
                interventions.append("feature_fallback:\(reason)")
            }
            interventions.append(contentsOf: self.pickResolutionInterventions(
                mode: fallback.mode,
                notes: manifestResolution.notes
            ))

            self.logFrame(
                input: input,
                output: fallback,
                frameIndex: tickIndex,
                requestId: requestId,
                sendTsMs: sendTsMs,
                recvTsMs: recvTsMs,
                latencyMs: latency,
                timedOut: false,
                decodeError: error.localizedDescription,
                interventions: interventions,
                featureSource: featureFrame.source,
                fallbackReason: featureFrame.fallbackReason,
                sentPacketJson: sentPacketJson
            )
            return true
        }
    }

    private func noteTick(_ nowNs: UInt64) -> Double? {
        defer { previousTickNs = nowNs }
        guard let prev = previousTickNs else { return nil }
        let intervalMs = Double(nowNs - prev) / 1_000_000.0
        DispatchQueue.main.async {
            self.lastTickIntervalMs = intervalMs
        }
        return intervalMs
    }

    private func makeDummyFeatures() -> Features {
        phase += 0.08
        let s = sin(phase)
        let loudness = -30.0 + 6.0 * s
        let onset = 1.0 + 2.0 * abs(sin(phase * 0.6))
        let centroid = 1200.0 + 900.0 * sin(phase * 0.35)
        let low = 0.30 + 0.10 * (0.5 + 0.5 * sin(phase * 0.9))
        let mid = 0.45 + 0.10 * (0.5 + 0.5 * sin(phase * 0.7 + 1.0))
        let high = max(0.05, 1.0 - (low + mid))
        let noisiness = 0.25 + 0.35 * (0.5 + 0.5 * sin(phase * 0.5 + 2.0))

        return Features(
            loudnessLufs: loudness,
            onsetRateHz: onset,
            specCentroidHz: centroid,
            bandLow: low,
            bandMid: mid,
            bandHigh: high,
            noisiness: noisiness,
            pitchHz: 220.0 + 44.0 * sin(phase * 0.22),
            pitchConf: 0.65,
            keyEstimate: "C",
            keyConf: 0.42
        )
    }

    private func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func pickResolutionInterventions(mode: Int, notes: [String]) -> [String] {
        if lastResolvedOutputMode != mode {
            lastResolvedOutputMode = mode
            picksFallbackLoggedForMode = nil
        }

        guard !notes.isEmpty else { return [] }
        guard picksFallbackLoggedForMode != mode else { return [] }

        picksFallbackLoggedForMode = mode
        return notes.map { "pick_resolution:\($0)" }
    }
}

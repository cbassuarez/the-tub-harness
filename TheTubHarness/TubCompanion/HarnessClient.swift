//
//  HarnessClient.swift
//  TubCompanion
//
//  Local network client for harness communication.
//  Uses NDJSON envelopes with one-line-per-message framing.
//

import Foundation
import Network
import Combine
import CoreGraphics
import Darwin

enum StageFeedState: String, Equatable {
    case live
    case degraded
    case standby

    var chipLabel: String {
        rawValue.uppercased()
    }
}

enum HarnessTransportPath: String, Equatable {
    case none
    case direct
    case relay

    var chipLabel: String {
        rawValue.uppercased()
    }
}

struct OperatorVectorLiveState: Equatable {
    let sessionId: String
    let param: Double
    let thought: Double
    let audio: Double
    let ttlSeconds: Double
    let receivedAt: Date
}

private struct HarnessRelayJoinRequest: Encodable {
    let code: String
    let sessionId: String
}

private struct HarnessRelayJoinResponse: Decodable {
    let status: String?
    let token: String?
    let wsURL: String?
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case token
        case wsURL = "ws_url"
        case expiresAt = "expires_at"
    }
}

class HarnessClient: NSObject, ObservableObject {
    private struct RelayCandidate: Equatable {
        let wsURL: URL
        let joinCode: String
        let expiresAt: Date?
    }

    struct HandshakeResponse: Decodable {
        let status: String
        let service: String?
        let protocolVersion: String?
        let audiencePort: Int?
        let hostHints: [String]?
        let transports: [String]?
        let relayJoinCode: String?
        let relayWsURL: String?
        let relaySessionExpiresAt: String?
        let timestamp: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case service
            case protocolVersion = "protocol"
            case audiencePort
            case hostHints
            case transports
            case relayJoinCode
            case relayWsURL
            case relaySessionExpiresAt
            case timestamp
            case message
        }
    }

    @Published var connectionState: HarnessConnectionState = .disconnected
    @Published var lastVisualOutput: VisualOutput?
    @Published var lastStageSnapshot: StageSnapshotPayload?
    @Published var descriptorSnapshot: DescriptorSnapshotPayload?
    @Published var lastHandshakeSummary: String?
    @Published var lastAudienceAck: String?
    @Published var stageFeedState: StageFeedState = .standby
    @Published var lastOperatorVectorState: OperatorVectorLiveState?
    @Published var lastOperatorActivity: OperatorActivityEvent?
    @Published var lastOperatorActivitySnapshot: OperatorActivitySnapshot?
    @Published var activeTransportPath: HarnessTransportPath = .none
    @Published var transportStatus: String = "IDLE"
    @Published var relayJoinCode: String?
    @Published var relaySessionExpiresAt: Date?
    @Published var networkFingerprint: String = "UNKNOWN"

    var onVisualUpdate: ((VisualOutput) -> Void)?
    var onStageSnapshot: ((StageSnapshotPayload) -> Void)?
    var onDescriptorSnapshot: ((DescriptorSnapshotPayload) -> Void)?

    private var nwConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.cbassuarez.thetub.harness-client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var receiveBuffer = Data()
    private var activeSessionId = "ios-\(UUID().uuidString.prefix(8))"
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var lastStageSnapshotAt: Date?
    private var lastVisualUpdateAt: Date?
    private var stageFeedTicker: AnyCancellable?
    private var reconnectTicker: AnyCancellable?
    private var relayHeartbeatTicker: AnyCancellable?
    private var preferredHost: String = "tub-harness.local"
    private var preferredPort: UInt16 = 9911
    private var autoReconnectEnabled = false
    private var bonjourBrowser: NWBrowser?
    private var bonjourDiscoveredEndpoint: NWEndpoint?
    private var relaySocket: URLSessionWebSocketTask?
    private var relaySession: URLSession?
    private var relayReceiveBuffer = Data()
    private var relayFallbackWorkItem: DispatchWorkItem?
    private var relayCandidate: RelayCandidate?
    private var configuredRelayWSURL: URL? = HarnessClient.resolveDefaultRelayWSURL()
    private var relayJoinCodeOverride: String?
    private var reconnectAttemptCount = 0
    private var nextReconnectEligibleAt: Date = .distantPast
    private var pathPreferenceByFingerprint: [String: String] = [:]
    private let transportPreferenceDefaultsKey = "HarnessTransportPathByNetworkFingerprintV1"
    private let relayFallbackDelay: TimeInterval = 1.2

    override init() {
        super.init()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        pathPreferenceByFingerprint = UserDefaults.standard.dictionary(forKey: transportPreferenceDefaultsKey) as? [String: String] ?? [:]
        stageFeedTicker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStageFeedState()
            }
        reconnectTicker = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.attemptAutoReconnectIfNeeded()
            }
        startBonjourDiscovery()
    }

    deinit {
        stageFeedTicker?.cancel()
        reconnectTicker?.cancel()
        relayHeartbeatTicker?.cancel()
        relaySocket?.cancel(with: .goingAway, reason: nil)
        relaySession?.invalidateAndCancel()
        bonjourBrowser?.cancel()
    }

    // MARK: - Bonjour Discovery

    func startBonjourDiscovery() {
        guard bonjourBrowser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_tubharness._tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed:
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.restartBonjourDiscovery()
                }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let result = results.first else {
                self.bonjourDiscoveredEndpoint = nil
                return
            }
            self.bonjourDiscoveredEndpoint = result.endpoint
            self.connectViaBonjourIfNeeded(result.endpoint)
        }

        browser.start(queue: queue)
        bonjourBrowser = browser
    }

    private func restartBonjourDiscovery() {
        bonjourBrowser?.cancel()
        bonjourBrowser = nil
        startBonjourDiscovery()
    }

    private func connectViaBonjourIfNeeded(_ endpoint: NWEndpoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.connectionState {
            case .connected:
                return
            default:
                break
            }
            self.connectToEndpoint(endpoint)
        }
    }

    func connectToEndpoint(_ endpoint: NWEndpoint) {
        networkFingerprint = resolveNetworkFingerprint()
        queue.async { [weak self] in
            guard let self else { return }

            self.cancelRelayFallback()
            self.cancelRelayConnection()
            self.connectTimeoutWorkItem?.cancel()
            self.nwConnection?.cancel()
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: params)
            self.nwConnection = connection
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.autoReconnectEnabled = true

            DispatchQueue.main.async {
                self.connectionState = .connecting
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.cancelConnectTimeout()
                        self.cancelRelayFallback()
                        self.cancelRelayConnection()
                        self.activeTransportPath = .direct
                        self.transportStatus = "DIRECT LINK READY"
                        self.recordSuccessfulPath(.direct)
                        self.resetReconnectBackoff()
                        self.connectionState = .connected
                        self.refreshStageFeedState()
                        self.startReceivingData()
                        self.sendSessionOpen()
                        self.queryState()
                    case .failed(let error):
                        self.cancelConnectTimeout()
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .error("Connection failed: \(error.localizedDescription)")
                        self.transportStatus = "DIRECT LINK FAILED"
                        self.markReconnectFailure()
                        self.refreshStageFeedState()
                    case .waiting:
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .connecting
                        self.refreshStageFeedState()
                    case .cancelled:
                        self.cancelConnectTimeout()
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .disconnected
                        self.activeTransportPath = .none
                        self.markReconnectFailure()
                        self.refreshStageFeedState()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: self.queue)
        }
    }

    func setSessionId(_ sessionId: String) {
        queue.async { [weak self] in
            self?.activeSessionId = sessionId
        }
    }

    func setRelayJoinCodeOverride(_ code: String?) {
        relayJoinCodeOverride = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if relayJoinCodeOverride?.isEmpty == true {
            relayJoinCodeOverride = nil
        }
        if let relayJoinCodeOverride {
            relayJoinCode = relayJoinCodeOverride
        }
        primeRelayCandidateFromOverrides()
    }

    func connectToHarness(host: String = "tub-harness.local", port: UInt16 = 9911) {
        let normalizedPreferredHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredHost = normalizedPreferredHost.isEmpty ? "tub-harness.local" : normalizedPreferredHost
        preferredPort = port
        autoReconnectEnabled = true
        networkFingerprint = resolveNetworkFingerprint()
        transportStatus = "LINKING..."

        queue.async { [weak self] in
            guard let self else { return }
            let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedHost.isEmpty else {
                DispatchQueue.main.async {
                    self.connectionState = .error("Invalid host address")
                }
                return
            }

            self.cancelRelayFallback()
            self.cancelRelayConnection()
            self.connectTimeoutWorkItem?.cancel()
            self.nwConnection?.cancel()
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(normalizedHost), port: NWEndpoint.Port(rawValue: port) ?? 9911)
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: params)
            self.nwConnection = connection
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.scheduleConnectTimeout(for: connection, host: normalizedHost, port: port)

            DispatchQueue.main.async {
                self.activeTransportPath = .none
                self.connectionState = .connecting
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.cancelConnectTimeout()
                        if self.activeTransportPath == .relay {
                            connection.cancel()
                            return
                        }
                        self.cancelRelayFallback()
                        self.cancelRelayConnection()
                        self.activeTransportPath = .direct
                        self.transportStatus = "DIRECT LINK READY"
                        self.recordSuccessfulPath(.direct)
                        self.resetReconnectBackoff()
                        self.connectionState = .connected
                        self.refreshStageFeedState()
                        self.startReceivingData()
                        self.sendSessionOpen()
                        self.queryState()
                    case .failed(let error):
                        self.cancelConnectTimeout()
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .error("Connection failed: \(error.localizedDescription)")
                        self.transportStatus = "DIRECT LINK FAILED"
                        self.markReconnectFailure()
                        self.scheduleRelayFallback(delay: 0.15, reason: "DIRECT FAILED")
                        self.refreshStageFeedState()
                    case .waiting:
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .connecting
                        self.refreshStageFeedState()
                    case .cancelled:
                        self.cancelConnectTimeout()
                        if self.activeTransportPath == .relay {
                            return
                        }
                        self.connectionState = .disconnected
                        self.activeTransportPath = .none
                        self.markReconnectFailure()
                        self.refreshStageFeedState()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: self.queue)
        }

        if relayJoinCodeOverride != nil {
            primeRelayCandidateFromOverrides()
            let preferredDelay = preferredPathForCurrentNetwork() == .relay ? 0.15 : 0.35
            scheduleRelayFallback(delay: preferredDelay, reason: "MANUAL CODE")
        }

        preflightHandshake(host: preferredHost, port: preferredPort) { [weak self] result in
            guard let self else { return }
            guard case .success(let payload) = result else { return }
            self.applyHandshakeMetadata(payload, requestedHost: preferredHost, requestedPort: preferredPort)
            let preferredDelay = self.preferredPathForCurrentNetwork() == .relay ? 0.2 : self.relayFallbackDelay
            self.scheduleRelayFallback(delay: preferredDelay, reason: "HYBRID FALLBACK")
        }
    }

    func shouldAttemptLocalDiscovery(for host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        if normalized == "localhost" || normalized == "127.0.0.1" { return true }
        if normalized.hasSuffix(".local") { return true }
        if !normalized.contains(".") { return true }
        return false
    }

    func discoverHarnessOnLocalNetwork(
        port: UInt16,
        completion: @escaping (Result<(host: String, payload: HandshakeResponse), Error>) -> Void
    ) {
        let candidates = localDiscoveryHosts()
        guard !candidates.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(DiscoveryError.noLocalIPv4))
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                let found = try await self.probeLocalNetwork(candidates: candidates, port: port)
                await MainActor.run {
                    self.lastHandshakeSummary = "LAN discovery OK: \(found.host):\(port)"
                    completion(.success(found))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func preflightHandshake(host: String, port: UInt16, completion: @escaping (Result<HandshakeResponse, Error>) -> Void) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        func finish(
            _ result: Result<HandshakeResponse, Error>,
            summary: String? = nil
        ) {
            DispatchQueue.main.async { [weak self] in
                if let summary {
                    self?.lastHandshakeSummary = summary
                }
                completion(result)
            }
        }

        guard !normalizedHost.isEmpty else {
            finish(.failure(NSError(
                domain: "HarnessClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Host is empty."]
            )))
            return
        }

        let parsedHostInput = URLComponents(string: normalizedHost)
        let explicitScheme = parsedHostInput?.scheme?.lowercased()
        let handshakeHost = parsedHostInput?.host ?? normalizedHost

        guard !handshakeHost.isEmpty else {
            finish(.failure(NSError(
                domain: "HarnessClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid handshake URL."]
            )))
            return
        }

        let hostLower = handshakeHost.lowercased()
        let hostSegments = hostLower.split(separator: ".")
        let isIPv4 = hostSegments.count == 4 && hostSegments.allSatisfy { segment in
            guard let value = Int(segment), (0...255).contains(value) else { return false }
            return true
        }
        let isLikelyLANHost = hostLower == "localhost" || hostLower.hasSuffix(".local") || isIPv4

        let candidateSchemes: [String]
        if let explicitScheme {
            candidateSchemes = [explicitScheme]
        } else if port == 443 {
            candidateSchemes = ["https", "http"]
        } else if isLikelyLANHost {
            candidateSchemes = ["http"]
        } else {
            candidateSchemes = ["http", "https"]
        }

        let candidateURLs = candidateSchemes.compactMap { scheme -> URL? in
            var components = URLComponents()
            components.scheme = scheme
            components.host = handshakeHost
            components.port = Int(port)
            components.path = "/handshake"
            return components.url
        }

        guard !candidateURLs.isEmpty else {
            finish(.failure(NSError(
                domain: "HarnessClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid handshake URL."]
            )))
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config)

        func attempt(_ index: Int, lastError: Error?) {
            guard index < candidateURLs.count else {
                let finalError = lastError ?? NSError(
                    domain: "HarnessClient",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Handshake unavailable."]
                )
                finish(.failure(finalError), summary: "Handshake unavailable: \(finalError.localizedDescription)")
                return
            }

            var request = URLRequest(url: candidateURLs[index])
            request.timeoutInterval = 2.0
            request.httpMethod = "GET"

            session.dataTask(with: request) { data, response, error in
                if let error {
                    attempt(index + 1, lastError: error)
                    return
                }

                guard
                    let http = response as? HTTPURLResponse,
                    let data
                else {
                    let err = NSError(
                        domain: "HarnessClient",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid handshake response."]
                    )
                    attempt(index + 1, lastError: err)
                    return
                }

                guard (200...299).contains(http.statusCode) else {
                    let err = NSError(
                        domain: "HarnessClient",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Handshake failed (\(http.statusCode))."]
                    )
                    attempt(index + 1, lastError: err)
                    return
                }

                DispatchQueue.main.async {
                    do {
                        let payload = try JSONDecoder().decode(HandshakeResponse.self, from: data)
                        let service = payload.service ?? "THE TUB"
                        let protocolToken = payload.protocolVersion ?? "ndjson"
                        self.applyHandshakeMetadata(payload, requestedHost: handshakeHost, requestedPort: port)
                        let transportToken: String
                        if let transports = payload.transports, !transports.isEmpty {
                            transportToken = transports.joined(separator: ",")
                        } else {
                            transportToken = "direct_tcp"
                        }
                        finish(
                            .success(payload),
                            summary: "Handshake OK: \(service) (\(protocolToken)) [\(transportToken)]"
                        )
                    } catch {
                        attempt(index + 1, lastError: error)
                    }
                }
            }.resume()
        }

        attempt(0, lastError: nil)
    }

    func sendPreferenceEvent(_ event: AudiencePreferenceEvent) {
        setSessionId(event.sessionId)

        switch event.eventType {
        case .dragTowardDescriptor:
            let point = event.position ?? .zero
            sendSteerVector(
                pointX: point.x,
                pointY: point.y,
                velocityX: 0,
                velocityY: 0,
                intensity: event.intensity,
                descriptorId: event.descriptorLabel,
                descriptorLabel: event.descriptorLabel,
                sessionId: event.sessionId
            )
        case .hold:
            sendHoldState(
                isHolding: true,
                durationSeconds: 0,
                intensity: event.intensity,
                sessionId: event.sessionId
            )
        case .release:
            sendHoldState(
                isHolding: false,
                durationSeconds: event.intensity,
                intensity: event.intensity,
                sessionId: event.sessionId
            )
        case .moreAction:
            sendIntensityNudge(direction: .more, intensity: event.intensity, sessionId: event.sessionId)
        case .lessAction:
            sendIntensityNudge(direction: .less, intensity: event.intensity, sessionId: event.sessionId)
        case .pairwiseCompare:
            let choice = event.descriptorLabel ?? "compare-choice"
            sendCompareChoice(
                pairId: "legacy-pair",
                leftDescriptorId: "left",
                rightDescriptorId: "right",
                chosenDescriptorId: choice,
                intensity: event.intensity,
                sessionId: event.sessionId
            )
        }
    }

    func sendSteerVector(
        pointX: CGFloat,
        pointY: CGFloat,
        velocityX: CGFloat,
        velocityY: CGFloat,
        intensity: Double,
        descriptorId: String?,
        descriptorLabel: String?,
        sessionId: String? = nil
    ) {
        let session = sessionId ?? activeSessionId
        let payload = SteerVectorPayload(
            pointX: Double(pointX),
            pointY: Double(pointY),
            velocityX: Double(velocityX),
            velocityY: Double(velocityY),
            intensity: max(0, min(1, intensity)),
            descriptorId: descriptorId,
            descriptorLabel: descriptorLabel
        )

        let envelope = AudienceEnvelope(
            kind: .steerVector,
            sessionId: session,
            steerVector: payload
        )
        sendEnvelope(envelope)
    }

    func sendHoldState(
        isHolding: Bool,
        durationSeconds: Double,
        intensity: Double,
        sessionId: String? = nil
    ) {
        let session = sessionId ?? activeSessionId
        let payload = HoldStatePayload(
            isHolding: isHolding,
            durationSeconds: max(0, durationSeconds),
            intensity: max(0, min(1, intensity))
        )
        let envelope = AudienceEnvelope(
            kind: .holdState,
            sessionId: session,
            holdState: payload
        )
        sendEnvelope(envelope)
    }

    func sendIntensityNudge(
        direction: IntensityNudgeDirection,
        intensity: Double = 1,
        sessionId: String? = nil
    ) {
        let session = sessionId ?? activeSessionId
        let payload = IntensityNudgePayload(
            direction: direction,
            intensity: max(0, min(1, intensity))
        )
        let envelope = AudienceEnvelope(
            kind: .intensityNudge,
            sessionId: session,
            intensityNudge: payload
        )
        sendEnvelope(envelope)
    }

    func sendCompareChoice(
        pairId: String,
        leftDescriptorId: String,
        rightDescriptorId: String,
        chosenDescriptorId: String,
        intensity: Double = 1,
        sessionId: String? = nil
    ) {
        let session = sessionId ?? activeSessionId
        let payload = CompareChoicePayload(
            pairId: pairId,
            leftDescriptorId: leftDescriptorId,
            rightDescriptorId: rightDescriptorId,
            chosenDescriptorId: chosenDescriptorId,
            intensity: max(0, min(1, intensity))
        )
        let envelope = AudienceEnvelope(
            kind: .compareChoice,
            sessionId: session,
            compareChoice: payload
        )
        sendEnvelope(envelope)
    }

    func sendOperatorVector(
        paramVector: Double,
        thoughtVector: Double,
        audioVector: Double,
        ttlSeconds: Double,
        sessionId: String? = nil
    ) {
        let session = sessionId ?? activeSessionId
        let payload = OperatorVectorPayload(
            paramVector: max(-1, min(1, paramVector)),
            thoughtVector: max(-1, min(1, thoughtVector)),
            audioVector: max(-1, min(1, audioVector)),
            ttlSeconds: max(0, ttlSeconds)
        )
        let envelope = AudienceEnvelope(
            kind: .operatorVector,
            sessionId: session,
            operatorVector: payload
        )
        sendEnvelope(envelope)
    }

    func sendOperatorActivity(_ event: OperatorActivityEvent) {
        let resolvedSession = event.sessionId.isEmpty ? activeSessionId : event.sessionId
        let envelope = AudienceEnvelope(
            kind: .operatorActivity,
            sessionId: resolvedSession,
            timestamp: event.timestamp,
            operatorActivity: event
        )
        sendEnvelope(envelope)
    }

    func queryState(sessionId: String? = nil) {
        let envelope = AudienceEnvelope(
            kind: .queryState,
            sessionId: sessionId ?? activeSessionId
        )
        sendEnvelope(envelope)
    }

    func uploadAudioContribution(_ contribution: AudienceAudioContribution) {
        let payload: Data
        do {
            payload = try encoder.encode(contribution)
        } catch {
            DispatchQueue.main.async {
                self.connectionState = .error("Upload failed: \(error.localizedDescription)")
            }
            return
        }
        sendRawPayload(payload, failurePrefix: "Upload failed")
    }

    func fetchQueuedContributions(completion: @escaping ([AudienceAudioContribution]) -> Void) {
        completion([])
    }

    func fetchApprovedContributions(completion: @escaping ([AudienceAudioContribution]) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            completion([])
        }
    }

    func downloadContribution(contributionId: String, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            completion(nil)
        }
    }

    private func sendSessionOpen() {
        let envelope = AudienceEnvelope(
            kind: .sessionOpen,
            sessionId: activeSessionId
        )
        sendEnvelope(envelope)
    }

    private func sendSessionClose() {
        let envelope = AudienceEnvelope(
            kind: .sessionClose,
            sessionId: activeSessionId
        )
        sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: AudienceEnvelope) {
        let payload: Data
        do {
            var line = try encoder.encode(envelope)
            line.append(0x0A)
            payload = line
        } catch {
            DispatchQueue.main.async {
                self.connectionState = .error("Encoding failed: \(error.localizedDescription)")
            }
            return
        }
        sendRawPayload(payload, failurePrefix: "Send failed")
    }

    private func startReceivingData() {
        queue.async { [weak self] in
            self?.receiveMessage()
        }
    }

    private func receiveMessage() {
        guard let connection = nwConnection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if !isComplete, error == nil {
                self.receiveMessage()
                return
            }

            if let error {
                DispatchQueue.main.async {
                    if self.activeTransportPath == .relay {
                        return
                    }
                    self.connectionState = .error("Receive failed: \(error.localizedDescription)")
                    self.transportStatus = "DIRECT RECEIVE FAILED"
                    self.markReconnectFailure()
                    self.scheduleRelayFallback(delay: 0.15, reason: "DIRECT RECEIVE")
                }
            }
        }
    }

    private func processReceiveBuffer() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)

            guard !line.isEmpty else { continue }
            handleIncomingLine(Data(line))
        }
    }

    private func handleIncomingLine(_ line: Data) {
        if let envelope = try? decoder.decode(AudienceEnvelope.self, from: line) {
            handleEnvelope(envelope)
            return
        }

        // Transitional compatibility: allow legacy visual payloads.
        if let visual = try? decoder.decode(VisualOutput.self, from: line) {
            publishVisual(visual)
            return
        }
    }

    private func handleEnvelope(_ envelope: AudienceEnvelope) {
        switch envelope.kind {
        case .descriptorSnapshot:
            guard let snapshot = envelope.descriptorSnapshot else { return }
            DispatchQueue.main.async {
                self.descriptorSnapshot = snapshot
                self.onDescriptorSnapshot?(snapshot)
            }
        case .stageSnapshot:
            guard let snapshot = envelope.stageSnapshot else { return }
            publishStageSnapshot(snapshot)
        case .visualUpdate:
            guard let visual = envelope.visualUpdate else { return }
            publishVisual(visual)
        case .error:
            let message = envelope.error?.message ?? "Unknown harness error"
            DispatchQueue.main.async {
                self.connectionState = .error(message)
                self.refreshStageFeedState()
            }
        case .ack:
            let message = envelope.ack?.message ?? "STATUS"
            DispatchQueue.main.async {
                self.lastAudienceAck = message
            }
        case .operatorVector:
            guard let vector = envelope.operatorVector else { return }
            let liveState = OperatorVectorLiveState(
                sessionId: envelope.sessionId,
                param: max(-1, min(1, vector.paramVector)),
                thought: max(-1, min(1, vector.thoughtVector)),
                audio: max(-1, min(1, vector.audioVector)),
                ttlSeconds: max(0, vector.ttlSeconds),
                receivedAt: Date()
            )
            DispatchQueue.main.async {
                self.lastOperatorVectorState = liveState
            }
        case .operatorActivity:
            guard let activity = envelope.operatorActivity else { return }
            DispatchQueue.main.async {
                self.lastOperatorActivity = activity
            }
        case .operatorActivitySnapshot:
            guard let snapshot = envelope.operatorActivitySnapshot else { return }
            DispatchQueue.main.async {
                self.lastOperatorActivitySnapshot = snapshot
            }
        default:
            break
        }
    }

    private func publishVisual(_ visual: VisualOutput) {
        DispatchQueue.main.async {
            self.lastVisualOutput = visual
            self.lastVisualUpdateAt = Date()
            self.onVisualUpdate?(visual)
            self.refreshStageFeedState()
        }
    }

    private func publishStageSnapshot(_ snapshot: StageSnapshotPayload) {
        DispatchQueue.main.async {
            self.lastStageSnapshot = snapshot
            self.lastStageSnapshotAt = Date()
            self.onStageSnapshot?(snapshot)
            self.refreshStageFeedState()
        }
    }

    func disconnect(manual: Bool = true) {
        if manual {
            autoReconnectEnabled = false
        }
        cancelConnectTimeout()
        cancelRelayFallback()
        sendSessionClose()
        nwConnection?.cancel()
        nwConnection = nil
        cancelRelayConnection()
        queue.async { [weak self] in
            self?.receiveBuffer.removeAll(keepingCapacity: true)
            self?.relayReceiveBuffer.removeAll(keepingCapacity: true)
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.activeTransportPath = .none
            self.transportStatus = "DISCONNECTED"
            self.lastOperatorVectorState = nil
            self.lastOperatorActivity = nil
            self.lastOperatorActivitySnapshot = nil
            self.refreshStageFeedState()
        }
    }

    private func attemptAutoReconnectIfNeeded() {
        guard autoReconnectEnabled else { return }
        guard Date() >= nextReconnectEligibleAt else { return }

        switch connectionState {
        case .connected, .connecting:
            return
        case .disconnected, .error:
            if preferredPathForCurrentNetwork() == .relay {
                connectToHarness(host: preferredHost, port: preferredPort)
            } else if let endpoint = bonjourDiscoveredEndpoint {
                connectToEndpoint(endpoint)
            } else {
                connectToHarness(host: preferredHost, port: preferredPort)
            }
        }
    }

    private enum DiscoveryError: LocalizedError {
        case noLocalIPv4
        case noHarnessFound

        var errorDescription: String? {
            switch self {
            case .noLocalIPv4:
                return "No local network interface is available."
            case .noHarnessFound:
                return "No harness responded on the local subnet."
            }
        }
    }

    private func scheduleConnectTimeout(
        for connection: NWConnection,
        host: String,
        port: UInt16,
        timeout: TimeInterval = 6.0
    ) {
        connectTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self else { return }
            guard let connection, self.nwConnection === connection else { return }
            if self.activeTransportPath == .relay {
                return
            }

            connection.cancel()
            self.nwConnection = nil
            self.receiveBuffer.removeAll(keepingCapacity: true)

            DispatchQueue.main.async {
                self.connectionState = .error("Connection timed out: \(host):\(port)")
                self.transportStatus = "DIRECT LINK TIMEOUT"
                self.markReconnectFailure()
                self.scheduleRelayFallback(delay: 0.1, reason: "DIRECT TIMEOUT")
            }
        }
        connectTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelConnectTimeout() {
        queue.async { [weak self] in
            self?.connectTimeoutWorkItem?.cancel()
            self?.connectTimeoutWorkItem = nil
        }
    }

    private func refreshStageFeedState(now: Date = Date()) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.refreshStageFeedState(now: now)
            }
            return
        }

        let connected: Bool
        if case .connected = connectionState {
            connected = true
        } else {
            connected = false
        }

        let nextState: StageFeedState
        if connected,
           let seenAt = lastStageSnapshotAt,
           now.timeIntervalSince(seenAt) <= 1.5 {
            nextState = .live
        } else if connected,
                  let seenAt = lastStageSnapshotAt,
                  now.timeIntervalSince(seenAt) <= 4.0 {
            nextState = .degraded
        } else if connected,
                  let seenAt = lastVisualUpdateAt,
                  now.timeIntervalSince(seenAt) <= 4.0 {
            nextState = .degraded
        } else {
            nextState = .standby
        }

        if stageFeedState != nextState {
            stageFeedState = nextState
        }
    }

    private func localDiscoveryHosts() -> [String] {
        var hosts = [String]()
        #if targetEnvironment(simulator)
        hosts.append("127.0.0.1")
        #endif

        let interfaces = activeIPv4Interfaces()
        guard let best = interfaces.min(by: { interfacePriority($0.name) < interfacePriority($1.name) }) else {
            return hosts
        }

        let octets = best.address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return hosts }

        let prefix = "\(octets[0]).\(octets[1]).\(octets[2])."
        for hostOctet in 1...254 where hostOctet != octets[3] {
            hosts.append("\(prefix)\(hostOctet)")
        }
        return hosts
    }

    private func activeIPv4Interfaces() -> [(name: String, address: String)] {
        var results: [(name: String, address: String)] = []
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
            return results
        }
        defer { freeifaddrs(addressPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor?.pointee {
            defer { cursor = current.ifa_next }

            guard
                let sa = current.ifa_addr,
                sa.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            let interfaceName = String(cString: current.ifa_name)
            if interfaceName == "lo0" || interfaceName.hasPrefix("awdl") || interfaceName.hasPrefix("utun") {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let value = String(cString: hostBuffer)
                if !value.isEmpty {
                    results.append((interfaceName, value))
                }
            }
        }

        return results
    }

    private func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name == "en1" { return 1 }
        if name.hasPrefix("bridge") { return 2 }
        if name.hasPrefix("pdp_ip") { return 3 }
        return 4
    }

    private func probeLocalNetwork(
        candidates: [String],
        port: UInt16
    ) async throws -> (host: String, payload: HandshakeResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.45
        config.timeoutIntervalForResource = 0.45
        let session = URLSession(configuration: config)

        let batchSize = 24
        var start = 0
        while start < candidates.count {
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            if let result = await firstReachableHarness(in: batch, port: port, session: session) {
                return result
            }
            start = end
        }

        throw DiscoveryError.noHarnessFound
    }

    private func firstReachableHarness(
        in hosts: [String],
        port: UInt16,
        session: URLSession
    ) async -> (host: String, payload: HandshakeResponse)? {
        await withTaskGroup(of: (host: String, payload: HandshakeResponse)?.self) { group in
            for host in hosts {
                group.addTask {
                    await Self.fetchHandshake(host: host, port: port, session: session)
                }
            }

            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func fetchHandshake(
        host: String,
        port: UInt16,
        session: URLSession
    ) async -> (host: String, payload: HandshakeResponse)? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/handshake"

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.45
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                return nil
            }

            let payload = try JSONDecoder().decode(HandshakeResponse.self, from: data)
            return (host, payload)
        } catch {
            return nil
        }
    }

    private func applyHandshakeMetadata(
        _ payload: HandshakeResponse,
        requestedHost: String,
        requestedPort: UInt16
    ) {
        if let wsURLString = payload.relayWsURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wsURLString.isEmpty,
           let wsURL = URL(string: wsURLString) {
            configuredRelayWSURL = wsURL
        }
        if let override = relayJoinCodeOverride, !override.isEmpty {
            relayJoinCode = override
        } else if let firstCode = payload.relayJoinCode?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !firstCode.isEmpty {
            relayJoinCode = firstCode.uppercased()
        } else {
            relayJoinCode = nil
        }

        relaySessionExpiresAt = parseISO8601Date(payload.relaySessionExpiresAt)

        if let candidate = relayCandidate(from: payload) {
            relayCandidate = candidate
            configuredRelayWSURL = candidate.wsURL
            if activeTransportPath != .direct {
                transportStatus = "RELAY READY / CODE \(candidate.joinCode.uppercased())"
            }
        } else {
            primeRelayCandidateFromOverrides()
            if relayJoinCodeOverride == nil {
                relayCandidate = nil
            }
        }

        let resolvedHost = resolvedHostFromHandshake(payload, requestedHost: requestedHost)
        let resolvedPort = payload.audiencePort.flatMap { UInt16(exactly: $0) } ?? requestedPort
        preferredHost = resolvedHost
        preferredPort = resolvedPort
    }

    private func relayCandidate(from payload: HandshakeResponse) -> RelayCandidate? {
        let chosenCode = relayJoinCodeOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let rawURL = payload.relayWsURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let wsURL = URL(string: rawURL),
            let code = (chosenCode?.isEmpty == false ? chosenCode : payload.relayJoinCode?.trimmingCharacters(in: .whitespacesAndNewlines)),
            !code.isEmpty
        else {
            return nil
        }

        let expiresAt = parseISO8601Date(payload.relaySessionExpiresAt)
        if let expiresAt, expiresAt <= Date() {
            return nil
        }
        return RelayCandidate(wsURL: wsURL, joinCode: code.uppercased(), expiresAt: expiresAt)
    }

    private func primeRelayCandidateFromOverrides() {
        guard let override = relayJoinCodeOverride, !override.isEmpty else { return }
        let wsURL = relayCandidate?.wsURL ?? configuredRelayWSURL
        guard let wsURL else { return }
        relayCandidate = RelayCandidate(
            wsURL: wsURL,
            joinCode: override.uppercased(),
            expiresAt: relayCandidate?.expiresAt
        )
    }

    private func resolvedHostFromHandshake(_ payload: HandshakeResponse, requestedHost: String) -> String {
        guard shouldAttemptLocalDiscovery(for: requestedHost) else {
            return requestedHost
        }
        let preferred = payload.hostHints?
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty {
            return preferred
        }
        return requestedHost
    }

    private func scheduleRelayFallback(delay: TimeInterval, reason: String) {
        guard relayCandidate != nil else { return }
        cancelRelayFallback()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .connected = self.connectionState, self.activeTransportPath == .direct {
                return
            }
            self.connectToRelay(reason: reason)
        }
        relayFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelRelayFallback() {
        relayFallbackWorkItem?.cancel()
        relayFallbackWorkItem = nil
    }

    private func connectToRelay(reason: String) {
        guard let candidate = relayCandidate else { return }
        if let expiresAt = candidate.expiresAt, expiresAt <= Date() {
            transportStatus = "RELAY CODE EXPIRED"
            return
        }
        if case .connected = connectionState, activeTransportPath == .direct {
            return
        }

        transportStatus = "PROMOTING RELAY / \(reason.uppercased())"
        connectionState = .connecting
        queue.async { [weak self] in
            guard let self else { return }
            self.nwConnection?.cancel()
            self.nwConnection = nil
            self.receiveBuffer.removeAll(keepingCapacity: true)
        }

        joinRelaySession(candidate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let wsURL):
                self.openRelaySocket(url: wsURL)
            case .failure(let error):
                DispatchQueue.main.async {
                    self.connectionState = .error("Relay connect failed: \(error.localizedDescription)")
                    self.activeTransportPath = .none
                    self.transportStatus = "RELAY FAILED"
                    self.markReconnectFailure()
                }
            }
        }
    }

    private func joinRelaySession(
        _ candidate: RelayCandidate,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let joinURL = relayJoinURL(from: candidate.wsURL) else {
            completion(.success(
                relaySocketURL(
                    base: candidate.wsURL,
                    token: nil,
                    code: candidate.joinCode
                )
            ))
            return
        }

        let body = HarnessRelayJoinRequest(code: candidate.joinCode, sessionId: activeSessionId)
        var request = URLRequest(url: joinURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            guard
                let http = response as? HTTPURLResponse,
                let data,
                (200...299).contains(http.statusCode)
            else {
                DispatchQueue.main.async {
                    completion(.success(
                        self.relaySocketURL(
                            base: candidate.wsURL,
                            token: nil,
                            code: candidate.joinCode
                        )
                    ))
                }
                return
            }

            DispatchQueue.main.async {
                if let payload = try? JSONDecoder().decode(HarnessRelayJoinResponse.self, from: data) {
                    let responseURL = payload.wsURL.flatMap(URL.init(string:))
                    let socketURL = self.relaySocketURL(
                        base: responseURL ?? candidate.wsURL,
                        token: payload.token,
                        code: candidate.joinCode
                    )
                    completion(.success(socketURL))
                    return
                }

                completion(.success(
                    self.relaySocketURL(
                        base: candidate.wsURL,
                        token: nil,
                        code: candidate.joinCode
                    )
                ))
            }
        }.resume()
    }

    private func openRelaySocket(url: URL) {
        queue.async { [weak self] in
            guard let self else { return }

            self.cancelRelayConnection()
            let session = URLSession(configuration: .ephemeral)
            let socket = session.webSocketTask(with: url)
            self.relaySession = session
            self.relaySocket = socket
            self.relayReceiveBuffer.removeAll(keepingCapacity: true)
            socket.resume()
            self.receiveRelayMessage()
            self.startRelayHeartbeat()

            DispatchQueue.main.async {
                self.activeTransportPath = .relay
                self.connectionState = .connected
                self.transportStatus = "RELAY LINK READY"
                self.recordSuccessfulPath(.relay)
                self.resetReconnectBackoff()
                self.refreshStageFeedState()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.sendSessionOpen()
                self.queryState()
            }
        }
    }

    private func receiveRelayMessage() {
        guard let socket = relaySocket else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.consumeRelayPayload(data)
                case .string(let text):
                    self.consumeRelayPayload(Data(text.utf8))
                @unknown default:
                    break
                }
                self.receiveRelayMessage()
            case .failure(let error):
                self.handleRelayFailure(error)
            }
        }
    }

    private func consumeRelayPayload(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.relayReceiveBuffer.append(data)
            self.processRelayReceiveBuffer()
        }
    }

    private func processRelayReceiveBuffer() {
        while let newline = relayReceiveBuffer.firstIndex(of: 0x0A) {
            let line = relayReceiveBuffer.prefix(upTo: newline)
            relayReceiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handleIncomingLine(Data(line))
        }

        // Relay frames may carry one JSON object without trailing newline.
        guard !relayReceiveBuffer.isEmpty else { return }
        if (try? decoder.decode(AudienceEnvelope.self, from: relayReceiveBuffer)) != nil {
            let line = relayReceiveBuffer
            relayReceiveBuffer.removeAll(keepingCapacity: true)
            handleIncomingLine(line)
            return
        }
        if let visual = try? decoder.decode(VisualOutput.self, from: relayReceiveBuffer) {
            relayReceiveBuffer.removeAll(keepingCapacity: true)
            publishVisual(visual)
        }
    }

    private func startRelayHeartbeat() {
        DispatchQueue.main.async {
            self.relayHeartbeatTicker?.cancel()
            self.relayHeartbeatTicker = Timer.publish(every: 5.0, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.sendRelayHeartbeat()
                }
        }
    }

    private func sendRelayHeartbeat() {
        guard activeTransportPath == .relay, let relaySocket else { return }
        relaySocket.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleRelayFailure(error)
            }
        }
        if let lastStageSnapshotAt, Date().timeIntervalSince(lastStageSnapshotAt) > 4 {
            queryState()
        }
    }

    private func handleRelayFailure(_ error: Error) {
        DispatchQueue.main.async {
            if self.activeTransportPath != .relay {
                return
            }
            self.cancelRelayConnection()
            self.connectionState = .error("Relay receive failed: \(error.localizedDescription)")
            self.transportStatus = "RELAY LINK LOST"
            self.markReconnectFailure()
            self.refreshStageFeedState()
        }
    }

    private func cancelRelayConnection() {
        relayHeartbeatTicker?.cancel()
        relayHeartbeatTicker = nil
        relaySocket?.cancel(with: .goingAway, reason: nil)
        relaySocket = nil
        relaySession?.invalidateAndCancel()
        relaySession = nil
        relayReceiveBuffer.removeAll(keepingCapacity: true)
    }

    private func sendRawPayload(_ payload: Data, failurePrefix: String) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.activeTransportPath == .relay, let relaySocket = self.relaySocket {
                relaySocket.send(.data(payload)) { error in
                    if let error {
                        DispatchQueue.main.async {
                            self.connectionState = .error("\(failurePrefix): \(error.localizedDescription)")
                        }
                    }
                }
                return
            }

            guard let connection = self.nwConnection else { return }
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    DispatchQueue.main.async {
                        self.connectionState = .error("\(failurePrefix): \(error.localizedDescription)")
                    }
                }
            })
        }
    }

    private func markReconnectFailure() {
        reconnectAttemptCount = min(reconnectAttemptCount + 1, 6)
        let exponent = max(0, reconnectAttemptCount - 1)
        let delay = min(20.0, pow(2.0, Double(exponent)))
        nextReconnectEligibleAt = Date().addingTimeInterval(delay)
    }

    private func resetReconnectBackoff() {
        reconnectAttemptCount = 0
        nextReconnectEligibleAt = .distantPast
    }

    private func recordSuccessfulPath(_ path: HarnessTransportPath) {
        guard networkFingerprint != "UNKNOWN" else { return }
        pathPreferenceByFingerprint[networkFingerprint] = path.rawValue
        UserDefaults.standard.set(pathPreferenceByFingerprint, forKey: transportPreferenceDefaultsKey)
    }

    private func preferredPathForCurrentNetwork() -> HarnessTransportPath {
        guard
            let raw = pathPreferenceByFingerprint[networkFingerprint],
            let parsed = HarnessTransportPath(rawValue: raw)
        else {
            return .direct
        }
        return parsed
    }

    private func resolveNetworkFingerprint() -> String {
        let interfaces = activeIPv4Interfaces()
        guard let best = interfaces.min(by: { interfacePriority($0.name) < interfacePriority($1.name) }) else {
            return "UNKNOWN"
        }
        let octets = best.address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return "\(best.name)-\(best.address)"
        }
        return "\(best.name)-\(octets[0]).\(octets[1]).\(octets[2]).x"
    }

    private func relayJoinURL(from wsURL: URL) -> URL? {
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "wss" {
            components.scheme = "https"
        } else if components.scheme == "ws" {
            components.scheme = "http"
        }
        components.path = "/v1/link/join"
        components.query = nil
        return components.url
    }

    private func relaySocketURL(base: URL, token: String?, code: String) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { $0.name == "token" || $0.name == "code" || $0.name == "session_id" })
        if let token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        queryItems.append(URLQueryItem(name: "code", value: code))
        queryItems.append(URLQueryItem(name: "session_id", value: activeSessionId))
        components.queryItems = queryItems
        return components.url ?? base
    }

    private func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = Self.iso8601Fractional.date(from: value) {
            return date
        }
        return Self.iso8601.date(from: value)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func resolveDefaultRelayWSURL() -> URL? {
        if let envValue = ProcessInfo.processInfo.environment["TUB_RELAY_WS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty,
           let envURL = URL(string: envValue) {
            return envURL
        }

        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "TUBRelayWSURL") as? String {
            let trimmed = plistValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let plistURL = URL(string: trimmed) {
                return plistURL
            }
        }
        return nil
    }

    // MARK: - Testing Hooks

    func injectEnvelopeForTesting(_ envelope: AudienceEnvelope) {
        handleEnvelope(envelope)
    }

    func ingestHandshakeForTesting(
        _ payload: HandshakeResponse,
        requestedHost: String = "tub-harness.local",
        requestedPort: UInt16 = 9911
    ) {
        applyHandshakeMetadata(payload, requestedHost: requestedHost, requestedPort: requestedPort)
    }

    func setNetworkFingerprintForTesting(_ value: String) {
        networkFingerprint = value
    }
}

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

class HarnessClient: NSObject, ObservableObject {
    struct HandshakeResponse: Decodable {
        let status: String
        let service: String?
        let protocolVersion: String?
        let audiencePort: Int?
        let hostHints: [String]?
        let timestamp: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case service
            case protocolVersion = "protocol"
            case audiencePort
            case hostHints
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

    override init() {
        super.init()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        stageFeedTicker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStageFeedState()
            }
    }

    deinit {
        stageFeedTicker?.cancel()
    }

    func setSessionId(_ sessionId: String) {
        queue.async { [weak self] in
            self?.activeSessionId = sessionId
        }
    }

    func connectToHarness(host: String = "tub-harness.local", port: UInt16 = 9911) {
        queue.async { [weak self] in
            guard let self else { return }
            let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedHost.isEmpty else {
                DispatchQueue.main.async {
                    self.connectionState = .error("Invalid host address")
                }
                return
            }

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
                self.connectionState = .connecting
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.cancelConnectTimeout()
                        self.connectionState = .connected
                        self.refreshStageFeedState()
                        self.startReceivingData()
                        self.sendSessionOpen()
                        self.queryState()
                    case .failed(let error):
                        self.cancelConnectTimeout()
                        self.connectionState = .error("Connection failed: \(error.localizedDescription)")
                        self.refreshStageFeedState()
                    case .waiting:
                        self.connectionState = .connecting
                        self.refreshStageFeedState()
                    case .cancelled:
                        self.cancelConnectTimeout()
                        self.connectionState = .disconnected
                        self.refreshStageFeedState()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: self.queue)
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
                        finish(
                            .success(payload),
                            summary: "Handshake OK: \(service) (\(protocolToken))"
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

        queue.async { [weak self] in
            guard
                let self,
                let connection = self.nwConnection
            else { return }

            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    DispatchQueue.main.async {
                        self.connectionState = .error("Upload failed: \(error.localizedDescription)")
                    }
                }
            })
        }
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

        queue.async { [weak self] in
            guard
                let self,
                let connection = self.nwConnection
            else { return }

            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    DispatchQueue.main.async {
                        self.connectionState = .error("Send failed: \(error.localizedDescription)")
                    }
                }
            })
        }
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
                    self.connectionState = .error("Receive failed: \(error.localizedDescription)")
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
            let message = envelope.ack?.message ?? "ACK"
            DispatchQueue.main.async {
                self.lastAudienceAck = message
            }
        case .operatorVector:
            // Server-authored operator vectors are currently not expected on companion.
            break
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

    func disconnect() {
        cancelConnectTimeout()
        sendSessionClose()
        nwConnection?.cancel()
        nwConnection = nil
        queue.async { [weak self] in
            self?.receiveBuffer.removeAll(keepingCapacity: true)
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.refreshStageFeedState()
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

            connection.cancel()
            self.nwConnection = nil
            self.receiveBuffer.removeAll(keepingCapacity: true)

            DispatchQueue.main.async {
                self.connectionState = .error("Connection timed out: \(host):\(port)")
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
}

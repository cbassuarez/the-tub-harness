//
//  AudienceSessionServer.swift
//  TheTubHarness
//
//  Harness-side server for accepting and managing iOS audience sessions.
//  Uses NDJSON envelope framing with compatibility fallbacks.
//

import Foundation
import Network
import Combine
import CoreGraphics
import Darwin

struct AudienceInfluenceTelemetry: Equatable {
    let sessionId: String
    let eventType: PreferenceEventType
    let descriptorLabel: String?
    let intensity: Double
    let totalEvents: Int
    let timestamp: Date

    var stageLine: String {
        let descriptorToken = descriptorLabel?.uppercased() ?? "GENERAL"
        let pct = Int((max(0, min(1, intensity)) * 100).rounded())
        return "AUDIENCE \(descriptorToken) \(pct)%"
    }

    var ackMessage: String {
        let descriptorToken = descriptorLabel?.uppercased() ?? "GENERAL"
        let pct = Int((max(0, min(1, intensity)) * 100).rounded())
        return "APPLIED \(eventType.rawValue.uppercased()) \(descriptorToken) \(pct)%"
    }
}

class AudienceSessionServer: ObservableObject {
    private struct OperatorVectorBroadcastSignature: Equatable {
        let sourceSessionId: String
        let paramBin: Int
        let thoughtBin: Int
        let audioBin: Int
        let ttlBin: Int
    }

    private struct RelaySessionCreateRequest: Encodable {
        let sessionId: String
        let ttlSeconds: Int

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case ttlSeconds = "ttl_seconds"
        }
    }

    private struct RelaySessionCreateResponse: Decodable {
        let status: String?
        let code: String?
        let wsURL: String?
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case code
            case wsURL = "ws_url"
            case expiresAt = "expires_at"
        }
    }

    @Published var activeSessions: [String: AudienceSessionState] = [:]
    @Published var claimStates: [String: AudienceClaimState] = [:]
    @Published private(set) var lastInfluenceTelemetry: AudienceInfluenceTelemetry?
    @Published private(set) var lastStageSnapshot: StageSnapshotPayload?

    private let listeningQueue = DispatchQueue(label: "com.cbassuarez.thetub.audience-server")
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var receiveBuffers: [String: Data] = [:]
    private var sessionConnectionKeys: [String: String] = [:]
    private var captureOutgoingEnvelopesForTesting = false
    private var capturedOutgoingEnvelopesForTesting: [AudienceEnvelope] = []
    private var descriptorRevision = 1
    private var listeningPort: UInt16 = 9911
    private var totalPreferenceEvents = 0
    private var sessionDescriptorLabelHints: [String: String] = [:]
    private var cachedStageSnapshot: StageSnapshotPayload?
    private var lastBroadcastStageSnapshot: StageSnapshotPayload?
    private var lastStageBroadcastAt: Date = .distantPast
    private var lastOperatorVectorBroadcastSignature: OperatorVectorBroadcastSignature?
    private let stageBroadcastInterval: TimeInterval = 1.0 / 30.0
    private let preferenceOverlay = AudiencePreferenceOverlay()
    private let operatorActivityMaxCount = 300
    private let operatorActivityMaxAge: TimeInterval = 5 * 60
    private var operatorActivityEvents: [OperatorActivityEvent] = []
    private var operatorActivityEventIds: Set<String> = []
    private var lastActivityEmissionByKey: [String: Date] = [:]
    private var relayWSURL: URL?
    private var relaySessionCreateURL: URL?
    private var relayJoinCode: String?
    private var relaySessionExpiresAt: Date?
    private var relayProvisionTask: URLSessionDataTask?
    private var relayLastProvisionFailureAt: Date = .distantPast
    private let relaySessionClientId = "harness-\(UUID().uuidString.prefix(8))"
    private let relaySessionTTLSeconds: TimeInterval = 10 * 60
    private let relaySessionRefreshLeadSeconds: TimeInterval = 45
    private let relayProvisionRetrySeconds: TimeInterval = 8

    private let descriptorFallback: [AudienceDescriptorState] = [
        .init(descriptorId: "dense", label: "DENSE", priority: 1.0, isVisible: true, systemStateId: nil),
        .init(descriptorId: "sparse", label: "SPARSE", priority: 0.94, isVisible: true, systemStateId: nil),
        .init(descriptorId: "aberrant", label: "ABERRANT", priority: 0.88, isVisible: true, systemStateId: nil),
        .init(descriptorId: "stable", label: "STABLE", priority: 0.82, isVisible: true, systemStateId: nil),
        .init(descriptorId: "warm", label: "WARM", priority: 0.76, isVisible: true, systemStateId: nil),
        .init(descriptorId: "cold", label: "COLD", priority: 0.7, isVisible: true, systemStateId: nil),
        .init(descriptorId: "drift", label: "DRIFT", priority: 0.64, isVisible: true, systemStateId: nil),
        .init(descriptorId: "strike", label: "STRIKE", priority: 0.58, isVisible: true, systemStateId: nil),
    ]

    var bodyClaimResolver: AudienceBodyClaimResolver?

    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        if let wsURLString = ProcessInfo.processInfo.environment["TUB_RELAY_WS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !wsURLString.isEmpty,
           let wsURL = URL(string: wsURLString) {
            relayWSURL = wsURL
            let configuredAPI = ProcessInfo.processInfo.environment["TUB_RELAY_API_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let configuredAPI, !configuredAPI.isEmpty {
                relaySessionCreateURL = URL(string: configuredAPI)
            } else {
                relaySessionCreateURL = Self.relaySessionCreateURL(from: wsURL)
            }
            let configuredCode = ProcessInfo.processInfo.environment["TUB_RELAY_JOIN_CODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if relaySessionCreateURL == nil {
                relayJoinCode = (configuredCode?.isEmpty == false) ? configuredCode?.uppercased() : Self.makeRelayJoinCode()
                relaySessionExpiresAt = Date().addingTimeInterval(relaySessionTTLSeconds)
            } else if let configuredCode, !configuredCode.isEmpty {
                relayJoinCode = configuredCode.uppercased()
                relaySessionExpiresAt = Date().addingTimeInterval(relaySessionTTLSeconds)
            } else {
                relayJoinCode = nil
                relaySessionExpiresAt = nil
            }
        }
    }

    func startListening(on port: UInt16 = 9911) {
        listeningQueue.async { [weak self] in
            guard let self else { return }
            guard self.listener == nil else { return }

            do {
                let params = NWParameters.tcp
                params.includePeerToPeer = true
                self.listener = try NWListener(using: params, on: .init(rawValue: port) ?? 9911)
                self.listeningPort = port
                self.listener?.service = NWListener.Service(
                    name: Host.current().localizedName ?? "the-tub-harness",
                    type: "_tubharness._tcp"
                )

                self.listener?.stateUpdateHandler = { state in
                    print("Audience listener state: \(state)")
                }

                self.listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleNewConnection(connection)
                }

                self.listener?.start(queue: self.listeningQueue)
                self.refreshRelaySessionIfNeeded(now: Date(), force: true)
                print("Audience session server listening on port \(port)")
            } catch {
                print("Failed to start audience server: \(error)")
            }
        }
    }

    func stopListening() {
        listeningQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.relayProvisionTask?.cancel()
            self.relayProvisionTask = nil
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
            self.sessionConnectionKeys.removeAll()
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionKey = UUID().uuidString

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveAudienceMessages(from: connection, connectionKey: connectionKey)
            case .failed, .cancelled:
                self.cleanupConnection(connectionKey: connectionKey)
            default:
                break
            }
        }

        listeningQueue.async { [weak self] in
            guard let self else { return }
            self.connections[connectionKey] = connection
            self.receiveBuffers[connectionKey] = Data()
            connection.start(queue: self.listeningQueue)
        }
    }

    private func cleanupConnection(connectionKey: String) {
        listeningQueue.async { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: connectionKey)
            self.receiveBuffers.removeValue(forKey: connectionKey)

            let detachedSessions = self.sessionConnectionKeys
                .filter { $0.value == connectionKey }
                .map(\.key)

            detachedSessions.forEach { sessionId in
                self.sessionConnectionKeys.removeValue(forKey: sessionId)
                self.preferenceOverlay.clearSession(sessionId)
                DispatchQueue.main.async {
                    self.activeSessions.removeValue(forKey: sessionId)
                    self.claimStates.removeValue(forKey: sessionId)
                }
            }
            self.broadcastCanonicalOperatorVectorIfChanged()
        }
    }

    private func receiveAudienceMessages(from connection: NWConnection, connectionKey: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.appendChunk(data, for: connectionKey)
            }

            if !isComplete, error == nil {
                self.receiveAudienceMessages(from: connection, connectionKey: connectionKey)
            }
        }
    }

    private func appendChunk(_ data: Data, for connectionKey: String) {
        var buffer = receiveBuffers[connectionKey] ?? Data()
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if line.isEmpty {
                continue
            }
            handleIncomingLine(Data(line), connectionKey: connectionKey)
        }

        receiveBuffers[connectionKey] = buffer
    }

    private func handleIncomingLine(_ line: Data, connectionKey: String) {
        if let requestLine = String(data: line, encoding: .utf8), requestLine.hasPrefix("GET ") {
            handleHTTPRequestLine(requestLine, connectionKey: connectionKey)
            return
        }

        if let envelope = try? decoder.decode(AudienceEnvelope.self, from: line) {
            handleEnvelope(envelope, connectionKey: connectionKey)
            return
        }

        // Transitional compatibility: legacy packet types are still accepted.
        if let event = try? decoder.decode(AudiencePreferenceEvent.self, from: line) {
            bind(sessionId: event.sessionId, to: connectionKey)
            recordPreferenceEvent(event)
            return
        }

        if let contribution = try? decoder.decode(AudienceAudioContribution.self, from: line) {
            bind(sessionId: contribution.sessionId, to: connectionKey)
            print("Received audio contribution from session \(contribution.sessionId)")
        }
    }

    private func handleHTTPRequestLine(_ requestLine: String, connectionKey: String) {
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            sendHTTPResponse(
                to: connectionKey,
                statusCode: 400,
                reason: "Bad Request",
                contentType: "application/json",
                body: Data(#"{"status":"error","message":"Malformed request line"}"#.utf8)
            )
            return
        }

        let path = String(components[1])
        switch path {
        case "/handshake":
            let payload = handshakePayload(now: Date())
            let body = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                ?? Data(#"{"status":"ok"}"#.utf8)
            sendHTTPResponse(
                to: connectionKey,
                statusCode: 200,
                reason: "OK",
                contentType: "application/json",
                body: body
            )
        case "/health":
            let body = Data(#"{"status":"ok"}"#.utf8)
            sendHTTPResponse(
                to: connectionKey,
                statusCode: 200,
                reason: "OK",
                contentType: "application/json",
                body: body
            )
        case "/status":
            let payload = statusPayload(now: Date())
            let body = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                ?? Data(#"{"status":"ok","isRunning":false}"#.utf8)
            sendHTTPResponse(
                to: connectionKey,
                statusCode: 200,
                reason: "OK",
                contentType: "application/json",
                body: body
            )
        default:
            sendHTTPResponse(
                to: connectionKey,
                statusCode: 404,
                reason: "Not Found",
                contentType: "application/json",
                body: Data(#"{"status":"error","message":"Not found"}"#.utf8)
            )
        }
    }

    private func localHostHints() -> [String] {
        var hints: [String] = []

        if let localizedName = Host.current().localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            let mdnsHost = localizedName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                + ".local"
            hints.append(mdnsHost)
        }

        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
            return Array(Set(hints)).sorted()
        }
        defer { freeifaddrs(addressPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor?.pointee {
            defer { cursor = current.ifa_next }

            guard
                let sa = current.ifa_addr,
                sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: current.ifa_name)
            if name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("utun") {
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
                    hints.append(value)
                }
            }
        }

        return Array(Set(hints)).sorted()
    }

    private func statusPayload(now: Date) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "status": "ok",
            "service": "tub-harness-audience",
            "audiencePort": Int(listeningPort),
            "timestamp": iso8601.string(from: now),
            "isRunning": false,
            "hasStageSnapshot": false
        ]

        if let snapshot = cachedStageSnapshot {
            payload["isRunning"] = snapshot.isRunning
            payload["hasStageSnapshot"] = true
            payload["mode"] = snapshot.mode
            payload["sceneId"] = snapshot.sceneId
            payload["thought"] = snapshot.thought
            payload["isWaiting"] = snapshot.isWaiting
            payload["snapshotTimestamp"] = iso8601.string(from: snapshot.timestamp)
            if let waitingReason = snapshot.waitingReason, !waitingReason.isEmpty {
                payload["waitingReason"] = waitingReason
            }
        }
        return payload
    }

    private func handshakePayload(now: Date) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var transports: [String] = ["direct_tcp"]
        var payload: [String: Any] = [
            "status": "ok",
            "service": "tub-harness-audience",
            "protocol": "ndjson-envelope-v1",
            "audiencePort": Int(listeningPort),
            "hostHints": localHostHints(),
            "timestamp": iso8601.string(from: now)
        ]

        if let relay = relayAnnouncement(now: now) {
            transports.append("relay_ws")
            payload["relayJoinCode"] = relay.code
            payload["relayWsURL"] = relay.wsURL.absoluteString
            payload["relaySessionExpiresAt"] = iso8601.string(from: relay.expiresAt)
        }
        payload["transports"] = transports
        return payload
    }

    private func relayAnnouncement(now: Date) -> (wsURL: URL, code: String, expiresAt: Date)? {
        guard let relayWSURL else {
            return nil
        }
        refreshRelaySessionIfNeeded(now: now)
        if relaySessionCreateURL == nil {
            if relayJoinCode == nil {
                relayJoinCode = Self.makeRelayJoinCode()
            }
            if relaySessionExpiresAt == nil || relaySessionExpiresAt! <= now {
                relaySessionExpiresAt = now.addingTimeInterval(relaySessionTTLSeconds)
                relayJoinCode = Self.makeRelayJoinCode()
            }
        }
        guard let relayJoinCode, let relaySessionExpiresAt, relaySessionExpiresAt > now else {
            return nil
        }
        return (relayWSURL, relayJoinCode, relaySessionExpiresAt)
    }

    private func refreshRelaySessionIfNeeded(now: Date, force: Bool = false) {
        guard relayWSURL != nil else { return }
        guard let relaySessionCreateURL else { return }

        let refreshCutoff = now.addingTimeInterval(relaySessionRefreshLeadSeconds)
        let hasFreshSession = relayJoinCode != nil && (relaySessionExpiresAt ?? .distantPast) > refreshCutoff
        if hasFreshSession, !force {
            return
        }
        if relayProvisionTask != nil {
            return
        }
        if !force, now.timeIntervalSince(relayLastProvisionFailureAt) < relayProvisionRetrySeconds {
            return
        }

        var request = URLRequest(url: relaySessionCreateURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let relayAPIKey = ProcessInfo.processInfo.environment["TUB_RELAY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !relayAPIKey.isEmpty {
            request.setValue("Bearer \(relayAPIKey)", forHTTPHeaderField: "Authorization")
        }
        let requestBody = RelaySessionCreateRequest(
            sessionId: relaySessionClientId,
            ttlSeconds: max(60, Int(relaySessionTTLSeconds.rounded()))
        )
        request.httpBody = try? JSONEncoder().encode(requestBody)

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.listeningQueue.async {
                self.relayProvisionTask = nil
                defer {
                    session.invalidateAndCancel()
                }

                if error != nil {
                    self.relayLastProvisionFailureAt = Date()
                    return
                }
                guard
                    let http = response as? HTTPURLResponse,
                    (200...299).contains(http.statusCode),
                    let data
                else {
                    self.relayLastProvisionFailureAt = Date()
                    return
                }
                guard
                    let payload = try? JSONDecoder().decode(RelaySessionCreateResponse.self, from: data),
                    let code = payload.code?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !code.isEmpty,
                    let wsURLRaw = payload.wsURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !wsURLRaw.isEmpty,
                    let wsURL = URL(string: wsURLRaw),
                    let expiresAt = self.parseISO8601Date(payload.expiresAt),
                    expiresAt > Date()
                else {
                    self.relayLastProvisionFailureAt = Date()
                    return
                }

                self.relayWSURL = wsURL
                self.relayJoinCode = code.uppercased()
                self.relaySessionExpiresAt = expiresAt
                self.relayLastProvisionFailureAt = .distantPast
            }
        }
        relayProvisionTask = task
        task.resume()
    }

    private static func relaySessionCreateURL(from relayWSURL: URL) -> URL? {
        guard var components = URLComponents(url: relayWSURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "wss" {
            components.scheme = "https"
        } else if components.scheme == "ws" {
            components.scheme = "http"
        }
        components.path = "/v1/link/sessions"
        components.query = nil
        return components.url
    }

    private func parseISO8601Date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let fractional = Self.iso8601WithFractional.date(from: raw) {
            return fractional
        }
        return Self.iso8601.date(from: raw)
    }

    private static func makeRelayJoinCode(length: Int = 6) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet.randomElement() ?? "X" })
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func sendHTTPResponse(
        to connectionKey: String,
        statusCode: Int,
        reason: String,
        contentType: String,
        body: Data
    ) {
        guard let connection = connections[connectionKey] else { return }

        var response = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var packet = Data(response.utf8)
        packet.append(body)

        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            connection.cancel()
            self.cleanupConnection(connectionKey: connectionKey)
        })
    }

    private func handleEnvelope(_ envelope: AudienceEnvelope, connectionKey: String) {
        let sessionId = envelope.sessionId.isEmpty ? "session-\(connectionKey.prefix(8))" : envelope.sessionId
        bind(sessionId: sessionId, to: connectionKey)

        switch envelope.kind {
        case .sessionOpen:
            sendDescriptorSnapshot(to: sessionId)
            if let stageSnapshot = cachedStageSnapshot {
                sendStageSnapshot(stageSnapshot, to: sessionId)
            }
            sendCanonicalOperatorVectorSnapshot(to: sessionId)
            sendOperatorActivitySnapshot(to: sessionId)
            sendAck(to: sessionId, message: "SESSION OPEN")
        case .sessionClose:
            cleanupSession(sessionId)
            broadcastCanonicalOperatorVectorIfChanged()
        case .queryState:
            sendDescriptorSnapshot(to: sessionId)
            sendOperatorActivitySnapshot(to: sessionId)
        case .steerVector:
            if let payload = envelope.steerVector {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)

                let activity = OperatorActivityEvent(
                    eventId: envelope.messageId,
                    sessionId: sessionId,
                    surface: .steer,
                    action: .steerVector,
                    label: canonicalDescriptorLabel(payload.descriptorLabel ?? payload.descriptorId),
                    intensity: payload.intensity,
                    position: CGPoint(x: payload.pointX, y: payload.pointY),
                    timestamp: envelope.timestamp
                )
                appendOperatorActivityEvent(activity)
            }
        case .holdState:
            if let payload = envelope.holdState {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)

                let activity = OperatorActivityEvent(
                    eventId: envelope.messageId,
                    sessionId: sessionId,
                    surface: .steer,
                    action: payload.isHolding ? .steerHoldStart : .steerHoldEnd,
                    intensity: payload.intensity,
                    timestamp: envelope.timestamp
                )
                appendOperatorActivityEvent(activity)
            }
        case .intensityNudge:
            if let payload = envelope.intensityNudge {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)

                let activity = OperatorActivityEvent(
                    eventId: envelope.messageId,
                    sessionId: sessionId,
                    surface: .steer,
                    action: payload.direction == .more ? .steerNudgeMore : .steerNudgeLess,
                    intensity: payload.intensity,
                    timestamp: envelope.timestamp
                )
                appendOperatorActivityEvent(activity)
            }
        case .compareChoice:
            if let payload = envelope.compareChoice {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)

                let activity = OperatorActivityEvent(
                    eventId: envelope.messageId,
                    sessionId: sessionId,
                    surface: .steer,
                    action: .steerCompareChoice,
                    label: canonicalDescriptorLabel(payload.chosenDescriptorId),
                    intensity: payload.intensity,
                    timestamp: envelope.timestamp
                )
                appendOperatorActivityEvent(activity)
            }
        case .operatorVector:
            if let payload = envelope.operatorVector {
                preferenceOverlay.recordOperatorVector(payload, for: sessionId)
                let summary = "OPERATOR VECTOR APPLIED P:\(formatSigned(payload.paramVector)) T:\(formatSigned(payload.thoughtVector)) A:\(formatSigned(payload.audioVector)) TTL:\(Int(payload.ttlSeconds))s"
                sendAck(to: sessionId, message: summary)
                broadcastCanonicalOperatorVectorIfChanged()
            }
        case .operatorActivity:
            if let activity = envelope.operatorActivity {
                let normalized = OperatorActivityEvent(
                    eventId: activity.eventId.isEmpty ? envelope.messageId : activity.eventId,
                    sessionId: activity.sessionId.isEmpty ? sessionId : activity.sessionId,
                    surface: activity.surface,
                    action: activity.action,
                    label: activity.label,
                    intensity: activity.intensity,
                    position: activity.position,
                    timestamp: activity.timestamp
                )
                if normalized.surface == .play {
                    appendOperatorActivityEvent(normalized)
                }
            }
        case .operatorActivitySnapshot:
            // Companion should not send snapshots.
            break
        case .descriptorSnapshot:
            // Companion is not authoritative for descriptors in this path.
            break
        case .stageSnapshot:
            // Companion should not send stage snapshots.
            break
        case .visualUpdate:
            // Companion should not send visual updates.
            break
        case .ack, .error:
            break
        }
    }

    private func bind(sessionId: String, to connectionKey: String) {
        sessionConnectionKeys[sessionId] = connectionKey
        DispatchQueue.main.async {
            if self.activeSessions[sessionId] == nil {
                self.activeSessions[sessionId] = AudienceSessionState(sessionId: sessionId, sessionType: .appCompanion)
            }
            if self.claimStates[sessionId] == nil {
                self.claimStates[sessionId] = AudienceClaimState(sessionId: sessionId)
            }
        }
    }

    private func cleanupSession(_ sessionId: String) {
        sessionConnectionKeys.removeValue(forKey: sessionId)
        sessionDescriptorLabelHints.removeValue(forKey: sessionId)
        preferenceOverlay.clearSession(sessionId)
        lastActivityEmissionByKey = lastActivityEmissionByKey.filter { !($0.key.hasPrefix("\(sessionId)|")) }
        DispatchQueue.main.async {
            self.activeSessions.removeValue(forKey: sessionId)
            self.claimStates.removeValue(forKey: sessionId)
        }
    }

    private func sendAck(to sessionId: String, message: String) {
        let payload = AudienceAckPayload(message: message)
        let envelope = AudienceEnvelope(kind: .ack, sessionId: sessionId, ack: payload)
        sendEnvelope(envelope, to: sessionId)
    }

    func broadcastAck(message: String) {
        let sessions = Array(sessionConnectionKeys.keys)
        for sessionId in sessions {
            sendAck(to: sessionId, message: message)
        }
    }

    func sendDescriptorSnapshot(to sessionId: String) {
        let payload = DescriptorSnapshotPayload(revision: descriptorRevision, descriptors: descriptorFallback)
        let envelope = AudienceEnvelope(kind: .descriptorSnapshot, sessionId: sessionId, descriptorSnapshot: payload)
        sendEnvelope(envelope, to: sessionId)
    }

    func publishDescriptorSnapshot(_ descriptors: [AudienceDescriptorState]) {
        descriptorRevision += 1
        let payload = DescriptorSnapshotPayload(revision: descriptorRevision, descriptors: descriptors)
        let sessions = Array(sessionConnectionKeys.keys)
        sessions.forEach { sessionId in
            let envelope = AudienceEnvelope(kind: .descriptorSnapshot, sessionId: sessionId, descriptorSnapshot: payload)
            sendEnvelope(envelope, to: sessionId)
        }
    }

    func sendVisualUpdate(_ visual: VisualOut, to sessionId: String) {
        let visualOutput = VisualOutput(
            sceneId: visual.sceneId,
            density: visual.density,
            cohesion: visual.cohesion,
            disruption: visual.disruption,
            thought: visual.thought
        )
        let envelope = AudienceEnvelope(kind: .visualUpdate, sessionId: sessionId, visualUpdate: visualOutput)
        sendEnvelope(envelope, to: sessionId)
    }

    func publishStageSnapshot(_ snapshot: StageSnapshotPayload) {
        DispatchQueue.main.async {
            self.lastStageSnapshot = snapshot
        }

        listeningQueue.async { [weak self] in
            guard let self else { return }
            self.cachedStageSnapshot = snapshot
            self.broadcastStageSnapshotIfDue(snapshot)
        }
    }

    private func broadcastStageSnapshotIfDue(_ snapshot: StageSnapshotPayload) {
        let now = Date()
        guard snapshot != lastBroadcastStageSnapshot else { return }
        guard now.timeIntervalSince(lastStageBroadcastAt) >= stageBroadcastInterval else { return }

        lastBroadcastStageSnapshot = snapshot
        lastStageBroadcastAt = now

        let sessions = Array(sessionConnectionKeys.keys)
        sessions.forEach { sendStageSnapshot(snapshot, to: $0) }
    }

    private func sendStageSnapshot(_ snapshot: StageSnapshotPayload, to sessionId: String) {
        let envelope = AudienceEnvelope(
            kind: .stageSnapshot,
            sessionId: sessionId,
            stageSnapshot: snapshot
        )
        sendEnvelope(envelope, to: sessionId)
    }

    private func sendCanonicalOperatorVectorSnapshot(to sessionId: String) {
        guard let state = preferenceOverlay.activeOperatorVectorState(activeSessions: overlayEligibleSessions()) else {
            return
        }
        let envelope = AudienceEnvelope(
            kind: .operatorVector,
            sessionId: state.sessionId,
            operatorVector: state.payload
        )
        sendEnvelope(envelope, to: sessionId)
    }

    private func broadcastCanonicalOperatorVectorIfChanged() {
        let maybeState = preferenceOverlay.activeOperatorVectorState(activeSessions: overlayEligibleSessions())
        let sessions = Array(sessionConnectionKeys.keys)
        guard !sessions.isEmpty else {
            lastOperatorVectorBroadcastSignature = nil
            return
        }

        guard let state = maybeState else {
            if lastOperatorVectorBroadcastSignature == nil {
                return
            }
            lastOperatorVectorBroadcastSignature = nil
            let neutral = OperatorVectorPayload(
                paramVector: 0,
                thoughtVector: 0,
                audioVector: 0,
                ttlSeconds: 0
            )
            sessions.forEach { destinationSessionId in
                let envelope = AudienceEnvelope(
                    kind: .operatorVector,
                    sessionId: "SYSTEM",
                    operatorVector: neutral
                )
                sendEnvelope(envelope, to: destinationSessionId)
            }
            return
        }

        let signature = operatorVectorBroadcastSignature(for: state)
        guard signature != lastOperatorVectorBroadcastSignature else { return }
        lastOperatorVectorBroadcastSignature = signature

        sessions.forEach { destinationSessionId in
            let envelope = AudienceEnvelope(
                kind: .operatorVector,
                sessionId: state.sessionId,
                operatorVector: state.payload
            )
            sendEnvelope(envelope, to: destinationSessionId)
        }
    }

    private func operatorVectorBroadcastSignature(for state: ActiveOperatorVectorState) -> OperatorVectorBroadcastSignature {
        OperatorVectorBroadcastSignature(
            sourceSessionId: state.sessionId,
            paramBin: quantizedBin(state.payload.paramVector, step: 0.01),
            thoughtBin: quantizedBin(state.payload.thoughtVector, step: 0.01),
            audioBin: quantizedBin(state.payload.audioVector, step: 0.01),
            ttlBin: Int(state.payload.ttlSeconds.rounded(.toNearestOrEven))
        )
    }

    private func overlayEligibleSessions() -> [String: AudienceSessionState] {
        var sessions: [String: AudienceSessionState] = [:]
        for sessionId in sessionConnectionKeys.keys {
            sessions[sessionId] = AudienceSessionState(sessionId: sessionId, sessionType: .appCompanion)
        }
        return sessions
    }

    private func quantizedBin(_ value: Double, step: Double) -> Int {
        guard step > 0 else { return 0 }
        return Int((value / step).rounded())
    }

    private func sendOperatorActivitySnapshot(to sessionId: String) {
        pruneOperatorActivityEvents(now: Date())
        let payload = OperatorActivitySnapshot(events: operatorActivityEvents, serverTimestamp: Date())
        let envelope = AudienceEnvelope(
            kind: .operatorActivitySnapshot,
            sessionId: "SYSTEM",
            operatorActivitySnapshot: payload
        )
        sendEnvelope(envelope, to: sessionId)
    }

    private func appendOperatorActivityEvent(_ event: OperatorActivityEvent) {
        let now = Date()
        pruneOperatorActivityEvents(now: now)

        if operatorActivityEventIds.contains(event.eventId) {
            return
        }

        if shouldThrottleOperatorActivity(event, now: now) {
            return
        }

        operatorActivityEvents.insert(event, at: 0)
        operatorActivityEventIds.insert(event.eventId)

        if operatorActivityEvents.count > operatorActivityMaxCount {
            operatorActivityEvents = Array(operatorActivityEvents.prefix(operatorActivityMaxCount))
            operatorActivityEventIds = Set(operatorActivityEvents.map(\.eventId))
        }

        let sessions = Array(sessionConnectionKeys.keys)
        sessions.forEach { destinationSessionId in
            let envelope = AudienceEnvelope(
                kind: .operatorActivity,
                sessionId: event.sessionId,
                timestamp: event.timestamp,
                operatorActivity: event
            )
            sendEnvelope(envelope, to: destinationSessionId)
        }
    }

    private func shouldThrottleOperatorActivity(_ event: OperatorActivityEvent, now: Date) -> Bool {
        let minimumInterval: TimeInterval
        switch event.action {
        case .steerVector:
            minimumInterval = 0.25
        case .playLongSweep:
            minimumInterval = 0.1
        default:
            minimumInterval = 0
        }

        guard minimumInterval > 0 else { return false }

        let key = "\(event.sessionId)|\(event.surface.rawValue)|\(event.action.rawValue)"
        if let lastEmission = lastActivityEmissionByKey[key], now.timeIntervalSince(lastEmission) < minimumInterval {
            return true
        }

        lastActivityEmissionByKey[key] = now
        return false
    }

    private func pruneOperatorActivityEvents(now: Date) {
        let cutoff = now.addingTimeInterval(-operatorActivityMaxAge)
        operatorActivityEvents = operatorActivityEvents.filter { $0.timestamp >= cutoff }
        operatorActivityEventIds = Set(operatorActivityEvents.map(\.eventId))
    }

    private func sendEnvelope(_ envelope: AudienceEnvelope, to sessionId: String) {
        if captureOutgoingEnvelopesForTesting {
            capturedOutgoingEnvelopesForTesting.append(envelope)
        }

        guard
            let connectionKey = sessionConnectionKeys[sessionId],
            let connection = connections[connectionKey]
        else { return }

        let payload: Data
        do {
            var encoded = try encoder.encode(envelope)
            encoded.append(0x0A)
            payload = encoded
        } catch {
            print("Failed to encode audience envelope: \(error)")
            return
        }

        listeningQueue.async {
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    print("Failed to send envelope to \(sessionId): \(error.localizedDescription)")
                }
            })
        }
    }

    @MainActor
    func applyAudienceOverlay(to modelOut: inout ModelOut) -> AudienceInfluenceTelemetry? {
        let telemetrySessionId = lastInfluenceTelemetry.flatMap { activeSessions[$0.sessionId] != nil ? $0.sessionId : nil }
        let operatorSessionId = preferenceOverlay.activeOperatorVectorSession(activeSessions: activeSessions)
        guard let sessionId = telemetrySessionId ?? operatorSessionId else {
            return nil
        }

        let overlayResult = preferenceOverlay.applyOverlay(to: &modelOut, for: sessionId, activeSessions: activeSessions)
        guard overlayResult != nil else { return nil }
        if let telemetry = lastInfluenceTelemetry, telemetry.sessionId == sessionId {
            return telemetry
        }
        return nil
    }

    private func recordPreferenceEvent(_ event: AudiencePreferenceEvent) {
        preferenceOverlay.recordPreferenceEvent(event)
        totalPreferenceEvents += 1

        let resolvedDescriptorLabel = descriptorLabelWithSessionFallback(
            event.descriptorLabel,
            sessionId: event.sessionId
        )

        let telemetry = AudienceInfluenceTelemetry(
            sessionId: event.sessionId,
            eventType: event.eventType,
            descriptorLabel: resolvedDescriptorLabel,
            intensity: event.intensity,
            totalEvents: totalPreferenceEvents,
            timestamp: event.timestamp
        )

        DispatchQueue.main.async {
            self.lastInfluenceTelemetry = telemetry
        }

        // Keep acknowledgements lightweight during continuous drag streams.
        let shouldAck = event.eventType != .dragTowardDescriptor || (totalPreferenceEvents % 6 == 0)
        if shouldAck {
            sendAck(to: event.sessionId, message: telemetry.ackMessage)
        }

        print("Received preference event from session \(event.sessionId): \(event.eventType)")

        // Resolve body claim for this session
        if let resolver = bodyClaimResolver,
           let session = activeSessions[event.sessionId],
           let claim = resolver.resolveActiveClaim(for: session, activeSessions: activeSessions) {
            resolver.updateSessionInteraction(event.sessionId)
            DispatchQueue.main.async {
                self.claimStates[event.sessionId] = claim
            }
        }
    }

    private func preferenceEvent(sessionId: String, from payload: SteerVectorPayload) -> AudiencePreferenceEvent {
        AudiencePreferenceEvent(
            sessionId: sessionId,
            eventType: .dragTowardDescriptor,
            descriptorLabel: canonicalDescriptorLabel(payload.descriptorLabel ?? payload.descriptorId),
            intensity: payload.intensity,
            position: CGPoint(x: payload.pointX, y: payload.pointY)
        )
    }

    private func preferenceEvent(sessionId: String, from payload: HoldStatePayload) -> AudiencePreferenceEvent {
        AudiencePreferenceEvent(
            sessionId: sessionId,
            eventType: payload.isHolding ? .hold : .release,
            intensity: payload.intensity
        )
    }

    private func preferenceEvent(sessionId: String, from payload: IntensityNudgePayload) -> AudiencePreferenceEvent {
        AudiencePreferenceEvent(
            sessionId: sessionId,
            eventType: payload.direction == .more ? .moreAction : .lessAction,
            intensity: payload.intensity
        )
    }

    private func preferenceEvent(sessionId: String, from payload: CompareChoicePayload) -> AudiencePreferenceEvent {
        AudiencePreferenceEvent(
            sessionId: sessionId,
            eventType: .pairwiseCompare,
            descriptorLabel: canonicalDescriptorLabel(payload.chosenDescriptorId),
            intensity: payload.intensity
        )
    }

    private func descriptorLabelWithSessionFallback(_ label: String?, sessionId: String) -> String? {
        if let canonical = canonicalDescriptorLabel(label) {
            sessionDescriptorLabelHints[sessionId] = canonical
            return canonical
        }
        return sessionDescriptorLabelHints[sessionId]
    }

    private func canonicalDescriptorLabel(_ label: String?) -> String? {
        guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let matched = descriptorFallback.first(where: {
            $0.descriptorId.caseInsensitiveCompare(raw) == .orderedSame ||
            $0.label.caseInsensitiveCompare(raw) == .orderedSame
        }) {
            return matched.label
        }

        return raw.uppercased()
    }

    private func formatSigned(_ value: Double) -> String {
        let clamped = max(-1, min(1, value))
        return String(format: "%+.2f", clamped)
    }

    // MARK: - Testing hooks

    func decodeEnvelopesForTesting(chunks: [Data]) -> [AudienceEnvelope] {
        var buffer = Data()
        var decoded: [AudienceEnvelope] = []

        for chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let envelope = try? decoder.decode(AudienceEnvelope.self, from: line) {
                    decoded.append(envelope)
                }
            }
        }
        return decoded
    }

    func routePreferenceForTesting(_ envelope: AudienceEnvelope) -> AudiencePreferenceEvent? {
        switch envelope.kind {
        case .steerVector:
            guard let payload = envelope.steerVector else { return nil }
            return preferenceEvent(sessionId: envelope.sessionId, from: payload)
        case .holdState:
            guard let payload = envelope.holdState else { return nil }
            return preferenceEvent(sessionId: envelope.sessionId, from: payload)
        case .intensityNudge:
            guard let payload = envelope.intensityNudge else { return nil }
            return preferenceEvent(sessionId: envelope.sessionId, from: payload)
        case .compareChoice:
            guard let payload = envelope.compareChoice else { return nil }
            return preferenceEvent(sessionId: envelope.sessionId, from: payload)
        default:
            return nil
        }
    }

    func enableOutgoingEnvelopeCaptureForTesting(_ enabled: Bool) {
        captureOutgoingEnvelopesForTesting = enabled
        if !enabled {
            capturedOutgoingEnvelopesForTesting.removeAll(keepingCapacity: false)
        }
    }

    func takeOutgoingEnvelopesForTesting() -> [AudienceEnvelope] {
        let envelopes = capturedOutgoingEnvelopesForTesting
        capturedOutgoingEnvelopesForTesting.removeAll(keepingCapacity: true)
        return envelopes
    }

    func simulateEnvelopeForTesting(_ envelope: AudienceEnvelope, connectionKey: String = "test-connection") {
        handleEnvelope(envelope, connectionKey: connectionKey)
    }

    func setRelayAnnouncementForTesting(wsURL: String?, joinCode: String?, expiresAt: Date?) {
        relayWSURL = wsURL.flatMap(URL.init(string:))
        relayJoinCode = joinCode
        relaySessionExpiresAt = expiresAt
    }

    func handshakePayloadDataForTesting(now: Date = Date()) -> Data {
        let payload = handshakePayload(now: now)
        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    }
}

extension StageSnapshotPayload {
    static func fromVideoStageSnapshot(_ snapshot: VideoStageSnapshot, now: Date = Date()) -> StageSnapshotPayload {
        let thoughtLog: [String]
        if snapshot.visual.thoughtLog.isEmpty {
            thoughtLog = [snapshot.visual.thought]
        } else {
            thoughtLog = Array(snapshot.visual.thoughtLog.prefix(5))
        }

        let paramLines = snapshot.params.prefix(6).map {
            "\($0.token.uppercased()) \($0.valueToken.uppercased())"
        }
        let pickLines = snapshot.picks.prefix(4).map {
            "\($0.token.uppercased()) \($0.resolvedToken.uppercased())"
        }
        let changeLines = snapshot.changes.suffix(6).map {
            "\($0.kind.rawValue.uppercased()) \($0.token.uppercased()) \($0.resolvedToken.uppercased())"
        }

        return StageSnapshotPayload(
            mode: snapshot.mode,
            sceneId: snapshot.visual.sceneId,
            thought: snapshot.visual.thought,
            thoughtLog: thoughtLog,
            density: snapshot.visual.density,
            cohesion: snapshot.visual.cohesion,
            disruption: snapshot.visual.disruption,
            isRunning: snapshot.isRunning,
            isWaiting: snapshot.isWaiting,
            waitingReason: snapshot.waitingReason,
            paramLines: paramLines,
            pickLines: pickLines,
            changeLines: changeLines,
            audio: StageAudioSummaryPayload(
                rms: snapshot.stageAudio.rms,
                transientFlux: snapshot.stageAudio.transientFlux,
                lowBand: snapshot.stageAudio.lowBand,
                midBand: snapshot.stageAudio.midBand,
                highBand: snapshot.stageAudio.highBand,
                peak: snapshot.stageAudio.peak,
                brightness: snapshot.stageAudio.brightness,
                overloadPulse: snapshot.stageAudio.overloadPulse
            ),
            joltHeld: snapshot.joltHeld,
            timestamp: snapshot.updatedAt ?? now
        )
    }
}

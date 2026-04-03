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
    @Published var activeSessions: [String: AudienceSessionState] = [:]
    @Published var claimStates: [String: AudienceClaimState] = [:]
    @Published private(set) var lastInfluenceTelemetry: AudienceInfluenceTelemetry?
    @Published private(set) var lastStageSnapshot: StageSnapshotPayload?

    private let listeningQueue = DispatchQueue(label: "com.cbassuarez.thetub.audience-server")
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var receiveBuffers: [String: Data] = [:]
    private var sessionConnectionKeys: [String: String] = [:]
    private var descriptorRevision = 1
    private var listeningPort: UInt16 = 9911
    private var totalPreferenceEvents = 0
    private var sessionDescriptorLabelHints: [String: String] = [:]
    private var cachedStageSnapshot: StageSnapshotPayload?
    private var lastBroadcastStageSnapshot: StageSnapshotPayload?
    private var lastStageBroadcastAt: Date = .distantPast
    private let stageBroadcastInterval: TimeInterval = 1.0 / 30.0
    private let preferenceOverlay = AudiencePreferenceOverlay()

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

    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
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
                DispatchQueue.main.async {
                    self.activeSessions.removeValue(forKey: sessionId)
                    self.claimStates.removeValue(forKey: sessionId)
                }
            }
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
            let iso8601 = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "status": "ok",
                "service": "tub-harness-audience",
                "protocol": "ndjson-envelope-v1",
                "audiencePort": Int(listeningPort),
                "hostHints": localHostHints(),
                "timestamp": iso8601.string(from: Date())
            ]
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
            sendAck(to: sessionId, message: "SESSION OPEN")
        case .sessionClose:
            cleanupSession(sessionId)
        case .queryState:
            sendDescriptorSnapshot(to: sessionId)
        case .steerVector:
            if let payload = envelope.steerVector {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)
            }
        case .holdState:
            if let payload = envelope.holdState {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)
            }
        case .intensityNudge:
            if let payload = envelope.intensityNudge {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)
            }
        case .compareChoice:
            if let payload = envelope.compareChoice {
                let event = preferenceEvent(sessionId: sessionId, from: payload)
                recordPreferenceEvent(event)
            }
        case .operatorVector:
            if let payload = envelope.operatorVector {
                preferenceOverlay.recordOperatorVector(payload, for: sessionId)
                let summary = "OPERATOR VECTOR APPLIED P:\(formatSigned(payload.paramVector)) T:\(formatSigned(payload.thoughtVector)) A:\(formatSigned(payload.audioVector)) TTL:\(Int(payload.ttlSeconds))s"
                sendAck(to: sessionId, message: summary)
            }
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

    private func sendEnvelope(_ envelope: AudienceEnvelope, to sessionId: String) {
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

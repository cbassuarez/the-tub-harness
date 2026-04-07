//
//  KinectUDPProvider.swift
//  TheTubHarness
//
//  Receives body detection data from the Python kinect_bridge over UDP.
//  Implements KinectBodyProvider for use with AudienceBodyClaimResolver.
//
//  Protocol: JSON packets on UDP port 9920
//    {"bodies": [{"bodyIndex":0, "x":960, "y":540, "depthZ":2.5, "confidence":0.9, "isTracked":true}, ...]}
//

import Foundation
import Network
import Combine

final class KinectUDPProvider: ObservableObject, KinectBodyProvider {
    @Published private(set) var isReceiving: Bool = false
    @Published private(set) var bodyCount: Int = 0

    private let port: UInt16
    private let queue = DispatchQueue(label: "tub.kinect.udp", qos: .userInitiated)
    private var listener: NWListener?
    private var running = false

    private let bodyLock = NSLock()
    private var bodies: [KinectBodyData] = []
    private var lastPacketTime: Date = .distantPast

    private var timeoutTimer: DispatchSourceTimer?
    private let timeoutInterval: TimeInterval = 2.0

    init(port: UInt16 = 9920) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        do {
            let params = NWParameters.udp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[KinectUDP] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[KinectUDP] Listening on port \(self?.port ?? 0)")
            case .failed(let error):
                print("[KinectUDP] Listener failed: \(error)")
                self?.running = false
            default:
                break
            }
        }

        listener?.start(queue: queue)
        startTimeoutMonitor()
    }

    func stop() {
        running = false
        timeoutTimer?.cancel()
        timeoutTimer = nil
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isReceiving = false
            self.bodyCount = 0
        }
    }

    deinit {
        stop()
    }

    // MARK: - KinectBodyProvider

    func getActiveBodies() -> [KinectBodyData] {
        bodyLock.lock()
        defer { bodyLock.unlock() }
        return bodies
    }

    func getNearestBody(to position: CGPoint) -> KinectBodyData? {
        let active = getActiveBodies()
        return active.min { a, b in
            let da = hypot(a.position.x - position.x, a.position.y - position.y)
            let db = hypot(b.position.x - position.x, b.position.y - position.y)
            return da < db
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receivePacket(from: connection)
    }

    private func receivePacket(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.running else { return }

            if let data, !data.isEmpty {
                self.parsePacket(data)
            }

            if error == nil {
                self.receivePacket(from: connection)
            }
        }
    }

    // MARK: - Packet parsing

    private struct BridgePacket: Decodable {
        let bodies: [BridgeBody]
    }

    private struct BridgeBody: Decodable {
        let bodyIndex: Int
        let x: Double
        let y: Double
        let depthZ: Double
        let confidence: Double
        let isTracked: Bool
    }

    func parsePacket(_ data: Data) {
        guard let packet = try? JSONDecoder().decode(BridgePacket.self, from: data) else {
            return
        }

        let parsed: [KinectBodyData] = packet.bodies.compactMap { b in
            guard b.isTracked else { return nil }
            return KinectBodyData(
                bodyIndex: b.bodyIndex,
                position: CGPoint(x: b.x, y: b.y),
                depthZ: b.depthZ,
                confidence: b.confidence,
                isTracked: true
            )
        }

        bodyLock.lock()
        bodies = parsed
        lastPacketTime = Date()
        bodyLock.unlock()

        DispatchQueue.main.async {
            self.isReceiving = true
            self.bodyCount = parsed.count
        }
    }

    // MARK: - Timeout monitor

    private func startTimeoutMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeoutInterval, repeating: timeoutInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.bodyLock.lock()
            let elapsed = Date().timeIntervalSince(self.lastPacketTime)
            self.bodyLock.unlock()

            if elapsed > self.timeoutInterval {
                DispatchQueue.main.async {
                    if self.isReceiving {
                        self.isReceiving = false
                        self.bodyCount = 0
                    }
                }
            }
        }
        timer.resume()
        timeoutTimer = timer
    }
}

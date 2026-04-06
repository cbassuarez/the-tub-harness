//
//  ExternalAudioRouteMonitor.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/31/26.
//


import AVFAudio
import Combine
import Foundation

@MainActor
final class ExternalAudioRouteMonitor: ObservableObject {
    @Published private(set) var isExternalAudioRouteActive = false
    @Published private(set) var isDebugOutputSimulated = false
    @Published private(set) var isCableRouteSimulated = false
    @Published private(set) var routeDescription = "No external audio route"
    @Published private(set) var lastSeenOutputPortTypes: [AVAudioSession.Port] = []

    private let session = AVAudioSession.sharedInstance()
    private var routeObserver: NSObjectProtocol?

    init() {
        refreshRouteState()

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRouteState()
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            configureSessionIfNeeded()
            refreshRouteState()
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    private func configureSessionIfNeeded() {
        do {
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowAirPlay]
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true, options: [])
        } catch {
            // Intentionally non-fatal; route inspection can still work in many cases.
        }
    }

    func refreshRouteState() {
        let outputs = session.currentRoute.outputs
        lastSeenOutputPortTypes = outputs.map(\.portType)

        let externalPorts: Set<AVAudioSession.Port> = [
            .headphones,
            .lineOut,
            .usbAudio
        ]

        let hasExternal = outputs.contains { externalPorts.contains($0.portType) }
        isExternalAudioRouteActive = hasExternal
        isCableRouteSimulated = false
        isDebugOutputSimulated = false

        if let firstExternal = outputs.first(where: { externalPorts.contains($0.portType) }) {
            routeDescription = firstExternal.portName
        } else if let first = outputs.first {
            routeDescription = first.portName
        } else {
            routeDescription = "No external audio route"
        }
    }
}

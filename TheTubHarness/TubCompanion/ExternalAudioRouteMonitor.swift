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

    #if DEBUG
    private func debugFlag(_ name: String, defaultValue: Bool) -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: name), index + 1 < args.count {
            let value = args[index + 1].uppercased()
            if value == "YES" || value == "TRUE" || value == "1" { return true }
            if value == "NO" || value == "FALSE" || value == "0" { return false }
        }

        if let raw = ProcessInfo.processInfo.environment[name]?.uppercased() {
            if raw == "YES" || raw == "TRUE" || raw == "1" { return true }
            if raw == "NO" || raw == "FALSE" || raw == "0" { return false }
        }
        return defaultValue
    }

    private var debugFakeCable: Bool {
        debugFlag("-DEBUG_FAKE_CABLE", defaultValue: false)
    }

    private var debugAllowSpeakerWithoutCable: Bool {
        debugFlag("-DEBUG_ALLOW_SPEAKER_WITHOUT_CABLE", defaultValue: true)
    }
    #endif

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
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowAirPlay]
            #if DEBUG
            if debugAllowSpeakerWithoutCable {
                options.insert(.defaultToSpeaker)
            }
            #endif
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

        #if DEBUG
        if debugAllowSpeakerWithoutCable {
            try? session.overrideOutputAudioPort(hasExternal ? .none : .speaker)
        }
        #endif

        #if DEBUG
        if debugFakeCable {
            isCableRouteSimulated = true
            isDebugOutputSimulated = false
            isExternalAudioRouteActive = true
            routeDescription = "Debug Simulated Cable"
            return
        }

        isCableRouteSimulated = false
        isDebugOutputSimulated = debugAllowSpeakerWithoutCable && !hasExternal
        #else
        isCableRouteSimulated = false
        isDebugOutputSimulated = false
        #endif

        if let firstExternal = outputs.first(where: { externalPorts.contains($0.portType) }) {
            routeDescription = firstExternal.portName
        } else if let first = outputs.first {
            #if DEBUG
            if isDebugOutputSimulated {
                routeDescription = "\(first.portName) (Debug Simulated Output)"
            } else {
                routeDescription = first.portName
            }
            #else
            routeDescription = first.portName
            #endif
        } else {
            routeDescription = "No external audio route"
        }
    }
}

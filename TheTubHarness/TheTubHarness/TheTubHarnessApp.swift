//
//  TheTubHarnessApp.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import CoreData

private enum HarnessLaunchOptions {
    static func parseBoolean(arguments: [String], key: String) -> Bool? {
        guard let idx = arguments.firstIndex(of: key), idx + 1 < arguments.count else {
            return nil
        }
        let raw = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func parseString(arguments: [String], key: String) -> String? {
        guard let idx = arguments.firstIndex(of: key), idx + 1 < arguments.count else {
            return nil
        }
        let raw = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func parseRecordInputAudio(arguments: [String]) -> Bool? {
        parseBoolean(arguments: arguments, key: "--record-input-audio")
    }

    static func parseAutoStart(arguments: [String]) -> Bool? {
        parseBoolean(arguments: arguments, key: "--autostart")
    }

    static func parseMode(arguments: [String]) -> HarnessRunMode? {
        guard let idx = arguments.firstIndex(of: "--mode"), idx + 1 < arguments.count else {
            return nil
        }
        return HarnessRunMode(rawValue: arguments[idx + 1].lowercased())
    }
}

@main
struct TheTubHarnessApp: App {
    let persistenceController = PersistenceController.shared
    private let defaultRecordInputAudio: Bool
    private let autoStartRun: Bool
    private let preferredInputDeviceHint: String?
    private let preferredOutputDeviceHint: String?
    @State private var selectedMode: HarnessRunMode?
    @StateObject private var audienceServer = AudienceSessionServer()

    init() {
        let args = ProcessInfo.processInfo.arguments
        defaultRecordInputAudio = HarnessLaunchOptions.parseRecordInputAudio(arguments: args) ?? false
        autoStartRun = HarnessLaunchOptions.parseAutoStart(arguments: args) ?? false
        preferredInputDeviceHint = HarnessLaunchOptions.parseString(arguments: args, key: "--input-hint")
        preferredOutputDeviceHint = HarnessLaunchOptions.parseString(arguments: args, key: "--output-hint")
        _selectedMode = State(initialValue: HarnessLaunchOptions.parseMode(arguments: args))
        BundledFontRegistrar.registerAll()
        ManifestCatalog.shared.logValidationSummary(context: "app")
        ReplayCLI.runIfRequested(arguments: args)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let mode = selectedMode {
                    ContentView(
                        runMode: mode,
                        defaultRecordInputAudio: defaultRecordInputAudio,
                        autoStartRun: autoStartRun,
                        launchInputDeviceHint: preferredInputDeviceHint,
                        launchOutputDeviceHint: preferredOutputDeviceHint
                    )
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                        .environmentObject(audienceServer)
                } else {
                    ModeChooserView { mode in
                        HarnessRunModeStorage.save(mode)
                        selectedMode = mode
                    }
                    .environmentObject(audienceServer)
                }
            }
            .onAppear {
                audienceServer.startListening(on: 9911)
            }
            .onDisappear {
                audienceServer.stopListening()
            }
        }
        .commands {
            CommandMenu("Harness") {
                if let mode = selectedMode {
                    Text("Mode: \(mode.title)")
                    Divider()
                }
                Button("Switch to Training Mode\u{2026}") {
                    relaunchInMode(.training)
                }
                .disabled(selectedMode == .training)
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Switch to Performance Mode\u{2026}") {
                    relaunchInMode(.performance)
                }
                .disabled(selectedMode == .performance)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private func relaunchInMode(_ mode: HarnessRunMode) {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--mode", mode.rawValue]
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

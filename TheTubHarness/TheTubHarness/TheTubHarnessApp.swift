//
//  TheTubHarnessApp.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import SwiftUI
import CoreData

private enum HarnessLaunchOptions {
    static func parseRecordInputAudio(arguments: [String]) -> Bool? {
        guard let idx = arguments.firstIndex(of: "--record-input-audio"), idx + 1 < arguments.count else {
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
    @State private var selectedMode: HarnessRunMode?

    init() {
        let args = ProcessInfo.processInfo.arguments
        defaultRecordInputAudio = HarnessLaunchOptions.parseRecordInputAudio(arguments: args) ?? false
        _selectedMode = State(initialValue: HarnessLaunchOptions.parseMode(arguments: args))
        BundledFontRegistrar.registerAll()
        ManifestCatalog.shared.logValidationSummary(context: "app")
        ReplayCLI.runIfRequested(arguments: args)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let mode = selectedMode {
                    ContentView(runMode: mode, defaultRecordInputAudio: defaultRecordInputAudio)
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                } else {
                    ModeChooserView { mode in
                        HarnessRunModeStorage.save(mode)
                        selectedMode = mode
                    }
                }
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

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
}

@main
struct TheTubHarnessApp: App {
    let persistenceController = PersistenceController.shared
    private let defaultRecordInputAudio: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        defaultRecordInputAudio = HarnessLaunchOptions.parseRecordInputAudio(arguments: args) ?? false
        ManifestCatalog.shared.logValidationSummary(context: "app")
        ReplayCLI.runIfRequested(arguments: args)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(defaultRecordInputAudio: defaultRecordInputAudio)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

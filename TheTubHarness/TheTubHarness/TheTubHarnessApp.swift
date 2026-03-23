//
//  TheTubHarnessApp.swift
//  TheTubHarness
//
//  Created by Sebastian Suarez-Solis on 3/23/26.
//

import SwiftUI
import CoreData

@main
struct TheTubHarnessApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

import AppKit
import SwiftUI

enum AppMetadata {
    static let bundleIdentifier = "com.local.MacResourceMonitor"
    static let minimumSystemVersion = "13.0"
}

@main
struct MacResourceMonitorApp: App {
    @StateObject private var store = MonitoringStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

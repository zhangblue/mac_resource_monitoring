import AppKit
import SwiftUI

enum AppMetadata {
    static let bundleIdentifier = "com.local.MacResourceMonitor"
    static let minimumSystemVersion = "13.0"
}

@main
struct MacResourceMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Mac 状态", systemImage: "gauge.with.dots.needle.67percent") {
            Text("Mac 状态")
            Button("退出应用") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}

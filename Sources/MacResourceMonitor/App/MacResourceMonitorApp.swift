import AppKit
import SwiftUI

enum AppMetadata {
    static let bundleIdentifier = "com.local.MacResourceMonitor"
    static let minimumSystemVersion = "13.0"
}

@main
struct MacResourceMonitorApp: App {
    @StateObject private var store = MonitoringStore()

    /// 构建菜单栏应用的唯一场景；应用启动后由 SwiftUI 调用，并持续绑定监控状态与详情面板。
    /// 技术上使用 @StateObject 保证 Store 在 Scene 重算时保持唯一，并通过 MenuBarExtra(.window) 创建无 Dock 主窗口的面板。
    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

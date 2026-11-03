import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: MonitoringStore

    /// 构建等宽菜单栏文本；SwiftUI 在快照或板块选择变化时调用。
    var body: some View {
        Text(MenuBarPresentation(snapshot: store.snapshot, selection: store.selection).text)
            .font(.system(.body, design: .monospaced))
            .monospacedDigit()
    }
}

import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: MonitoringStore

    var body: some View {
        Text(MenuBarPresentation(snapshot: store.snapshot).text)
            .font(.system(.body, design: .monospaced))
            .monospacedDigit()
    }
}

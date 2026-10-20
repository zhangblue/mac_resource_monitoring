import AppKit
import SwiftUI

@MainActor
final class DashboardNavigation: ObservableObject {
    @Published private(set) var showingSettings = false
    func openSettings() { showingSettings = true }
    func returnHome() { showingSettings = false }
}

struct DashboardPresentation {
    let selection: MetricSelection
    var visibleSections: [MetricSection] {
        MetricSection.allCases.filter { selection.contains($0) }
    }
    var cardRows: [[MetricSection]] {
        let cards = visibleSections.filter { $0 != .diskCapacity }
        return stride(from: 0, to: cards.count, by: 2).map {
            Array(cards[$0..<min($0 + 2, cards.count)])
        }
    }
    var isEmpty: Bool { visibleSections.isEmpty }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var store: MonitoringStore
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var navigation: DashboardNavigation

    init(store: MonitoringStore, navigation: DashboardNavigation? = nil) {
        self.store = store
        _navigation = StateObject(wrappedValue: navigation ?? DashboardNavigation())
    }

    private var presentation: DashboardPresentation { .init(selection: store.selection) }

    var body: some View {
        Group {
            if navigation.showingSettings {
                SettingsView(loginItemManager: loginItemManager, settings: store.settings) {
                    navigation.returnHome()
                }
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac 状态")
                    .font(.headline)
            }

            if presentation.isEmpty {
                Text("尚未选择监控板块。可在设置中重新开启。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityIdentifier("monitoring.empty")
            } else {
                // Eager rows keep the menu bar panel's measured height in sync
                // when sections are removed and restored while settings is open.
                ForEach(presentation.cardRows, id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row, id: \.self) { section in
                            card(for: section)
                        }
                        if row.count == 1 {
                            Spacer(minLength: 0).frame(maxWidth: .infinity)
                        }
                    }
                }
                if presentation.selection.contains(.diskCapacity) { diskCard }
            }
            HStack {
                Button("设置") { navigation.openSettings() }
                Spacer()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func card(for section: MetricSection) -> some View {
        switch section {
        case .cpu:
            MetricCardView(title: "CPU", value: percent(store.snapshot?.cpuUsage),
                           detail: MetricPresentation.status(for: store.snapshot?.cpuUsage, historyDuration: store.settings.historyDuration),
                           points: store.history.cpu.elements, sparklineStyle: .cpu,
                           historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval,
                           processes: store.snapshot?.processes.cpu, processStyle: .cpu)
        case .memory:
            MetricCardView(title: "内存", value: percent(store.snapshot?.memory.map(\.usage)),
                           detail: memoryDetail,
                           points: store.history.memory.elements, sparklineStyle: .memory,
                           historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval,
                           processes: store.snapshot?.processes.memory, processStyle: .memory)
        case .upload:
            MetricCardView(title: "上传", value: rate(store.snapshot?.network.value?.uploadBytesPerSecond),
                           detail: networkStatus(store.snapshot?.network.value?.uploadBytesPerSecond),
                           points: store.history.upload.elements, sparklineStyle: .upload,
                           historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval,
                           processes: store.snapshot?.processes.upload, processStyle: .upload)
        case .download:
            MetricCardView(title: "下载", value: rate(store.snapshot?.network.value?.downloadBytesPerSecond),
                           detail: networkStatus(store.snapshot?.network.value?.downloadBytesPerSecond),
                           points: store.history.download.elements, sparklineStyle: .download,
                           historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval,
                           processes: store.snapshot?.processes.download, processStyle: .download)
        case .chipTemperature:
            MetricCardView(title: "芯片温度", value: temperature,
                           detail: MetricPresentation.temperatureReadingStatus(for: store.snapshot?.temperature))
        case .fan:
            MetricCardView(title: "风扇", value: fan,
                           detail: sensorStatus(store.snapshot?.fan))
        case .diskCapacity:
            EmptyView() // Disk occupies the full-width row outside the grid.
        }
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("磁盘使用量")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !disk.status.isEmpty {
                Text(disk.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let fraction = disk.usedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("磁盘容量使用率")
                    .accessibilityValue(MetricFormatter.percent(fraction * 100))
            }
            Text(disk.capacityText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var disk: DiskPresentation { DiskPresentation(reading: store.snapshot?.disk) }

    private func percent(_ reading: Reading<Double>?) -> String {
        guard let value = reading?.value else { return "—" }
        return MetricFormatter.percent(value * 100)
    }

    private func rate(_ bytes: Double?) -> String {
        bytes.map(MetricFormatter.rate) ?? "—"
    }

    private var memoryDetail: String {
        guard let memory = store.snapshot?.memory.value else {
            return MetricPresentation.status(for: store.snapshot?.memory, historyDuration: store.settings.historyDuration)
        }
        return "已用 \(MetricFormatter.memory(memory.usedBytes)) / \(MetricFormatter.memory(memory.totalBytes)) · \(store.settings.historyDuration.recentLabel)"
    }

    private func networkStatus(_ bytes: Double?) -> String {
        guard store.snapshot?.network.value != nil else {
            return MetricPresentation.status(for: store.snapshot?.network, historyDuration: store.settings.historyDuration)
        }
        return bytes == nil ? "等待下一次采样" : store.settings.historyDuration.recentLabel
    }

    private var temperature: String {
        guard let value = store.snapshot?.temperature.value,
              value.isFinite else { return "—" }
        return String(format: "%.0f °C", value)
    }

    private var fan: String {
        guard let fan = store.snapshot?.fan.value else { return "—" }
        switch fan {
        case let .rpm(value): return MetricFormatter.rpm(value)
        case .fanless: return "无风扇"
        }
    }

    private func sensorStatus<Value>(_ reading: Reading<Value>?) -> String {
        guard let reading else { return "等待下一次采样" }
        return reading.isUnavailable ? "暂不可用" : ""
    }

}

import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: MonitoringStore
    @StateObject private var loginItemManager = LoginItemManager()
    @State private var showingSettings = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(loginItemManager: loginItemManager, settings: store.settings) {
                    showingSettings = false
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

            LazyVGrid(columns: columns, spacing: 12) {
                MetricCardView(title: "CPU", value: percent(store.snapshot?.cpuUsage),
                               detail: MetricPresentation.status(for: store.snapshot?.cpuUsage, historyDuration: store.settings.historyDuration),
                               points: store.history.cpu.elements, sparklineStyle: .cpu,
                               historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval)
                MetricCardView(title: "内存", value: percent(store.snapshot?.memory.map(\.usage)),
                               detail: memoryDetail,
                               points: store.history.memory.elements, sparklineStyle: .memory,
                               historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval)
                MetricCardView(title: "上传", value: rate(store.snapshot?.network.value?.uploadBytesPerSecond),
                               detail: networkStatus(store.snapshot?.network.value?.uploadBytesPerSecond),
                               points: store.history.upload.elements, sparklineStyle: .upload,
                               historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval)
                MetricCardView(title: "下载", value: rate(store.snapshot?.network.value?.downloadBytesPerSecond),
                               detail: networkStatus(store.snapshot?.network.value?.downloadBytesPerSecond),
                               points: store.history.download.elements, sparklineStyle: .download,
                               historyDuration: store.settings.historyDuration, refreshInterval: store.settings.refreshInterval)
                MetricCardView(title: "芯片温度", value: MetricPresentation.temperatureText(for: store.snapshot?.thermal),
                               detail: MetricPresentation.temperatureStatus(for: store.snapshot?.thermal))
                MetricCardView(title: "风扇", value: MetricPresentation.fanText(for: store.snapshot?.thermal),
                               detail: MetricPresentation.fanStatus(for: store.snapshot?.thermal))
            }
            diskCard
            HStack {
                Button("设置") { showingSettings = true }
                Spacer()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
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


}

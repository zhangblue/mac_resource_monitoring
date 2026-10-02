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
                               detail: MetricPresentation.status(for: store.snapshot?.cpuUsage),
                               points: store.history.cpu.elements, sparklineStyle: .cpu)
                MetricCardView(title: "内存", value: percent(store.snapshot?.memory.map(\.usage)),
                               detail: memoryDetail,
                               points: store.history.memory.elements, sparklineStyle: .memory)
                MetricCardView(title: "上传", value: rate(store.snapshot?.network.value?.uploadBytesPerSecond),
                               detail: networkStatus(store.snapshot?.network.value?.uploadBytesPerSecond),
                               points: store.history.upload.elements, sparklineStyle: .upload)
                MetricCardView(title: "下载", value: rate(store.snapshot?.network.value?.downloadBytesPerSecond),
                               detail: networkStatus(store.snapshot?.network.value?.downloadBytesPerSecond),
                               points: store.history.download.elements, sparklineStyle: .download)
                MetricCardView(title: "芯片温度", value: temperature,
                               detail: MetricPresentation.temperatureStatus(for: store.snapshot?.thermal))
                MetricCardView(title: "风扇", value: fan,
                               detail: thermalStatus(store.snapshot?.thermal.value?.fan != nil))
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
        guard let memory = store.snapshot?.memory.value else { return MetricPresentation.status(for: store.snapshot?.memory) }
        return "已用 \(MetricFormatter.memory(memory.usedBytes)) / \(MetricFormatter.memory(memory.totalBytes))"
    }

    private func networkStatus(_ bytes: Double?) -> String {
        guard store.snapshot?.network.value != nil else {
            return MetricPresentation.status(for: store.snapshot?.network)
        }
        return bytes == nil ? "等待下一次采样" : "最近五分钟"
    }

    private var temperature: String {
        guard let value = store.snapshot?.thermal.value?.chipTemperatureCelsius,
              value.isFinite else { return "—" }
        return String(format: "%.0f °C", value)
    }

    private var fan: String {
        guard let fan = store.snapshot?.thermal.value?.fan else { return "—" }
        switch fan {
        case let .rpm(value): return MetricFormatter.rpm(value)
        case .fanless: return "无风扇"
        }
    }

    private func thermalStatus(_ available: Bool) -> String {
        guard store.snapshot?.thermal.value != nil else {
            return MetricPresentation.status(for: store.snapshot?.thermal)
        }
        return available ? "" : "等待下一次采样"
    }

}

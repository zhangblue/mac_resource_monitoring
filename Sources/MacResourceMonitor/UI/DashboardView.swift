import AppKit
import SwiftUI

@MainActor
final class DashboardNavigation: ObservableObject {
    @Published private(set) var showingSettings = false
    /// 切换到设置页；用户点击详情面板“设置”按钮时调用。
    func openSettings() { showingSettings = true }
    /// 返回监控首页；用户点击设置页“返回首页”时调用。
    func returnHome() { showingSettings = false }
}

struct DashboardPresentation {
    let selection: MetricSelection
    /// 返回当前启用的板块顺序；详情面板计算布局时读取。
    var visibleSections: [MetricSection] {
        MetricSection.allCases.filter { selection.contains($0) }
    }
    /// 将非磁盘板块按每行两项分组；详情面板渲染卡片网格时读取。
    /// stride 每次切出最多两个枚举值，磁盘被排除后独占全宽；最后单项行由 Spacer 保持半宽。
    var cardRows: [[MetricSection]] {
        let cards = visibleSections.filter { $0 != .diskCapacity }
        return stride(from: 0, to: cards.count, by: 2).map {
            Array(cards[$0..<min($0 + 2, cards.count)])
        }
    }
    /// 判断是否没有任何启用板块；详情面板决定是否显示空状态时读取。
    var isEmpty: Bool { visibleSections.isEmpty }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var store: MonitoringStore
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var navigation: DashboardNavigation

    /// 组装监控存储和导航状态；菜单栏详情面板创建或界面测试注入导航器时调用。
    /// store 作为 ObservedObject 由外部持有，navigation 使用 StateObject 保证面板重绘时导航状态不被重建。
    init(store: MonitoringStore, navigation: DashboardNavigation? = nil) {
        self.store = store
        _navigation = StateObject(wrappedValue: navigation ?? DashboardNavigation())
    }

    /// 根据当前选择生成布局模型；每次 SwiftUI 刷新详情面板时读取。
    private var presentation: DashboardPresentation { .init(selection: store.selection) }

    /// 在监控首页与设置页之间切换；SwiftUI 渲染菜单栏详情窗口时调用。
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

    /// 构建监控首页和底部操作；未显示设置页时由 body 调用。
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
                // 立即构建各行，使设置打开期间增删板块时菜单栏面板高度能同步更新。
                ForEach(presentation.cardRows, id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row, id: \.self) { section in
                            // 按选择动态创建对应指标卡片，未选择板块不会进入展示层。
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

    /// 为指定板块构建对应指标卡片；详情面板遍历启用板块时调用。
    /// @ViewBuilder 让不同枚举分支保持静态 View 组合；所有数据来自 Store 已过滤快照，不在视图层触发采集。
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
            EmptyView() // 磁盘卡片独占全宽行，不在双列网格中重复创建。
        }
    }

    /// 构建仅展示容量的磁盘卡片；磁盘板块启用时由首页调用。
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

    /// 将最新磁盘读数转换为界面模型；磁盘卡片刷新时读取。
    /// 展示模型计算已用比例时处理总量为零并钳制上限，ProgressView 永远接收合法的 0...1 值。
    private var disk: DiskPresentation { DiskPresentation(reading: store.snapshot?.disk) }

    /// 将比例读数格式化为百分比；CPU 和内存卡片刷新时调用。
    private func percent(_ reading: Reading<Double>?) -> String {
        guard let value = reading?.value else { return "—" }
        return MetricFormatter.percent(value * 100)
    }

    /// 将可选字节速率格式化为文本；上传和下载卡片刷新时调用。
    private func rate(_ bytes: Double?) -> String {
        bytes.map(MetricFormatter.rate) ?? "—"
    }

    /// 生成内存容量与历史范围说明；内存卡片刷新时读取。
    private var memoryDetail: String {
        guard let memory = store.snapshot?.memory.value else {
            return MetricPresentation.status(for: store.snapshot?.memory, historyDuration: store.settings.historyDuration)
        }
        return "已用 \(MetricFormatter.memory(memory.usedBytes)) / \(MetricFormatter.memory(memory.totalBytes)) · \(store.settings.historyDuration.recentLabel)"
    }

    /// 生成网络采样状态；上传或下载卡片刷新时调用。
    private func networkStatus(_ bytes: Double?) -> String {
        guard store.snapshot?.network.value != nil else {
            return MetricPresentation.status(for: store.snapshot?.network, historyDuration: store.settings.historyDuration)
        }
        return bytes == nil ? "等待下一次采样" : store.settings.historyDuration.recentLabel
    }

    /// 格式化芯片温度；温度卡片刷新时读取。
    private var temperature: String {
        guard let value = store.snapshot?.temperature.value,
              value.isFinite else { return "—" }
        return String(format: "%.0f °C", value)
    }

    /// 格式化风扇状态或转速；风扇卡片刷新时读取。
    private var fan: String {
        guard let fan = store.snapshot?.fan.value else { return "—" }
        switch fan {
        case let .rpm(value): return MetricFormatter.rpm(value)
        case .fanless: return "无风扇"
        }
    }

    /// 将传感器 Reading 转换为简短状态；温度或风扇卡片刷新时调用。
    private func sensorStatus<Value>(_ reading: Reading<Value>?) -> String {
        guard let reading else { return "等待下一次采样" }
        return reading.isUnavailable ? "暂不可用" : ""
    }

}

import Combine
import CoreFoundation
import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5

    /// 使用秒数作为 SwiftUI 稳定标识；设置页枚举刷新选项时读取。
    var id: Int { rawValue }
    /// 返回刷新间隔中文标签；设置页和摘要展示时读取。
    var label: String { "\(rawValue) 秒" }
}

enum HistoryDuration: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    /// 使用秒数作为 SwiftUI 稳定标识；设置页枚举历史选项时读取。
    var id: Int { rawValue }
    /// 返回历史时长的简短标签；设置页分段选择器展示时读取。
    var label: String { "\(rawValue / 60) 分钟" }
    /// 返回带“最近”的历史范围说明；卡片状态和设置摘要展示时读取。
    var recentLabel: String { "最近 \(rawValue / 60) 分钟" }
}

enum MetricSection: String, CaseIterable, Sendable {
    case cpu, memory, upload, download, chipTemperature, fan, diskCapacity
}

struct MetricSelection: Equatable, Sendable {
    static let all = MetricSelection()
    private var selected: Set<MetricSection> = Set(MetricSection.allCases)

    /// 判断板块是否选中；界面渲染和引擎构建采样计划时调用。
    func contains(_ section: MetricSection) -> Bool { selected.contains(section) }
    /// 判断是否关闭全部板块；详情面板决定是否显示空状态时读取。
    var isEmpty: Bool { selected.isEmpty }

    /// 更新单个板块选择；设置开关变化或恢复持久化值时调用。
    /// Set 提供近似 O(1) 的成员增删，值类型语义让 Published 在整体替换后可靠触发界面更新。
    mutating func set(_ section: MetricSection, enabled: Bool) {
        if enabled {
            selected.insert(section)
        } else {
            selected.remove(section)
        }
    }
}

struct MonitoringConfiguration: Equatable, Sendable {
    var refreshInterval: RefreshInterval
    var historyDuration: HistoryDuration
    var selection: MetricSelection

    /// 创建完整监控配置；设置对象生成配置或测试构造引擎时调用。
    init(refreshInterval: RefreshInterval, historyDuration: HistoryDuration,
         selection: MetricSelection = .all) {
        self.refreshInterval = refreshInterval
        self.historyDuration = historyDuration
        self.selection = selection
    }
}

@MainActor
final class MonitoringSettings: ObservableObject {
    static let refreshIntervalKey = "monitoring.refreshIntervalSeconds"
    static let historyDurationKey = "monitoring.historyDurationSeconds"
    // rawValue 是持久化标识，修改界面文字时不得随意重命名。
    static let selectionKeys: [MetricSection: String] = Dictionary(uniqueKeysWithValues:
        MetricSection.allCases.map { ($0, "monitoring.section.\($0.rawValue)") })

    @Published private(set) var selection: MetricSelection

    /// 更新并持久化板块选择；设置界面的板块开关变化时调用。
    /// 每个板块使用独立稳定 UserDefaults 布尔键，修改一项不会重写或破坏其他选择。
    func set(_ section: MetricSection, enabled: Bool) {
        selection.set(section, enabled: enabled)
        defaults.set(enabled, forKey: Self.selectionKeys[section]!)
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Self.refreshIntervalKey) }
    }
    @Published var historyDuration: HistoryDuration {
        didSet { defaults.set(historyDuration.rawValue, forKey: Self.historyDurationKey) }
    }

    private let defaults: UserDefaults

    /// 从 UserDefaults 恢复全部设置；应用启动或测试注入独立存储时调用。
    /// 对数字与 CFBoolean 做严格 CoreFoundation 类型检查；缺失或非法值逐项回退默认值，兼容旧版本存储。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = Self.storedInteger(forKey: Self.refreshIntervalKey, defaults: defaults)
            .flatMap(RefreshInterval.init(rawValue:)) ?? .oneSecond
        historyDuration = Self.storedInteger(forKey: Self.historyDurationKey, defaults: defaults)
            .flatMap(HistoryDuration.init(rawValue:)) ?? .fiveMinutes
        var restored = MetricSelection.all
        for section in MetricSection.allCases {
            let value = defaults.object(forKey: Self.selectionKeys[section]!)
            if let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                restored.set(section, enabled: (value as! NSNumber).boolValue)
            }
        }
        selection = restored
    }

    /// 严格读取整数设置；初始化刷新间隔和历史窗口时调用，拒绝布尔和非整数值。
    /// 同时检查 NSNumber 的 Objective-C 类型、可解析整数和数值等价性，避免小数被静默截断。
    private static func storedInteger(forKey key: String, defaults: UserDefaults) -> Int? {
        guard let value = defaults.object(forKey: key),
              CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID(),
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }

        let number = value as! NSNumber
        let type = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type),
              let integer = Int(number.stringValue),
              number.compare(NSNumber(value: integer)) == .orderedSame else {
            return nil
        }
        return integer
    }

    /// 生成引擎可用的配置快照；存储初始化或任一设置变化时读取。
    var configuration: MonitoringConfiguration {
        MonitoringConfiguration(refreshInterval: refreshInterval, historyDuration: historyDuration,
                                selection: selection)
    }

    /// 生成简短设置摘要；设置页面底部展示当前刷新与保留策略时读取。
    var summary: String { "每 \(refreshInterval.label)刷新 · 保留\(historyDuration.recentLabel)" }
}

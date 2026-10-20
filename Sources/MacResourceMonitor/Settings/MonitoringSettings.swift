import Combine
import CoreFoundation
import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5

    var id: Int { rawValue }
    var label: String { "\(rawValue) 秒" }
}

enum HistoryDuration: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var label: String { "\(rawValue / 60) 分钟" }
    var recentLabel: String { "最近 \(rawValue / 60) 分钟" }
}

enum MetricSection: String, CaseIterable, Sendable {
    case cpu, memory, upload, download, chipTemperature, fan, diskCapacity
}

struct MetricSelection: Equatable, Sendable {
    static let all = MetricSelection()
    private var selected: Set<MetricSection> = Set(MetricSection.allCases)

    func contains(_ section: MetricSection) -> Bool { selected.contains(section) }
    var isEmpty: Bool { selected.isEmpty }

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
    // Raw values are persisted identifiers; do not rename them when changing UI labels.
    static let selectionKeys: [MetricSection: String] = Dictionary(uniqueKeysWithValues:
        MetricSection.allCases.map { ($0, "monitoring.section.\($0.rawValue)") })

    @Published private(set) var selection: MetricSelection

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

    var configuration: MonitoringConfiguration {
        MonitoringConfiguration(refreshInterval: refreshInterval, historyDuration: historyDuration,
                                selection: selection)
    }

    var summary: String { "每 \(refreshInterval.label)刷新 · 保留\(historyDuration.recentLabel)" }
}

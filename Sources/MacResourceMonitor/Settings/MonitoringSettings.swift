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

struct MonitoringConfiguration: Equatable, Sendable {
    var refreshInterval: RefreshInterval
    var historyDuration: HistoryDuration
}

@MainActor
final class MonitoringSettings: ObservableObject {
    static let refreshIntervalKey = "monitoring.refreshIntervalSeconds"
    static let historyDurationKey = "monitoring.historyDurationSeconds"

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
        MonitoringConfiguration(refreshInterval: refreshInterval, historyDuration: historyDuration)
    }

    var summary: String { "每 \(refreshInterval.label)刷新 · 保留\(historyDuration.recentLabel)" }
}

import Combine
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
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Self.refreshIntervalKey)) ?? .oneSecond
        historyDuration = HistoryDuration(rawValue: defaults.integer(forKey: Self.historyDurationKey)) ?? .fiveMinutes
    }

    var configuration: MonitoringConfiguration {
        MonitoringConfiguration(refreshInterval: refreshInterval, historyDuration: historyDuration)
    }

    var summary: String { "每 \(refreshInterval.label)刷新 · 保留\(historyDuration.recentLabel)" }
}

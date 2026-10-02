import Foundation
import XCTest
@testable import MacResourceMonitor

@MainActor
final class MonitoringSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MonitoringSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsAreOneSecondAndFiveMinutes() {
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
        XCTAssertEqual(settings.summary, "每 1 秒刷新 · 保留最近 5 分钟")
    }

    func testEverySupportedValueRoundTrips() {
        for refresh in RefreshInterval.allCases {
            for history in HistoryDuration.allCases {
                let settings = MonitoringSettings(defaults: defaults)
                settings.refreshInterval = refresh
                settings.historyDuration = history
                let restored = MonitoringSettings(defaults: defaults)
                XCTAssertEqual(restored.refreshInterval, refresh)
                XCTAssertEqual(restored.historyDuration, history)
            }
        }
    }

    func testUnsupportedStoredValuesFallBackToDefaults() {
        defaults.set(2, forKey: MonitoringSettings.refreshIntervalKey)
        defaults.set(-60, forKey: MonitoringSettings.historyDurationKey)
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
    }

    func testNumericStringStoredValueFallsBackToDefaults() {
        defaults.set("3", forKey: MonitoringSettings.refreshIntervalKey)
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
    }

    func testFractionalStoredValueFallsBackToDefaults() {
        defaults.set(3.9, forKey: MonitoringSettings.refreshIntervalKey)
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
    }
}

import CoreFoundation
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

    func testSelectionDefaultsToAllSevenAndConfigurationIncludesIt() {
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(MetricSection.allCases.count, 7)
        XCTAssertFalse(settings.selection.isEmpty)
        for section in MetricSection.allCases {
            XCTAssertTrue(settings.selection.contains(section), "Default selection excludes \(section)")
        }
        XCTAssertEqual(settings.configuration.selection, settings.selection)
    }

    func testSelectionKeysAreStableAndBooleanWritesAreIndependent() {
        XCTAssertEqual(MonitoringSettings.selectionKeys, [
            .cpu: "monitoring.section.cpu", .memory: "monitoring.section.memory",
            .upload: "monitoring.section.upload", .download: "monitoring.section.download",
            .chipTemperature: "monitoring.section.chipTemperature",
            .fan: "monitoring.section.fan", .diskCapacity: "monitoring.section.diskCapacity"
        ])
        var selection = MetricSelection.all
        selection.set(.download, enabled: false)
        XCTAssertFalse(selection.contains(.download))
        XCTAssertFalse(selection.isEmpty)
        selection.set(.download, enabled: true)
        XCTAssertEqual(selection, .all)

        let settings = MonitoringSettings(defaults: defaults)
        settings.set(.download, enabled: false)
        let value = defaults.object(forKey: MonitoringSettings.selectionKeys[.download]!)!
        XCTAssertEqual(CFGetTypeID(value as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertNil(defaults.object(forKey: MonitoringSettings.selectionKeys[.cpu]!))
    }

    func testEachSectionCanBeToggledAndRestoredIndependently() {
        let settings = MonitoringSettings(defaults: defaults)
        for section in MetricSection.allCases {
            settings.set(section, enabled: false)
            XCTAssertFalse(settings.selection.contains(section))
            XCTAssertFalse(MonitoringSettings(defaults: defaults).selection.contains(section))
            for other in MetricSection.allCases where other != section {
                XCTAssertEqual(MonitoringSettings(defaults: defaults).selection.contains(other),
                               settings.selection.contains(other))
            }
            settings.set(section, enabled: true)
            XCTAssertTrue(MonitoringSettings(defaults: defaults).selection.contains(section))
        }
    }

    func testAllOffPersistsAcrossRecreation() {
        let settings = MonitoringSettings(defaults: defaults)
        for section in MetricSection.allCases { settings.set(section, enabled: false) }
        XCTAssertTrue(settings.selection.isEmpty)
        XCTAssertTrue(MonitoringSettings(defaults: defaults).selection.isEmpty)
    }

    func testMissingAndNonBooleanKeysFallBackIndividually() {
        let keys = MonitoringSettings.selectionKeys
        XCTAssertEqual(keys.count, MetricSection.allCases.count)
        defaults.set(false, forKey: keys[.cpu]!)
        defaults.set("false", forKey: keys[.memory]!)
        defaults.set(0, forKey: keys[.upload]!)
        defaults.set(false, forKey: keys[.fan]!)
        let selection = MonitoringSettings(defaults: defaults).selection
        XCTAssertFalse(selection.contains(.cpu))
        XCTAssertFalse(selection.contains(.fan))
        for section in MetricSection.allCases where section != .cpu && section != .fan {
            XCTAssertTrue(selection.contains(section), "Invalid/missing \(section) should default on")
        }
    }

    func testLegacyRefreshAndHistorySurviveSelectionMigration() {
        defaults.set(3, forKey: MonitoringSettings.refreshIntervalKey)
        defaults.set(600, forKey: MonitoringSettings.historyDurationKey)
        let migrated = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(migrated.refreshInterval, .threeSeconds)
        XCTAssertEqual(migrated.historyDuration, .tenMinutes)
        XCTAssertEqual(migrated.selection, .all)
        defaults.removeObject(forKey: MonitoringSettings.refreshIntervalKey)
        defaults.removeObject(forKey: MonitoringSettings.historyDurationKey)
        let fresh = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(fresh.refreshInterval, .oneSecond)
        XCTAssertEqual(fresh.historyDuration, .fiveMinutes)
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

    func testStoreForwardsSettingsChangesToInjectedEngine() async {
        let settings = MonitoringSettings(defaults: defaults)
        let engine = MonitoringEngine(configuration: settings.configuration)
        let store = MonitoringStore(settings: settings, engine: engine)

        settings.refreshInterval = .threeSeconds
        settings.historyDuration = .tenMinutes

        let expected = MonitoringConfiguration(refreshInterval: .threeSeconds, historyDuration: .tenMinutes)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var actual = await engine.configuration
        while actual != expected && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            actual = await engine.configuration
        }

        store.stop()
        await engine.stop()
        XCTAssertEqual(actual, expected)
    }

    func testStoreAppliesInitialSettingsToDifferentlyConfiguredInjectedEngine() async {
        let settings = MonitoringSettings(defaults: defaults)
        settings.refreshInterval = .threeSeconds
        settings.historyDuration = .tenMinutes
        let engine = MonitoringEngine(configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .oneMinute))
        let store = MonitoringStore(settings: settings, engine: engine)

        let expected = MonitoringConfiguration(refreshInterval: .threeSeconds, historyDuration: .tenMinutes)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var actual = await engine.configuration
        while actual != expected && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            actual = await engine.configuration
        }

        store.stop()
        await engine.stop()
        XCTAssertEqual(actual, expected)
    }

    func testStoreKeepsLatestConfigurationAfterMixedPriorityChangesSettle() async {
        let settings = MonitoringSettings(defaults: defaults)
        let engine = MonitoringEngine(configuration: settings.configuration)
        let store = MonitoringStore(settings: settings, engine: engine)

        // All writes are queued before this actor yields. Joining each writer establishes
        // the final settings value independently of the writers' execution order.
        let writers = (0..<8).map { index in
            Task(priority: index.isMultiple(of: 2) ? .background : .high) { @MainActor in
                settings.refreshInterval = index.isMultiple(of: 2) ? .threeSeconds : .fiveSeconds
                settings.historyDuration = index.isMultiple(of: 2) ? .oneMinute : .tenMinutes
            }
        }
        for writer in writers { await writer.value }
        let expected = settings.configuration
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var actual = await engine.configuration
        while actual != expected && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            actual = await engine.configuration
        }
        XCTAssertEqual(actual, expected)

        // A transient match is insufficient: older forwarding work must not overwrite it.
        let stableUntil = ContinuousClock.now.advanced(by: .milliseconds(100))
        while ContinuousClock.now < stableUntil {
            try? await Task.sleep(for: .milliseconds(10))
            let settled = await engine.configuration
            XCTAssertEqual(settled, expected)
        }

        store.stop()
        await engine.stop()
    }
}

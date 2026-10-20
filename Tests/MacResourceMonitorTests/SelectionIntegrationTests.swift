import Foundation
import XCTest
@testable import MacResourceMonitor

// Exercises the real Settings -> Store -> Engine -> stream -> presentation path;
// only the operating-system providers and UserDefaults domain are substituted.
@MainActor
final class SelectionIntegrationTests: XCTestCase {
    func testPersistedAllOffThenReenablePublishesFreshUploadBaselineAndHistory() async throws {
        let name = "SelectionIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3, forKey: MonitoringSettings.refreshIntervalKey)
        defaults.set(600, forKey: MonitoringSettings.historyDurationKey)
        let migrated = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(migrated.refreshInterval, .threeSeconds)
        XCTAssertEqual(migrated.historyDuration, .tenMinutes)
        XCTAssertEqual(migrated.selection, .all, "Legacy preferences have no selection keys")
        migrated.refreshInterval = .oneSecond
        for section in MetricSection.allCases { migrated.set(section, enabled: false) }

        let probe = IntegrationProbe()
        let engine = integrationEngine(probe: probe)
        let store = MonitoringStore(settings: migrated, engine: engine)
        XCTAssertNil(store.snapshot, "Restored all-off selection must be visible before the first actor hop")
        XCTAssertEqual(store.selection, migrated.selection)
        await assertEventually { store.snapshot != nil }
        XCTAssertEqual(MenuBarPresentation(snapshot: store.snapshot, selection: store.selection).text, "监控")
        XCTAssertTrue(DashboardPresentation(selection: store.selection).isEmpty)
        let before = await probe.counts
        XCTAssertTrue(before.isEmpty, "Injected all-on Engine must apply restored selection before first collection")
        _ = await engine.sample(at: Date())
        let after = await probe.counts
        XCTAssertEqual(after, before, "All-off must not call any indicator provider")
        XCTAssertEqual(store.history.upload.count, 0)

        migrated.set(.upload, enabled: true)
        XCTAssertEqual(DashboardPresentation(selection: store.selection).visibleSections, [.upload])
        XCTAssertEqual(MenuBarPresentation(snapshot: store.snapshot, selection: store.selection).text, "↑ —")
        await assertEventually(timeout: 3) { store.history.upload.count >= 1 }
        XCTAssertNil(store.history.upload.elements.first?.value, "First restored rate is a new baseline")
        await assertEventually(timeout: 4) {
            store.snapshot?.network.value?.uploadBytesPerSecond != nil &&
            store.snapshot?.processes.upload.value != nil && store.history.upload.count >= 2
        }
        XCTAssertFalse(MenuBarPresentation(snapshot: store.snapshot, selection: store.selection).text.contains("↓"))
        let activeCounts = await probe.counts
        XCTAssertGreaterThan(activeCounts["network", default: 0], 0)
        XCTAssertGreaterThan(activeCounts["processNetwork", default: 0], 0)
        for unused in ["cpu", "memory", "disk", "temperature", "fan", "processSystem"] {
            XCTAssertEqual(activeCounts[unused, default: 0], 0, "Unexpected \(unused) collection")
        }

        migrated.set(.upload, enabled: false)
        XCTAssertNil(store.snapshot, "Immediate selection change must hide prior sample")
        XCTAssertEqual(store.history.upload.count, 0)
        await assertEventually { store.snapshot != nil && store.selection.isEmpty }
        let stoppedCounts = await probe.counts
        _ = await engine.sample(at: Date())
        let finalCounts = await probe.counts
        XCTAssertEqual(finalCounts, stoppedCounts)
        store.stop()
        await engine.stop()

        let restored = MonitoringSettings(defaults: defaults)
        XCTAssertTrue(restored.selection.isEmpty)
        XCTAssertEqual(restored.historyDuration, .tenMinutes)
        let freshProbe = IntegrationProbe()
        let freshEngine = integrationEngine(probe: freshProbe)
        let freshStore = MonitoringStore(settings: restored, engine: freshEngine)
        XCTAssertNil(freshStore.snapshot)
        XCTAssertEqual(MenuBarPresentation(snapshot: freshStore.snapshot, selection: freshStore.selection).text, "监控")
        await assertEventually { freshStore.snapshot != nil }
        let freshCounts = await freshProbe.counts
        XCTAssertTrue(freshCounts.isEmpty)
        freshStore.stop()
        await freshEngine.stop()
    }

    func testEachSelectionCrossesStoreAndEngineWithoutReadingUnselectedBranches() async throws {
        let name = "SelectionIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MonitoringSettings(defaults: defaults)
        for section in MetricSection.allCases { settings.set(section, enabled: false) }
        let probe = IntegrationProbe()
        let engine = integrationEngine(probe: probe)
        let store = MonitoringStore(settings: settings, engine: engine)
        await assertEventually { store.snapshot != nil }
        for section in MetricSection.allCases {
            settings.set(section, enabled: true)
            XCTAssertEqual(DashboardPresentation(selection: store.selection).visibleSections, [section])
            await assertEventually { await engine.configuration.selection == settings.selection }
            let prior = await probe.counts
            _ = await engine.sample(at: Date())
            let current = await probe.counts
            let requested: Set<String>
            switch section {
            case .cpu: requested = ["cpu", "processSystem"]
            case .memory: requested = ["memory", "processSystem"]
            case .upload, .download: requested = ["network", "processNetwork"]
            case .chipTemperature: requested = ["temperature"]
            case .fan: requested = ["fan"]
            case .diskCapacity: requested = ["disk"]
            }
            for branch in ["cpu", "memory", "network", "disk", "temperature", "fan", "processSystem", "processNetwork"] {
                let difference = current[branch, default: 0] - prior[branch, default: 0]
                if requested.contains(branch) {
                    XCTAssertGreaterThan(difference, 0, "\(section) did not read \(branch)")
                } else {
                    XCTAssertEqual(difference, 0, "\(section) unexpectedly read \(branch)")
                }
            }
            let menu = MenuBarPresentation(snapshot: store.snapshot, selection: store.selection).text
            XCTAssertEqual(menu == "监控", ![MetricSection.cpu, .memory, .upload, .download].contains(section))
            settings.set(section, enabled: false)
            await assertEventually { await engine.configuration.selection.isEmpty }
            XCTAssertTrue(DashboardPresentation(selection: store.selection).isEmpty)
        }
        store.stop()
        await engine.stop()
    }

    func testNetworkProcessFailureAndTemperatureFailureKeepOtherSelectedReadings() async throws {
        let name = "SelectionIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MonitoringSettings(defaults: defaults)
        for section in MetricSection.allCases { settings.set(section, enabled: false) }
        let probe = IntegrationProbe(temperatureFails: true, processNetworkFails: true)
        let engine = integrationEngine(probe: probe)
        let store = MonitoringStore(settings: settings, engine: engine)
        for section in [MetricSection.memory, .download, .chipTemperature, .fan] {
            settings.set(section, enabled: true)
        }
        await assertEventually { await engine.configuration.selection == settings.selection }
        let snapshot = await engine.sample(at: Date())
        XCTAssertEqual(snapshot.memory.value?.usage, 0.4)
        XCTAssertNotNil(snapshot.network.value)
        XCTAssertTrue(snapshot.processes.download.isUnavailable)
        XCTAssertTrue(snapshot.temperature.isUnavailable)
        XCTAssertEqual(snapshot.fan.value, .fanless)
        XCTAssertTrue(snapshot.processes.memory.value != nil)
        XCTAssertEqual(DashboardPresentation(selection: store.selection).visibleSections,
                       [.memory, .download, .chipTemperature, .fan])
        let counts = await probe.counts
        XCTAssertGreaterThan(counts["temperature", default: 0], 0)
        XCTAssertGreaterThan(counts["fan", default: 0], 0)
        XCTAssertGreaterThan(counts["processNetwork", default: 0], 0)
        XCTAssertEqual(counts["cpu", default: 0], 0)
        XCTAssertEqual(counts["disk", default: 0], 0)
        store.stop()
        await engine.stop()
    }

    private func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return await condition()
    }

    private func assertEventually(timeout: TimeInterval = 2, file: StaticString = #filePath,
                                  line: UInt = #line, _ condition: () async -> Bool) async {
        let reached = await eventually(timeout: timeout, condition)
        XCTAssertTrue(reached, "Condition not met before timeout", file: file, line: line)
    }
}

private actor IntegrationProbe {
    private(set) var counts: [String: Int] = [:]
    let temperatureFails: Bool
    let processNetworkFails: Bool
    init(temperatureFails: Bool = false, processNetworkFails: Bool = false) {
        self.temperatureFails = temperatureFails
        self.processNetworkFails = processNetworkFails
    }
    func hit(_ name: String) -> UInt64 {
        counts[name, default: 0] += 1
        return UInt64(counts[name]!)
    }
}

private func integrationEngine(probe: IntegrationProbe) -> MonitoringEngine {
    MonitoringEngine(providers: .init(cpu: IntegrationCPU(probe: probe), memory: IntegrationMemory(probe: probe),
        network: IntegrationNetwork(probe: probe), disk: IntegrationDisk(probe: probe),
        sensors: IntegrationSensors(probe: probe), processes: IntegrationProcesses(probe: probe)),
        logger: IntegrationLogger())
}

private struct IntegrationLogger: DiagnosticLogging {
    func record(component: DiagnosticComponent, failure: String?, at date: Date) async throws {}
}
private struct IntegrationCPU: CPUProviding {
    let probe: IntegrationProbe
    func sample() async -> CPUTicks {
        let n = await probe.hit("cpu")
        return .init(user: n * 10, system: 0, nice: 0, idle: n * 90)
    }
}
private struct IntegrationMemory: MemoryProviding {
    let probe: IntegrationProbe
    func sample() async -> MemoryMetric {
        _ = await probe.hit("memory")
        return .init(usage: 0.4, usedBytes: 40, totalBytes: 100)
    }
}
private struct IntegrationNetwork: NetworkProviding {
    let probe: IntegrationProbe
    func sample() async -> NetworkCounters {
        let n = await probe.hit("network")
        return .init(received: n * 1000, sent: n * 2000, interfaces: ["en0"])
    }
}
private struct IntegrationDisk: DiskProviding {
    let probe: IntegrationProbe
    func sample() async -> DiskMetric {
        _ = await probe.hit("disk")
        return .init(usedBytes: 50, totalBytes: 100)
    }
}
private struct IntegrationSensors: SensorProviding {
    let probe: IntegrationProbe
    func sample() async -> ThermalMetric { .init(chipTemperatureCelsius: 42, fan: .fanless) }
    func sample(temperature: Bool, fan: Bool) async -> SensorReadings {
        if temperature { _ = await probe.hit("temperature") }
        if fan { _ = await probe.hit("fan") }
        return .init(temperature: temperature
                     ? (probe.temperatureFails ? .unavailable("temperatureUnavailable") : .value(42))
                     : .unavailable("notSelected"),
                     fan: fan ? .value(.fanless) : .unavailable("notSelected"))
    }
}
private actor IntegrationProcesses: ProcessMetricsProviding {
    let probe: IntegrationProbe
    init(probe: IntegrationProbe) { self.probe = probe }
    func sample() async -> ProcessRawSnapshot { await sample(system: true, network: true) }
    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot {
        if system { _ = await probe.hit("processSystem") }
        if network { _ = await probe.hit("processNetwork") }
        return .init(system: system ? .value([]) : .unavailable("notSelected"),
                     network: network ? (probe.processNetworkFails ? .unavailable("nettopTimedOut") : .value([]))
                     : .unavailable("notSelected"))
    }
    func cancel() async {}
}

import XCTest
import ServiceManagement
@testable import MacResourceMonitor

final class UITests: XCTestCase {
    @MainActor
    func testLoginToggleRegistersWhenDisabled() throws {
        let service = FakeLoginService(status: .notRegistered)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testLoginToggleUnregistersWhenEnabled() throws {
        let service = FakeLoginService(status: .enabled)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testRepeatedToggleDoesNotRepeatRegistration() throws {
        let service = FakeLoginService(status: .enabled)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(true)
        try manager.setEnabled(false)
        try manager.setEnabled(false)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testRequiresApprovalCanBeUnregistered() throws {
        let service = FakeLoginService(status: .requiresApproval)
        let manager = LoginItemManager(service: service)
        XCTAssertTrue(manager.isEnabled)

        try manager.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testNotRegisteredToggleOffIsIdempotent() throws {
        let service = FakeLoginService(status: .notRegistered)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testRegistrationFailureRestoresActualStatus() {
        let service = FakeLoginService(status: .notRegistered)
        service.registerError = LoginTestError.failed
        let manager = LoginItemManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(true))

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testUnregistrationFailureRestoresActualStatus() {
        let service = FakeLoginService(status: .enabled)
        service.unregisterError = LoginTestError.failed
        let manager = LoginItemManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(false))

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertTrue(manager.isEnabled)
    }

    func testApplicationMetadataIsStable() {
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.local.MacResourceMonitor")
        XCTAssertEqual(AppMetadata.minimumSystemVersion, "13.0")
    }

    func testMenuBarTextContainsFourCompactMetrics() {
        let model = MenuBarPresentation(
            cpu: .value(0.24), memory: .value(0.61),
            upload: .value(1_200_000), download: .value(8_400_000)
        )
        XCTAssertEqual(model.text, "C 24%   M 61%   ↑ 1.2M   ↓ 8.4M")
    }

    func testUnavailableReadingUsesDash() {
        XCTAssertEqual(MenuBarPresentation.compactPercent(.unavailable("read failed")), "—")
        XCTAssertEqual(MenuBarPresentation.compactRate(.unavailable("read failed")), "—")
    }

    func testMissingSnapshotAndInitialRatesUseDash() {
        XCTAssertEqual(MenuBarPresentation(snapshot: nil).text, "C —   M —   ↑ —   ↓ —")
        let snapshot = MetricSnapshot(
            timestamp: Date(), cpuUsage: .unavailable("等待 CPU 采样基线"),
            memory: .value(MemoryMetric(usage: 0.61, usedBytes: 61, totalBytes: 100)),
            network: .value(NetworkMetric(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)),
            thermal: .unavailable("not used"), disk: .unavailable("not used")
        )
        XCTAssertEqual(MenuBarPresentation(snapshot: snapshot).text, "C —   M 61%   ↑ —   ↓ —")
    }

    func testSparklineMissingPointBreaksLine() {
        let start = Date(timeIntervalSince1970: 0)
        let points = [
            HistoryPoint(timestamp: start, value: 0.2),
            HistoryPoint(timestamp: start.addingTimeInterval(1), value: 0.3),
            HistoryPoint(timestamp: start.addingTimeInterval(2), value: nil),
            HistoryPoint(timestamp: start.addingTimeInterval(3), value: 0.4)
        ]
        XCTAssertEqual(SparklinePresentation(points: points).segments.map(\.count), [2, 1])
    }

    func testSparklineKeepsOnlyLatestFiveMinutes() {
        let start = Date(timeIntervalSince1970: 0)
        let points = [
            HistoryPoint(timestamp: start, value: 0.1),
            HistoryPoint(timestamp: start.addingTimeInterval(301), value: 0.2)
        ]
        XCTAssertEqual(SparklinePresentation(points: points).segments.map(\.count), [1])
        XCTAssertEqual(SparklinePresentation(points: points).segments[0][0].value, 0.2)
    }

    func testSparklineAxisIgnoresPeakOutsideVisibleWindow() throws {
        let start = Date(timeIntervalSince1970: 0)
        let presentation = SparklinePresentation(points: [
            HistoryPoint(timestamp: start, value: 1),
            HistoryPoint(timestamp: start.addingTimeInterval(301), value: 0.02)
        ])

        XCTAssertEqual(presentation.visibleValues, [0.02])
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: presentation.visibleValues, kind: .percentage))
        XCTAssertEqual(axis.domain.lowerBound, 0)
        XCTAssertEqual(axis.domain.upperBound, 0.10, accuracy: 0.000_001)
    }

    func testSparklineAxisValuesUseOnlyFiniteVisibleSegments() {
        let start = Date(timeIntervalSince1970: 0)
        let presentation = SparklinePresentation(points: [
            HistoryPoint(timestamp: start, value: 100_000_000),
            HistoryPoint(timestamp: start.addingTimeInterval(301), value: 1024),
            HistoryPoint(timestamp: start.addingTimeInterval(302), value: nil),
            HistoryPoint(timestamp: start.addingTimeInterval(303), value: .nan),
            HistoryPoint(timestamp: start.addingTimeInterval(304), value: 2048)
        ])

        XCTAssertEqual(presentation.visibleValues, [1024, 2048])
        XCTAssertEqual(presentation.segments.map(\.count), [1, 1])
    }

    func testPresentationDistinguishesWaitingFromUnavailable() {
        XCTAssertEqual(MetricPresentation.status(for: Optional<Reading<Double>>.none), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("等待 CPU 采样基线")), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("read failed")), "暂不可用")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2)), "最近五分钟")
    }

    func testDiskDisplaysOnlyCapacityFromFirstSample() {
        let disk = DiskMetric(usedBytes: 25, totalBytes: 100)
        let model = DiskPresentation(reading: .value(disk))
        XCTAssertEqual(model.capacityText, "已用 25 B / 100 B")
        XCTAssertEqual(model.usedFraction, 0.25)
    }

    func testDiskCapacityFractionHandlesZeroAndOverflow() {
        let zero = DiskMetric(usedBytes: 10, totalBytes: 0)
        let overflow = DiskMetric(usedBytes: 125, totalBytes: 100)
        XCTAssertEqual(DiskPresentation(reading: .value(zero)).usedFraction, 0)
        XCTAssertEqual(DiskPresentation(reading: .value(overflow)).usedFraction, 1)
    }

    func testDiskUnavailableAndPendingCapacityStates() {
        XCTAssertEqual(DiskPresentation(reading: nil).status, "等待下一次采样")
        XCTAssertEqual(DiskPresentation(reading: .unavailable("capacity read failed")).status, "暂不可用")
    }

    func testTemperatureMissingAfterSnapshotIsUnavailable() {
        XCTAssertEqual(MetricPresentation.temperatureStatus(for: nil), "等待下一次采样")
        let thermal = ThermalMetric(chipTemperatureCelsius: nil, fan: .fanless)
        XCTAssertEqual(MetricPresentation.temperatureStatus(for: .value(thermal)), "暂不可用")
    }
}

private enum LoginTestError: Error { case failed }

@MainActor
private final class FakeLoginService: LoginService {
    var status: SMAppService.Status
    var registerCount = 0
    var unregisterCount = 0
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

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
        XCTAssertEqual(SparklinePresentation(points: points, historyDuration: .fiveMinutes, refreshInterval: .oneSecond).segments.map(\.count), [2, 1])
    }

    func testSparklineKeepsOnlyLatestFiveMinutes() {
        let start = Date(timeIntervalSince1970: 0)
        let points = [
            HistoryPoint(timestamp: start, value: 0.1),
            HistoryPoint(timestamp: start.addingTimeInterval(301), value: 0.2)
        ]
        XCTAssertEqual(SparklinePresentation(points: points, historyDuration: .fiveMinutes, refreshInterval: .oneSecond).segments.map(\.count), [1])
        XCTAssertEqual(SparklinePresentation(points: points, historyDuration: .fiveMinutes, refreshInterval: .oneSecond).segments[0][0].value, 0.2)
    }

    func testSparklineAxisIgnoresPeakOutsideVisibleWindow() throws {
        let start = Date(timeIntervalSince1970: 0)
        let presentation = SparklinePresentation(points: [
            HistoryPoint(timestamp: start, value: 1),
            HistoryPoint(timestamp: start.addingTimeInterval(301), value: 0.02)
        ], historyDuration: .fiveMinutes, refreshInterval: .oneSecond)

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
        ], historyDuration: .fiveMinutes, refreshInterval: .oneSecond)

        XCTAssertEqual(presentation.visibleValues, [1024, 2048])
        XCTAssertEqual(presentation.segments.map(\.count), [1, 1])
    }

    func testSparklineClockRollbackExcludesFuturePeakAndIncludesWindowBoundary() throws {
        let presentation = SparklinePresentation(points: [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 698), value: 0.9),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 699), value: 0.03),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 1000), value: 1),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 999), value: 0.02)
        ], historyDuration: .fiveMinutes, refreshInterval: .oneSecond)

        XCTAssertEqual(presentation.visibleValues, [0.03, 0.02])
        XCTAssertEqual(presentation.segments.map(\.count), [1, 1])
        XCTAssertEqual(presentation.segments.map { $0[0].timestamp.timeIntervalSince1970 }, [699, 999])
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: presentation.visibleValues, kind: .percentage))
        XCTAssertEqual(axis.domain.lowerBound, 0)
        XCTAssertEqual(axis.domain.upperBound, 0.10, accuracy: 0.000_001)
    }

    func testPresentationDistinguishesWaitingFromUnavailable() {
        XCTAssertEqual(MetricPresentation.status(for: Optional<Reading<Double>>.none, historyDuration: .oneMinute), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("等待 CPU 采样基线"), historyDuration: .tenMinutes), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("read failed"), historyDuration: .oneMinute), "暂不可用")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2), historyDuration: .fiveMinutes), "最近 5 分钟")
    }

    // Filtering the future sample before checking raw adjacency hides the rollback.
    func testShortClockRollbackSplitsEvenWhenFuturePointIsExcluded() throws {
        let cases: [(RefreshInterval, [TimeInterval])] = [
            (.oneSecond, [100, 103, 102]),
            (.threeSeconds, [100, 109, 106]),
            (.fiveSeconds, [100, 115, 110])
        ]
        for (interval, timestamps) in cases {
            let points = zip(timestamps, [0.02, 1.0, 0.03]).map {
                HistoryPoint(timestamp: Date(timeIntervalSince1970: $0.0), value: $0.1)
            }
            let presentation = SparklinePresentation(points: points, historyDuration: .oneMinute,
                                                     refreshInterval: interval)

            XCTAssertEqual(presentation.segments.map(\.count), [1, 1], "Interval: \(interval)")
            XCTAssertEqual(presentation.visibleValues, [0.02, 0.03])
            XCTAssertTrue(presentation.segments.flatMap { $0 }.allSatisfy {
                presentation.timeDomain.contains($0.timestamp)
            })
            let axis = try XCTUnwrap(SparklineAxisPresentation(values: presentation.visibleValues, kind: .percentage))
            XCTAssertEqual(axis.domain.upperBound, 0.10, accuracy: 0.000_001)
        }
    }

    // Removing the future point must not erase the real history path's rollback boundary.
    func testHistoryTrimmingPreservesRollbackForSparklineAndAxis() throws {
        var history = MetricHistory(historyDuration: .oneMinute)
        for (second, value) in [(100.0, 0.02), (109.0, 1.0), (106.0, 0.03)] {
            history.append(MetricSnapshot(
                timestamp: Date(timeIntervalSince1970: second), cpuUsage: .value(value),
                memory: .value(MemoryMetric(usage: value, usedBytes: 2, totalBytes: 100)),
                network: .value(NetworkMetric(downloadBytesPerSecond: value, uploadBytesPerSecond: value)),
                thermal: .unavailable("not used"), disk: .unavailable("not used")
            ))
        }

        for points in [history.cpu.elements, history.memory.elements,
                       history.upload.elements, history.download.elements] {
            XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [100, 106])
            let presentation = SparklinePresentation(points: points, historyDuration: .oneMinute,
                                                     refreshInterval: .threeSeconds)
            XCTAssertEqual(presentation.segments.map { $0.map { $0.timestamp.timeIntervalSince1970 } },
                           [[100], [106]])
            XCTAssertEqual(presentation.visibleValues, [0.02, 0.03])
            let axis = try XCTUnwrap(SparklineAxisPresentation(values: presentation.visibleValues, kind: .percentage))
            XCTAssertEqual(axis.domain.upperBound, 0.10, accuracy: 0.000_001)
        }
    }

    // Trimming and missing values must preserve boundaries without splitting normal samples.
    func testHistoryDiscontinuitiesSurviveUnavailableSamplesDuplicatesAndWindowTrimming() {
        let cases: [(RefreshInterval, [TimeInterval], [Double?], [[TimeInterval]])] = [
            (.oneSecond, [100, 103, 102], [0.02, 1, 0.03], [[100], [102]]),
            (.fiveSeconds, [100, 115, 110], [0.02, 1, 0.03], [[100], [110]]),
            (.threeSeconds, [100, 109, 106], [0.02, nil, 0.03], [[100], [106]]),
            (.threeSeconds, [100, 109, 105, 106], [0.02, 1, nil, 0.03], [[100], [106]]),
            (.threeSeconds, [100, 103, 103, 106], [0.02, 0.03, 0.04, 0.05], [[100, 103], [103, 106]]),
            (.threeSeconds, [99, 100, 109, 106, 157, 160], [1, 0.02, 1, 0.03, 0.04, 0.05],
             [[100], [106], [157, 160]]),
            (.threeSeconds, [100, 103, 106], [0.02, 0.03, 0.04], [[100, 103, 106]])
        ]
        for (interval, timestamps, values, expected) in cases {
            var history = MetricHistory(historyDuration: .oneMinute)
            for (second, value) in zip(timestamps, values) {
                history.append(MetricSnapshot(
                    timestamp: Date(timeIntervalSince1970: second),
                    cpuUsage: value.map(Reading.value) ?? .unavailable("missing"),
                    memory: value.map { .value(MemoryMetric(usage: $0, usedBytes: 2, totalBytes: 100)) }
                        ?? .unavailable("missing"),
                    network: .value(NetworkMetric(downloadBytesPerSecond: value, uploadBytesPerSecond: value)),
                    thermal: .unavailable("not used"), disk: .unavailable("not used")
                ))
            }
            // Replacing the buffers for duration changes must retain existing boundaries.
            let end = timestamps.last.map(Date.init(timeIntervalSince1970:))
            history.updateDuration(.tenMinutes, endingAt: end)
            history.updateDuration(.oneMinute, endingAt: end)
            for points in [history.cpu.elements, history.memory.elements,
                           history.upload.elements, history.download.elements] {
                let presentation = SparklinePresentation(points: points, historyDuration: .oneMinute,
                                                         refreshInterval: interval)
                XCTAssertEqual(presentation.segments.map { $0.map { $0.timestamp.timeIntervalSince1970 } },
                               expected, "Input timestamps: \(timestamps)")
            }
        }
    }

    // Fixed 300-second clipping would retain the old peak and distort the axis.
    func testSparklineUsesSelectedOneMinuteWindow() throws {
        let start = Date(timeIntervalSince1970: 0)
        let presentation = SparklinePresentation(points: [
            .init(timestamp: start, value: 0.9),
            .init(timestamp: start.addingTimeInterval(60), value: 0.02),
            .init(timestamp: start.addingTimeInterval(61), value: 0.03)
        ], historyDuration: .oneMinute, refreshInterval: .oneSecond)

        XCTAssertEqual(presentation.visibleValues, [0.02, 0.03])
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: presentation.visibleValues, kind: .percentage))
        XCTAssertEqual(axis.domain.upperBound, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(presentation.timeDomain.lowerBound, start.addingTimeInterval(1))
        XCTAssertEqual(presentation.timeDomain.upperBound, start.addingTimeInterval(61))
    }

    func testSparklineUsesSelectedTenMinuteWindowIncludingBoundary() {
        let presentation = SparklinePresentation(points: [
            .init(timestamp: Date(timeIntervalSince1970: 0), value: 0.9),
            .init(timestamp: Date(timeIntervalSince1970: 1), value: 0.2),
            .init(timestamp: Date(timeIntervalSince1970: 601), value: 0.3)
        ], historyDuration: .tenMinutes, refreshInterval: .fiveSeconds)

        XCTAssertEqual(presentation.visibleValues, [0.2, 0.3])
        XCTAssertEqual(presentation.timeDomain.lowerBound, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(presentation.timeDomain.upperBound, Date(timeIntervalSince1970: 601))
    }

    func testEmptySparklineHasValidSelectedTimeDomain() {
        for duration in HistoryDuration.allCases {
            let presentation = SparklinePresentation(points: [], historyDuration: duration, refreshInterval: .oneSecond)
            XCTAssertTrue(presentation.segments.isEmpty)
            XCTAssertLessThan(presentation.timeDomain.lowerBound, presentation.timeDomain.upperBound)
            XCTAssertEqual(presentation.timeDomain.upperBound.timeIntervalSince(presentation.timeDomain.lowerBound),
                           Double(duration.rawValue))
        }
    }

    func testPresentationUsesSelectedDurationLabel() {
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2), historyDuration: .oneMinute), "最近 1 分钟")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2), historyDuration: .tenMinutes), "最近 10 分钟")
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

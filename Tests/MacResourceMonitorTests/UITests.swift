import XCTest
@testable import MacResourceMonitor

final class UITests: XCTestCase {
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

    func testPresentationDistinguishesWaitingFromUnavailable() {
        XCTAssertEqual(MetricPresentation.status(for: Optional<Reading<Double>>.none), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("等待 CPU 采样基线")), "等待下一次采样")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.unavailable("read failed")), "暂不可用")
        XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2)), "最近五分钟")
    }
}

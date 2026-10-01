import XCTest
@testable import MacResourceMonitor

final class DomainTests: XCTestCase {
    func testRingBufferKeepsNewestValuesInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        [1, 2, 3, 4].forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [2, 3, 4])
    }

    func testRingBufferCapacityOneKeepsOnlyNewestValue() {
        var buffer = RingBuffer<Int>(capacity: 1)
        [1, 2, 3].forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [3])
    }

    func testRateFormatterUsesCompactUnits() {
        XCTAssertEqual(MetricFormatter.rate(1_250_000), "1.3 MB/s")
        XCTAssertEqual(MetricFormatter.menuRate(8_400_000), "8.4M")
    }

    func testRateFormatterSaturatesExtremelyLargeFiniteValues() {
        XCTAssertEqual(MetricFormatter.rate(Double.greatestFiniteMagnitude), "9223372036854775807 GB/s")
        XCTAssertEqual(MetricFormatter.menuRate(Double.greatestFiniteMagnitude), "9223372036854775807G")
    }

    func testRateFormatterUsesDecimalKBMBAndGBUnits() {
        XCTAssertEqual(MetricFormatter.rate(1_250), "1.3 KB/s")
        XCTAssertEqual(MetricFormatter.rate(1_250_000), "1.3 MB/s")
        XCTAssertEqual(MetricFormatter.rate(1_250_000_000), "1.3 GB/s")
    }

    func testMemoryFormatterUsesBinaryKiBMiBAndGiBUnits() {
        XCTAssertEqual(MetricFormatter.memory(1_536), "1.5 KiB")
        XCTAssertEqual(MetricFormatter.memory(1_572_864), "1.5 MiB")
        XCTAssertEqual(MetricFormatter.memory(1_610_612_736), "1.5 GiB")
        XCTAssertEqual(MetricFormatter.memory(UInt64.max), "17179869184 GiB")
    }

    func testPercentAndRPMAreIntegersAndNegativeValuesClampToZero() {
        XCTAssertEqual(MetricFormatter.percent(42.6), "43%")
        XCTAssertEqual(MetricFormatter.rpm(1_234.6), "1235 RPM")
        XCTAssertEqual(MetricFormatter.rate(-100), "0 B/s")
        XCTAssertEqual(MetricFormatter.percent(-12), "0%")
        XCTAssertEqual(MetricFormatter.rpm(-12), "0 RPM")
    }

    func testFormatterHandlesNonFiniteAndOutOfRangeValuesDeterministically() {
        XCTAssertEqual(MetricFormatter.rate(.nan), "0 B/s")
        XCTAssertEqual(MetricFormatter.rate(.infinity), "0 B/s")
        XCTAssertEqual(MetricFormatter.rate(-.infinity), "0 B/s")
        XCTAssertEqual(MetricFormatter.percent(.infinity), "0%")
        XCTAssertEqual(MetricFormatter.percent(-.infinity), "0%")
        XCTAssertEqual(MetricFormatter.percent(.nan), "0%")
        XCTAssertEqual(MetricFormatter.percent(Double.greatestFiniteMagnitude), "9223372036854775807%")
        XCTAssertEqual(MetricFormatter.rpm(Double.greatestFiniteMagnitude), "9223372036854775807 RPM")
    }

    func testUnavailableHistoryPointRetainsTimestampAndNilValue() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let point = HistoryPoint(timestamp: timestamp, value: nil)
        XCTAssertEqual(point.timestamp, timestamp)
        XCTAssertNil(point.value)
    }

    func testReadingExposesValueAndUnavailableState() {
        let available = Reading<Double>.value(2.5)
        let unavailable = Reading<Double>.unavailable("permission denied")
        XCTAssertEqual(available.value, 2.5)
        XCTAssertFalse(available.isUnavailable)
        XCTAssertNil(unavailable.value)
        XCTAssertTrue(unavailable.isUnavailable)
    }
}

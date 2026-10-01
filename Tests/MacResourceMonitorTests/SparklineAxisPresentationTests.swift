import XCTest
@testable import MacResourceMonitor

final class SparklineAxisPresentationTests: XCTestCase {
    func testLowCPUUsageUsesNarrowDynamicRange() throws {
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: [0.02, 0.03, 0.05], kind: .percentage))
        XCTAssertLessThanOrEqual(axis.domain.lowerBound, 0.02)
        XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 0.05)
        XCTAssertEqual(axis.domain.upperBound - axis.domain.lowerBound, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(axis.ticks.count, 3)
        XCTAssertLessThan(axis.domain.upperBound, 0.20)
    }

    func testPercentageRangeStaysWithinZeroAndOne() throws {
        let low = try XCTUnwrap(SparklineAxisPresentation(values: [0, 0.01], kind: .percentage))
        let high = try XCTUnwrap(SparklineAxisPresentation(values: [0.98, 1], kind: .percentage))
        XCTAssertEqual(low.domain.lowerBound, 0)
        XCTAssertEqual(high.domain.upperBound, 1)
        XCTAssertEqual(low.labels.first, "0%")
        XCTAssertEqual(high.labels.last, "100%")
    }

    func testConstantPercentageStillHasNonZeroRange() throws {
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: [0.24, 0.24], kind: .percentage))
        XCTAssertEqual(axis.domain.upperBound - axis.domain.lowerBound, 0.10, accuracy: 0.000_001)
    }

    func testRateRangeDoesNotForceZeroWhenTrafficHasBaseline() throws {
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: [8_000_000, 8_200_000, 8_400_000], kind: .rate))
        XCTAssertGreaterThan(axis.domain.lowerBound, 0)
        XCTAssertLessThanOrEqual(axis.domain.lowerBound, 8_000_000)
        XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 8_400_000)
        XCTAssertEqual(axis.ticks.count, 3)
        XCTAssertTrue(axis.labels.allSatisfy { $0.contains("MB/s") })
    }

    func testConstantAndNearZeroRatesHaveSafeRanges() throws {
        let constant = try XCTUnwrap(SparklineAxisPresentation(values: [2048, 2048], kind: .rate))
        let zero = try XCTUnwrap(SparklineAxisPresentation(values: [0, 0], kind: .rate))
        XCTAssertGreaterThan(constant.domain.upperBound, constant.domain.lowerBound)
        XCTAssertGreaterThan(zero.domain.upperBound, zero.domain.lowerBound)
        XCTAssertEqual(zero.domain.lowerBound, 0)
    }

    func testEmptyAndNonFiniteValuesAreIgnored() {
        XCTAssertNil(SparklineAxisPresentation(values: [], kind: .percentage))
        XCTAssertNil(SparklineAxisPresentation(values: [.nan, .infinity], kind: .rate))
        XCTAssertNotNil(SparklineAxisPresentation(values: [.nan, 1024], kind: .rate))
    }
}

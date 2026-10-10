import XCTest
@testable import MacResourceMonitor

final class SparklineHoverSelectionTests: XCTestCase {
    func testSelectsNearestFinitePointAndUsesLaterPointForTie() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.2),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 20), value: nil),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 0.4),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 40), value: .nan)
        ]

        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 20),
            points: points
        ))

        XCTAssertEqual(selection.timestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(selection.value, 0.4)
    }

    func testTargetsOutsideRangeSelectBoundaryPoints() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 3)
        ]

        XCTAssertEqual(
            SparklineHoverSelection(nearestTo: Date(timeIntervalSince1970: 0), points: points)?.timestamp,
            Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            SparklineHoverSelection(nearestTo: Date(timeIntervalSince1970: 50), points: points)?.timestamp,
            Date(timeIntervalSince1970: 30)
        )
    }

    func testEmptyAndInvalidPointsProduceNoSelection() {
        XCTAssertNil(SparklineHoverSelection(nearestTo: Date(), points: []))
        XCTAssertNil(SparklineHoverSelection(
            nearestTo: Date(),
            points: [HistoryPoint(timestamp: Date(), value: nil),
                     HistoryPoint(timestamp: Date(), value: .infinity)]
        ))
    }

    func testSegmentBoundaryStillReturnsAnActualSample() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.2),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 0.8, startsNewSegment: true)
        ]
        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 20),
            points: points
        ))

        XCTAssertEqual(selection.timestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(selection.value, 0.8)
    }

    func testFormatsPercentageAndRateValues() throws {
        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 10),
            points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.237)]
        ))
        XCTAssertEqual(selection.valueLabel(for: .percentage), "24%")

        let rate = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 10),
            points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1_250_000)]
        ))
        XCTAssertEqual(rate.valueLabel(for: .rate), "1.3 MB/s")
    }

    func testFormatsRelativeTimeWithoutInventingFutureElapsedTime() throws {
        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 10),
            points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1)]
        ))
        XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 10)), "现在")
        XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 55)), "45 秒前")
        XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 70)), "1 分钟前")
        XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 75)), "1 分 5 秒前")
        XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 5)), "现在")
    }

}

import XCTest
@testable import MacResourceMonitor

final class SparklineHoverLayoutTests: XCTestCase {
    func testStationaryHoverMapsIntoLatestTimeDomainAndSelectsNewSample() throws {
        let position = try XCTUnwrap(SparklineHoverPosition(
            location: CGPoint(x: 200, y: 30),
            plotFrame: CGRect(x: 20, y: 0, width: 200, height: 64)
        ))
        let oldDomain = Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 160)
        let newDomain = Date(timeIntervalSince1970: 101)...Date(timeIntervalSince1970: 161)
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 154), value: 0.2),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 155), value: 0.8)
        ]

        XCTAssertEqual(position.timestamp(in: oldDomain), Date(timeIntervalSince1970: 154))
        XCTAssertEqual(position.timestamp(in: newDomain), Date(timeIntervalSince1970: 155))
        XCTAssertEqual(
            SparklineHoverSelection(nearestTo: position.timestamp(in: newDomain), points: points)?.value,
            0.8
        )
    }

    func testHoverMappingUsesNormalizedPositionAcrossDomainLengths() throws {
        let position = try XCTUnwrap(SparklineHoverPosition(
            location: CGPoint(x: 110, y: 30),
            plotFrame: CGRect(x: 20, y: 0, width: 100, height: 64)
        ))
        let domain = Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 220)
        XCTAssertEqual(position.timestamp(in: domain), Date(timeIntervalSince1970: 208))
    }

    func testHoverOutsidePlotOrZeroWidthHasNoPosition() {
        let plotFrame = CGRect(x: 20, y: 5, width: 100, height: 60)
        XCTAssertNil(SparklineHoverPosition(location: CGPoint(x: 19, y: 30), plotFrame: plotFrame))
        XCTAssertNil(SparklineHoverPosition(location: CGPoint(x: 50, y: 4), plotFrame: plotFrame))
        XCTAssertNil(SparklineHoverPosition(location: CGPoint(x: 20, y: 30),
                                           plotFrame: CGRect(x: 20, y: 0, width: 0, height: 64)))
    }

    func testNarrowTooltipFitsInsidePlotWithoutCoveringYAxis() {
        let plotFrame = CGRect(x: 52, y: 0, width: 92, height: 64)
        for pointX: CGFloat in [52, 98, 144] {
            let layout = SparklineHoverTooltipLayout(pointX: pointX, plotFrame: plotFrame)

            XCTAssertEqual(layout.width, 92)
            XCTAssertEqual(layout.centerX, 98)
            XCTAssertGreaterThanOrEqual(layout.centerX - layout.width / 2, plotFrame.minX)
            XCTAssertLessThanOrEqual(layout.centerX + layout.width / 2, plotFrame.maxX)
        }
    }

    func testNormalTooltipSwitchesSidesAndStaysInsidePlot() {
        let plotFrame = CGRect(x: 20, y: 0, width: 300, height: 64)
        let cases: [(pointX: CGFloat, centerX: CGFloat)] = [
            (20, 82), (100, 162), (240, 178), (320, 258)
        ]
        for testCase in cases {
            let layout = SparklineHoverTooltipLayout(pointX: testCase.pointX, plotFrame: plotFrame)

            XCTAssertEqual(layout.width, 108)
            XCTAssertEqual(layout.centerX, testCase.centerX)
            XCTAssertGreaterThanOrEqual(layout.centerX - layout.width / 2, plotFrame.minX)
            XCTAssertLessThanOrEqual(layout.centerX + layout.width / 2, plotFrame.maxX)
        }
    }

    func testTooltipCenterClampsUsingActualWidth() {
        let plotFrame = CGRect(x: 20, y: 0, width: 150, height: 64)
        XCTAssertEqual(SparklineHoverTooltipLayout(pointX: 90, plotFrame: plotFrame).centerX, 116)
        XCTAssertEqual(SparklineHoverTooltipLayout(pointX: 100, plotFrame: plotFrame).centerX, 74)
    }
}

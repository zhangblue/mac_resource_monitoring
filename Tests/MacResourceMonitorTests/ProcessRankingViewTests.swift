import XCTest
@testable import MacResourceMonitor

final class ProcessRankingViewTests: XCTestCase {
    // Using aggregate percentage rounding or the wrong units loses process detail.
    func testStylesFormatProcessValuesWithTheirOwnUnits() {
        XCTAssertEqual(ProcessRankingStyle.cpu.format(142.35), "142.4%")
        XCTAssertEqual(ProcessRankingStyle.cpu.format(100), "100.0%")
        XCTAssertEqual(ProcessRankingStyle.memory.format(2_147_483_648), "2 GiB")
        XCTAssertEqual(ProcessRankingStyle.upload.format(43_200), "43.2 KB/s")
        XCTAssertEqual(ProcessRankingStyle.download.format(650_000), "650 KB/s")
    }

    // Invalid numeric inputs must not leak NaN/infinity or trap during byte conversion.
    func testStylesHandleInvalidAndOutOfRangeValues() {
        for value in [-1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(ProcessRankingStyle.cpu.format(value), "0.0%")
            XCTAssertEqual(ProcessRankingStyle.memory.format(value), "0 B")
        }
        XCTAssertEqual(ProcessRankingStyle.memory.format(Double(UInt64.max)), "17179869184 GiB")
    }

    // Appending a PID to only one duplicate leaves the other process ambiguous.
    func testEveryDuplicateNameIncludesPIDWhileUniqueNamesRemainPlain() {
        let first = ProcessIdentity(pid: 101, startTimeMicroseconds: 10)
        let second = ProcessIdentity(pid: 202, startTimeMicroseconds: 20)
        let third = ProcessIdentity(pid: 303, startTimeMicroseconds: 30)
        let presentation = ProcessRankingPresentation(reading: .value([
            .init(identity: first, name: "Chrome", value: 142.35),
            .init(identity: second, name: "Chrome", value: 50),
            .init(identity: third, name: "Finder", value: 2.25)
        ]), style: .cpu)

        XCTAssertEqual(presentation.content, .rows([
            .init(id: first, rank: 1, displayName: "Chrome (101)", formattedValue: "142.4%"),
            .init(id: second, rank: 2, displayName: "Chrome (202)", formattedValue: "50.0%"),
            .init(id: third, rank: 3, displayName: "Finder", formattedValue: "2.3%")
        ]))
    }

    // A same-named process outside the visible five must not add PID noise to a visible row.
    func testDuplicateDetectionUsesOnlyTheVisibleTopFive() {
        let entries: [ProcessRankingEntry] = (1...6).map { index in
            let identity = ProcessIdentity(pid: Int32(index), startTimeMicroseconds: UInt64(index))
            let name = index == 6 ? "App 1" : "App \(index)"
            return ProcessRankingEntry(identity: identity, name: name, value: Double(7 - index))
        }
        let presentation = ProcessRankingPresentation(reading: .value(entries), style: .download)

        guard case let .rows(rows) = presentation.content else {
            return XCTFail("Expected the five visible process rows")
        }
        XCTAssertEqual(rows.map(\.rank), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.displayName), ["App 1", "App 2", "App 3", "App 4", "App 5"])
        XCTAssertEqual(rows.map(\.formattedValue), ["6 B/s", "5 B/s", "4 B/s", "3 B/s", "2 B/s"])
    }

    // Mapping all unavailable readings to one state hides whether sampling can recover normally.
    func testMissingSnapshotAndBaselineWaitForTheNextSample() {
        XCTAssertEqual(ProcessRankingPresentation(reading: nil, style: .cpu).content,
                       .message("等待下一次采样"))
        XCTAssertEqual(ProcessRankingPresentation(reading: .unavailable("等待进程采样基线"), style: .upload).content,
                       .message("等待下一次采样"))
    }

    func testUnavailableSamplingDisplaysUnavailable() {
        XCTAssertEqual(ProcessRankingPresentation(reading: .unavailable("permission denied"), style: .memory).content,
                       .message("暂不可用"))
    }

    // Empty success is an idle ranking, not a failure or a baseline wait.
    func testSuccessfulEmptyRankingDisplaysNoActiveProcesses() {
        XCTAssertEqual(ProcessRankingPresentation(reading: .value([]), style: .download).content,
                       .message("暂无活动进程"))
    }
}

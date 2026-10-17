import XCTest
import SwiftUI
import Vision
@testable import MacResourceMonitor

final class ProcessRankingViewTests: XCTestCase {
    func testRankingAlwaysBuildsFiveVisualSlots() {
        for count in [1, 3, 5] {
            let presentation = ProcessRankingPresentation(
                reading: .value(makeEntries(count: count)),
                style: .cpu
            )
            XCTAssertEqual(presentation.slots.count, 5)
            XCTAssertEqual(presentation.slots.filter { slot in
                if case .process = slot.content { return true }
                return false
            }.count, count)
            XCTAssertEqual(presentation.slots.filter { slot in
                if case .empty = slot.content { return true }
                return false
            }.count, 5 - count)
        }

        let messageReadings: [Reading<[ProcessRankingEntry]>?] = [
            nil,
            .value([]),
            .unavailable("nettopTimedOut")
        ]
        for reading in messageReadings {
            let presentation = ProcessRankingPresentation(reading: reading, style: .download)
            XCTAssertEqual(presentation.slots.count, 5)
            XCTAssertEqual(presentation.slots.filter { slot in
                if case .message = slot.content { return true }
                return false
            }.count, 1)
            XCTAssertEqual(presentation.slots.filter { slot in
                if case .empty = slot.content { return true }
                return false
            }.count, 4)
        }
    }

    @MainActor
    func testRankingRenderedHeightIsStableForEveryPopulationAndMessageState() throws {
        let readings: [Reading<[ProcessRankingEntry]>?] = [
            nil,
            .value([]),
            .value(makeEntries(count: 1)),
            .value(makeEntries(count: 3)),
            .value(makeEntries(count: 5)),
            .unavailable("nettopTimedOut")
        ]
        let heights = try readings.map { reading in
            let renderer = ImageRenderer(content:
                ProcessRankingView(processes: reading, style: .cpu)
                    .frame(width: 180)
                    .padding(8)
                    .foregroundStyle(.black)
                    .background(.white))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage).height
        }
        XCTAssertEqual(Set(heights).count, 1, "Rendered heights: \(heights)")
    }

    // The truncatable part must not contain the disambiguating PID.
    func testLongDuplicateNamesKeepPIDOutOfTruncatableName() {
        let name = "Very Long Browser Renderer Helper Process"
        let entries: [ProcessRankingEntry] = [101, 202].map {
            .init(identity: .init(pid: $0, startTimeMicroseconds: 10), name: name, value: 12)
        }
        guard case let .rows(rows) = ProcessRankingPresentation(reading: .value(entries), style: .cpu).content else {
            return XCTFail("Expected duplicate rows")
        }
        XCTAssertEqual(rows.map(\.displayName), [name, name])
        XCTAssertEqual(rows.map(\.pidSuffix), ["(101)", "(202)"])
    }

    // Read the rendered narrow card, not source text or accessibility labels
    // (accessibility labels can include characters that are visually truncated).
    @MainActor
    func testNarrowRankingKeepsEveryDuplicatePIDInsideTheNameColumn() throws {
        let entries: [ProcessRankingEntry] = [101, 202].map {
            .init(identity: .init(pid: $0, startTimeMicroseconds: 10),
                  name: "Very Long Browser Renderer Helper Process", value: 12)
        }
        let renderer = ImageRenderer(content:
            ProcessRankingView(processes: .value(entries), style: .cpu)
                .frame(width: 144).padding(8).foregroundStyle(.black).background(.white))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(lines.contains { $0.contains("(101)") }, "Rendered rows: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("(202)") }, "Rendered rows: \(lines)")
        XCTAssertEqual(lines.filter { $0.contains("12.0%") }.count, 2, "Values must remain visible")
    }

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
            .init(id: first, rank: 1, displayName: "Chrome", pidSuffix: "(101)", formattedValue: "142.4%"),
            .init(id: second, rank: 2, displayName: "Chrome", pidSuffix: "(202)", formattedValue: "50.0%"),
            .init(id: third, rank: 3, displayName: "Finder", pidSuffix: nil, formattedValue: "2.3%")
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
        XCTAssertTrue(rows.allSatisfy { $0.pidSuffix == nil })
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

    private func makeEntries(count: Int) -> [ProcessRankingEntry] {
        (0..<count).map { index in
            let identifier = index + 1
            return ProcessRankingEntry(
                identity: ProcessIdentity(pid: Int32(identifier), startTimeMicroseconds: UInt64(identifier)),
                name: "App \(index + 1)",
                value: Double(index + 1)
            )
        }
    }
}

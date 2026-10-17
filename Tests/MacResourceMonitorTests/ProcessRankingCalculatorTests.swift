import Foundation
import XCTest
@testable import MacResourceMonitor

final class ProcessRankingCalculatorTests: XCTestCase {
    private let appA = ProcessIdentity(pid: 101, startTimeMicroseconds: 1_000_000)
    private let appB = ProcessIdentity(pid: 102, startTimeMicroseconds: 2_000_000)

    func testFirstSampleProvidesMemoryWhileRatesWaitForBaseline() {
        var calculator = ProcessRankingCalculator()
        let result = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 9_000, residentBytes: 200),
            .init(identity: appB, name: "B", cpuNanoseconds: 5_000, residentBytes: 800)
        ]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 200)
        ]), at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(result.memory.value?.map(\.name), ["B", "A"])
        XCTAssertEqual(result.memory.value?.map(\.value), [800, 200])
        XCTAssertTrue(result.cpu.isUnavailable)
        XCTAssertTrue(result.upload.isUnavailable)
        XCTAssertTrue(result.download.isUnavailable)
    }

    func testCPUUsesElapsedTimeAllowsMoreThanOneHundredPercentAndKeepsTopFive() {
        var calculator = ProcessRankingCalculator()
        let first: [ProcessSystemCounter] = (0..<7).map { (index: Int) in
            let identity = ProcessIdentity(pid: Int32(100 + index), startTimeMicroseconds: UInt64(index))
            return ProcessSystemCounter(identity: identity, name: "app\(index)",
                                        cpuNanoseconds: 0, residentBytes: UInt64(100 + index))
        }
        _ = calculator.update(system: .value(first), network: .value([]), at: Date(timeIntervalSince1970: 10))
        let second = first.enumerated().map { index, item in
            ProcessSystemCounter(identity: item.identity, name: item.name,
                                 cpuNanoseconds: UInt64(index + 1) * 1_000_000_000,
                                 residentBytes: item.residentBytes)
        }

        let result = calculator.update(system: .value(second), network: .value([]),
                                       at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(result.cpu.value?.map(\.name), ["app6", "app5", "app4", "app3", "app2"])
        XCTAssertEqual(result.cpu.value?.first?.value ?? -1, 350, accuracy: 0.001)
        XCTAssertEqual(result.memory.value?.map(\.name), ["app6", "app5", "app4", "app3", "app2"])
    }

    func testTiesUseLiteralNameOrderThenPIDForEveryRanking() {
        var calculator = ProcessRankingCalculator()
        let fixtures: [(Int32, String)] = [(9, "z"), (8, "same"), (7, "a"), (6, "Z"), (5, "same"), (4, "b"), (3, "c")]
        let system = fixtures.map { pid, name in
            ProcessSystemCounter(identity: .init(pid: pid, startTimeMicroseconds: 1), name: name,
                                 cpuNanoseconds: 0, residentBytes: 100)
        }
        let network = system.map {
            ProcessNetworkCounter(identity: $0.identity, name: $0.name, receivedBytes: 0, sentBytes: 0)
        }
        _ = calculator.update(system: .value(system), network: .value(network), at: Date(timeIntervalSince1970: 10))
        let result = calculator.update(system: .value(system.map {
            .init(identity: $0.identity, name: $0.name, cpuNanoseconds: 1_000_000_000, residentBytes: 100)
        }), network: .value(network.map {
            .init(identity: $0.identity, name: $0.name, receivedBytes: 100, sentBytes: 100)
        }), at: Date(timeIntervalSince1970: 11))

        for ranking in [result.cpu, result.memory, result.upload, result.download] {
            XCTAssertEqual(ranking.value?.map(\.name), ["Z", "a", "b", "c", "same"])
            XCTAssertEqual(ranking.value?.map(\.identity.pid), [6, 7, 4, 3, 5])
        }
    }

    func testNetworkFiltersZeroSeparatesDirectionsAndRejectsReusedPID() {
        var calculator = ProcessRankingCalculator()
        _ = calculator.update(system: .value([]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 200),
            .init(identity: appB, name: "B", receivedBytes: 300, sentBytes: 400)
        ]), at: Date(timeIntervalSince1970: 20))
        let reused = ProcessIdentity(pid: appA.pid, startTimeMicroseconds: 9_000_000)
        let result = calculator.update(system: .value([]), network: .value([
            .init(identity: reused, name: "A2", receivedBytes: 9_000, sentBytes: 9_000),
            .init(identity: appB, name: "B", receivedBytes: 2_300, sentBytes: 400)
        ]), at: Date(timeIntervalSince1970: 22))

        XCTAssertEqual(result.download.value?.map(\.name), ["B"])
        XCTAssertEqual(result.download.value?.first?.value ?? -1, 1_000)
        XCTAssertEqual(result.upload.value, [])

        let next = calculator.update(system: .value([]), network: .value([
            .init(identity: reused, name: "A2", receivedBytes: 9_000, sentBytes: 9_500),
            .init(identity: appB, name: "B", receivedBytes: 2_300, sentBytes: 400)
        ]), at: Date(timeIntervalSince1970: 23))
        XCTAssertEqual(next.download.value, [])
        XCTAssertEqual(next.upload.value?.map(\.name), ["A2"])
        XCTAssertEqual(next.upload.value?.first?.value, 500)
    }

    func testCPURejectsReusedPIDButMemoryIncludesNewProcessImmediately() {
        var calculator = ProcessRankingCalculator()
        _ = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 1_000, residentBytes: 100)
        ]), network: .value([]), at: Date(timeIntervalSince1970: 10))
        let reused = ProcessIdentity(pid: appA.pid, startTimeMicroseconds: 9_000_000)
        let result = calculator.update(system: .value([
            .init(identity: reused, name: "A2", cpuNanoseconds: 9_000_000_000, residentBytes: 500)
        ]), network: .value([]), at: Date(timeIntervalSince1970: 11))

        XCTAssertEqual(result.cpu.value, [])
        XCTAssertEqual(result.memory.value?.map(\.name), ["A2"])
        let next = calculator.update(system: .value([
            .init(identity: reused, name: "A2", cpuNanoseconds: 10_000_000_000, residentBytes: 500)
        ]), network: .value([]), at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(next.cpu.value?.first?.value, 100)
    }

    func testCounterRollbackDropsOnlyAffectedProcessAndRebuildsItsBaseline() {
        var calculator = ProcessRankingCalculator()
        _ = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 2_000_000_000, residentBytes: 100),
            .init(identity: appB, name: "B", cpuNanoseconds: 0, residentBytes: 200)
        ]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 200, sentBytes: 200),
            .init(identity: appB, name: "B", receivedBytes: 100, sentBytes: 100)
        ]), at: Date(timeIntervalSince1970: 10))
        let system = [
            ProcessSystemCounter(identity: appA, name: "A", cpuNanoseconds: 0, residentBytes: 100),
            ProcessSystemCounter(identity: appB, name: "B", cpuNanoseconds: 1_000_000_000, residentBytes: 200)
        ]
        let network = [
            ProcessNetworkCounter(identity: appA, name: "A", receivedBytes: 0, sentBytes: 300),
            ProcessNetworkCounter(identity: appB, name: "B", receivedBytes: 200, sentBytes: 200)
        ]
        let result = calculator.update(system: .value(system), network: .value(network), at: Date(timeIntervalSince1970: 11))
        for ranking in [result.cpu, result.upload, result.download] {
            XCTAssertEqual(ranking.value?.map(\.name), ["B"])
            XCTAssertEqual(ranking.value?.first?.value, 100)
        }
        XCTAssertEqual(result.memory.value?.count, 2)

        let next = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 2_000_000_000, residentBytes: 100)
        ]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 600, sentBytes: 700)
        ]), at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(next.cpu.value?.first?.value, 200)
        XCTAssertEqual(next.download.value?.first?.value, 600)
        XCTAssertEqual(next.upload.value?.first?.value, 400)
    }

    func testNonpositiveElapsedTimeProducesNoRatesButKeepsMemoryAvailable() {
        for invalidTime in [10.0, 9.0] {
            var calculator = ProcessRankingCalculator()
            _ = calculator.update(system: .value([
                .init(identity: appA, name: "A", cpuNanoseconds: 0, residentBytes: 100)
            ]), network: .value([
                .init(identity: appA, name: "A", receivedBytes: 0, sentBytes: 0)
            ]), at: Date(timeIntervalSince1970: 10))
            let result = calculator.update(system: .value([
                .init(identity: appA, name: "A", cpuNanoseconds: 1_000_000_000, residentBytes: 200)
            ]), network: .value([
                .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 100)
            ]), at: Date(timeIntervalSince1970: invalidTime))

            XCTAssertTrue(result.cpu.isUnavailable)
            XCTAssertTrue(result.upload.isUnavailable)
            XCTAssertTrue(result.download.isUnavailable)
            XCTAssertEqual(result.memory.value?.first?.value, 200)
        }
    }

    func testUnavailableSystemPreservesReasonWithoutInterruptingNetwork() {
        var calculator = ProcessRankingCalculator()
        _ = calculator.update(system: .value([]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 0, sentBytes: 0)
        ]), at: Date(timeIntervalSince1970: 10))
        let result = calculator.update(system: .unavailable("system failed"), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 200)
        ]), at: Date(timeIntervalSince1970: 11))

        assertUnavailable(result.cpu, reason: "system failed")
        assertUnavailable(result.memory, reason: "system failed")
        XCTAssertEqual(result.download.value?.first?.value, 100)
        XCTAssertEqual(result.upload.value?.first?.value, 200)
    }

    func testUnavailableNetworkPreservesReasonWithoutInterruptingCPUOrMemory() {
        var calculator = ProcessRankingCalculator()
        _ = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 0, residentBytes: 100)
        ]), network: .value([]), at: Date(timeIntervalSince1970: 10))
        let result = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 1_000_000_000, residentBytes: 200)
        ]), network: .unavailable("network failed"), at: Date(timeIntervalSince1970: 11))

        assertUnavailable(result.upload, reason: "network failed")
        assertUnavailable(result.download, reason: "network failed")
        XCTAssertEqual(result.cpu.value?.first?.value, 100)
        XCTAssertEqual(result.memory.value?.first?.value, 200)
    }

    func testResetRatesRequiresFreshBaselinesAndLeavesMemoryAvailable() {
        var calculator = ProcessRankingCalculator()
        let system = [ProcessSystemCounter(identity: appA, name: "A", cpuNanoseconds: 0, residentBytes: 100)]
        let network = [ProcessNetworkCounter(identity: appA, name: "A", receivedBytes: 0, sentBytes: 0)]
        _ = calculator.update(system: .value(system), network: .value(network), at: Date(timeIntervalSince1970: 10))
        calculator.resetRates()
        let result = calculator.update(system: .value(system), network: .value(network), at: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(result.cpu.isUnavailable)
        XCTAssertTrue(result.upload.isUnavailable)
        XCTAssertTrue(result.download.isUnavailable)
        XCTAssertEqual(result.memory.value?.first?.value, 100)
        let next = calculator.update(system: .value([
            .init(identity: appA, name: "A", cpuNanoseconds: 1_000_000_000, residentBytes: 100)
        ]), network: .value([
            .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 200)
        ]), at: Date(timeIntervalSince1970: 21))
        XCTAssertEqual(next.cpu.value?.first?.value, 100)
        XCTAssertEqual(next.download.value?.first?.value, 100)
        XCTAssertEqual(next.upload.value?.first?.value, 200)
    }

    private func assertUnavailable(
        _ reading: Reading<[ProcessRankingEntry]>, reason: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .unavailable(actualReason) = reading else {
            return XCTFail("Expected unavailable reading", file: file, line: line)
        }
        XCTAssertEqual(actualReason, reason, file: file, line: line)
    }
}

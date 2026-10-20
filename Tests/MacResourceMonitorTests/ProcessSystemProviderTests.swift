import Darwin
import XCTest
@testable import MacResourceMonitor

final class ProcessSystemProviderTests: XCTestCase {
    // Catches including PID zero, dropping valid siblings, and incorrect units.
    func testMapsValidProcessesAndSkipsVanishedAndZeroPIDs() throws {
        let provider = ProcessSystemProvider(access: FixtureProcessAccess(pids: [0, 42, 43], infos: [42: processInfo()]))
        XCTAssertEqual(try provider.sample(), [.init(identity: .init(pid: 42, startTimeMicroseconds: 2_000_003),
            name: "App", cpuNanoseconds: 300, residentBytes: 4096)])
    }

    func testAllProcessesExitingAfterListingIsAnEmptySuccess() throws {
        XCTAssertEqual(try ProcessSystemProvider(access: FixtureProcessAccess(pids: [42], infos: [:])).sample(), [])
    }

    // Catches treating libproc's returned count as bytes or accepting truncated info.
    func testLibprocUsesCapacityThenByteBufferAndRejectsPartialTaskInfo() throws {
        let access = LibprocProcessInfoAccess(listPIDs: { buffer, size in
            if buffer == nil { XCTAssertEqual(size, 0); return 2 }
            XCTAssertEqual(size, 136)
            buffer!.assumingMemoryBound(to: Int32.self)[0] = 42
            buffer!.assumingMemoryBound(to: Int32.self)[1] = 43
            return 2
        }, readTaskInfo: { _, _, size in size - 1 })
        XCTAssertEqual(try access.allPIDs(), [42, 43])
        XCTAssertNil(access.taskAllInfo(for: 42))
    }

    func testNegativeListResultIsAnExplicitFailureOnEitherCall() {
        for firstCallFails in [true, false] {
            let access = LibprocProcessInfoAccess(listPIDs: { buffer, _ in
                buffer == nil && !firstCallFails ? 1 : -1
            })
            XCTAssertThrowsError(try access.allPIDs()) {
                XCTAssertEqual($0 as? ProcessSystemProviderError, .processListFailed)
            }
        }
    }

    func testNamesFallBackToCommandThenPID() throws {
        var commandOnly = processInfo()
        commandOnly.pbsd.pbi_name = proc_bsdinfo().pbi_name
        withUnsafeMutableBytes(of: &commandOnly.pbsd.pbi_comm) { $0.copyBytes(from: Array("Comm\0".utf8)) }
        let rows = try ProcessSystemProvider(access: FixtureProcessAccess(pids: [42, 43],
            infos: [42: commandOnly, 43: proc_taskallinfo()])).sample()
        XCTAssertEqual(rows.map(\.name), ["Comm", "PID 43"])
    }

    func testCompositeProviderKeepsNetworkWhenSystemFails() async {
        let provider = ProcessMetricsProvider(system: ProcessSystemProvider(access: FailingProcessAccess()),
            network: NetTopProcessProvider(runner: FixtureNetTopRunner(), identities: FixtureIdentities()))
        let snapshot = await provider.sample()
        XCTAssertTrue(snapshot.system.isUnavailable)
        XCTAssertEqual(snapshot.network.value?.first?.receivedBytes, 1200)
    }

    func testCompositeProviderKeepsSystemWhenNetworkFails() async {
        let provider = ProcessMetricsProvider(system: ProcessSystemProvider(access: FixtureProcessAccess(pids: [42], infos: [42: processInfo()])),
            network: NetTopProcessProvider(runner: FixtureNetTopRunner(status: 1), identities: FixtureIdentities()))
        let snapshot = await provider.sample()
        XCTAssertEqual(snapshot.system.value?.first?.residentBytes, 4096)
        XCTAssertTrue(snapshot.network.isUnavailable)
    }

    func testSelectiveProcessBranchesDoNotRunUnrequestedProvider() async {
        let access = CountingProcessAccess()
        let runner = CountingNetTopRunner()
        let provider = ProcessMetricsProvider(system: ProcessSystemProvider(access: access),
            network: NetTopProcessProvider(runner: runner, identities: FixtureIdentities()))

        let systemOnly = await provider.sample(system: true, network: false)
        XCTAssertEqual(systemOnly.system.value?.count, 1)
        XCTAssertTrue(systemOnly.network.isUnavailable)
        XCTAssertEqual(access.listCount, 1)
        let systemRuns = await runner.runCount
        XCTAssertEqual(systemRuns, 0)

        access.reset()
        let networkOnly = await provider.sample(system: false, network: true)
        XCTAssertTrue(networkOnly.system.isUnavailable)
        XCTAssertEqual(networkOnly.network.value?.first?.receivedBytes, 1200)
        XCTAssertEqual(access.listCount, 0)
        let networkRuns = await runner.runCount
        XCTAssertEqual(networkRuns, 1)

        let both = await provider.sample(system: true, network: true)
        XCTAssertEqual(both.system.value?.count, 1)
        XCTAssertEqual(both.network.value?.count, 1)
        XCTAssertEqual(access.listCount, 1)
        let bothRuns = await runner.runCount
        XCTAssertEqual(bothRuns, 2)

        access.reset()
        let previousRuns = await runner.runCount
        let none = await provider.sample(system: false, network: false)
        XCTAssertTrue(none.system.isUnavailable)
        XCTAssertTrue(none.network.isUnavailable)
        XCTAssertEqual(access.listCount, 0)
        let finalRuns = await runner.runCount
        XCTAssertEqual(finalRuns, previousRuns)
    }

    // Catches leaking private enum/exit details instead of the documented safe categories.
    func testNetworkFailuresMapToFormalSafeCategories() async {
        let cases: [(NetTopProcessProviderError, String)] = [
            (.commandFailed, "nettopLaunchFailed"), (.timedOut, "nettopTimedOut"),
            (.outputTooLarge, "nettopOutputTooLarge"), (.nonzeroExit(123), "nettopExitFailed"),
            (.invalidCSV, "nettopInvalidCSV"), (.missingColumns, "nettopInvalidCSV"),
            (.noProcessRows, "nettopInvalidCSV"), (.cancelled, "nettopLaunchFailed"),
            (.alreadyRunning, "nettopLaunchFailed")
        ]
        for (error, expected) in cases {
            let provider = ProcessMetricsProvider(system: ProcessSystemProvider(access: FailingProcessAccess()),
                network: NetTopProcessProvider(runner: ThrowingNetTopRunner(error: error), identities: FixtureIdentities()))
            let snapshot = await provider.sample()
            guard case let .unavailable(reason) = snapshot.network else { return XCTFail("Expected unavailable") }
            XCTAssertEqual(reason, expected)
            guard case let .unavailable(systemReason) = snapshot.system else { return XCTFail("Expected unavailable") }
            XCTAssertEqual(systemReason, "processListFailed")
        }
    }
}

private final class CountingProcessAccess: ProcessInfoAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var listCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reset() { lock.lock(); defer { lock.unlock() }; count = 0 }
    func allPIDs() throws -> [Int32] {
        lock.lock(); count += 1; lock.unlock()
        return [42]
    }
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo? { processInfo() }
}

private actor CountingNetTopRunner: NetTopCommandRunning {
    private(set) var runCount = 0
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        runCount += 1
        return .init(output: Data(",bytes_in,bytes_out\nApp.42,1200,300\n".utf8), exitStatus: 0)
    }
    func cancel() async {}
}

private struct ThrowingNetTopRunner: NetTopCommandRunning {
    let error: NetTopProcessProviderError
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult { throw error }
    func cancel() async {}
}

private func processInfo() -> proc_taskallinfo {
    var info = proc_taskallinfo()
    info.pbsd.pbi_start_tvsec = 2
    info.pbsd.pbi_start_tvusec = 3
    info.ptinfo.pti_total_user = 100
    info.ptinfo.pti_total_system = 200
    info.ptinfo.pti_resident_size = 4096
    withUnsafeMutableBytes(of: &info.pbsd.pbi_name) { $0.copyBytes(from: Array("App\0".utf8)) }
    return info
}

private struct FixtureProcessAccess: ProcessInfoAccessing {
    let pids: [Int32]
    let infos: [Int32: proc_taskallinfo]
    func allPIDs() throws -> [Int32] { pids }
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo? { infos[pid] }
}

private struct FailingProcessAccess: ProcessInfoAccessing {
    func allPIDs() throws -> [Int32] { throw ProcessSystemProviderError.processListFailed }
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo? { nil }
}

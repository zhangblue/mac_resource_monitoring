import Foundation
import XCTest
@testable import MacResourceMonitor

final class NetTopProcessProviderTests: XCTestCase {
    // Catches naive splitting on commas/dots and ignoring named column order.
    func testCSVHandlesQuotedNamesEscapedQuotesAndFinalDotPID() throws {
        let csv = """
        ,bytes_out,bytes_in,
        Code Helper.42,300,1200,
        "Comma, App.43",900,600,
        "Quoted ""App"".helper.44",8,9,
        invalid-row,1,2,
        broken.45,no,2,
        missing.46,1,
        negative.47,-1,2,
        """
        let rows = try NetTopCSVParser.parse(Data(csv.utf8))
        XCTAssertEqual(rows.map(\.pid), [42, 43, 44])
        XCTAssertEqual(rows.map(\.name), ["Code Helper", "Comma, App", "Quoted \"App\".helper"])
        XCTAssertEqual(rows.map(\.receivedBytes), [1200, 600, 9])
        XCTAssertEqual(rows.map(\.sentBytes), [300, 900, 8])
    }

    func testMissingHeaderEmptyRowsAndMalformedQuotesFailExplicitly() {
        for csv in ["", ",other,bytes_out\na.42,1,2", ",bytes_in,bytes_out\ninvalid,1,2", ",bytes_in,bytes_out\n\"unclosed.42,1,2"] {
            XCTAssertThrowsError(try NetTopCSVParser.parse(Data(csv.utf8)))
        }
    }

    func testFixedCommandResolvesIdentitiesSkipsExitedAndCombinesDuplicateCounters() async throws {
        let csv = ",bytes_in,bytes_out\nApp.42,1200,300\nOther.42,600,900\nExited.43,1,2\n"
        let provider = NetTopProcessProvider(runner: FixtureNetTopRunner(csv: csv), identities: FixtureIdentities())
        let rows = try await provider.sample()
        XCTAssertEqual(rows, [.init(identity: .init(pid: 42, startTimeMicroseconds: 99), name: "App", receivedBytes: 1800, sentBytes: 1200)])
    }

    func testNonzeroExitAndOversizedOutputHaveDistinctErrors() async {
        for (runner, expected) in [(FixtureNetTopRunner(status: 2), NetTopProcessProviderError.nonzeroExit(2)),
            (FixtureNetTopRunner(csv: String(repeating: "x", count: 1_048_577)), .outputTooLarge)] {
            await expectError(expected, provider: NetTopProcessProvider(runner: runner, identities: FixtureIdentities()))
        }
    }

    func testEightHundredMillisecondTimeoutCancelsCommand() async {
        let runner = SuspendedNetTopRunner()
        let start = ContinuousClock.now
        await expectError(.timedOut, provider: NetTopProcessProvider(runner: runner, identities: FixtureIdentities()))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let cancelled = await runner.cancelled
        XCTAssertTrue(cancelled)
    }

    // Catches reporting user cancellation when timeout-driven termination finishes first.
    func testTimeoutKeepsItsErrorWhenTerminationImmediatelyFinishesCommand() async {
        await expectError(.timedOut, provider: NetTopProcessProvider(
            runner: ImmediatelyTerminatingRunner(), identities: FixtureIdentities()))
    }

    func testTaskCancellationTerminatesCommandAndReleasesSingleInstance() async throws {
        let runner = SuspendedNetTopRunner()
        let provider = NetTopProcessProvider(runner: runner, identities: FixtureIdentities())
        let task = Task { try await provider.sample() }
        await runner.waitUntilStarted()
        await expectError(.alreadyRunning, provider: provider)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, .cancelled) }
        let cancelled = await runner.cancelled
        XCTAssertTrue(cancelled)
        let resumed = try await provider.sample()
        XCTAssertEqual(resumed.first?.receivedBytes, 1200)
    }

    func testExplicitCancelTerminatesRunningSample() async {
        let runner = SuspendedNetTopRunner()
        let provider = NetTopProcessProvider(runner: runner, identities: FixtureIdentities())
        let task = Task { try await provider.sample() }
        await runner.waitUntilStarted()
        await provider.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, .cancelled) }
    }

    private func expectError(_ expected: NetTopProcessProviderError, provider: NetTopProcessProvider) async {
        do { _ = try await provider.sample(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, expected) }
    }
}

struct FixtureIdentities: ProcessIdentityResolving {
    func identity(for pid: Int32) -> ProcessIdentity? {
        pid == 42 ? .init(pid: 42, startTimeMicroseconds: 99) : nil
    }
}

struct FixtureNetTopRunner: NetTopCommandRunning {
    var csv = ",bytes_in,bytes_out\nApp.42,1200,300\n"
    var status: Int32 = 0
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        XCTAssertEqual(executable, "/usr/bin/nettop")
        XCTAssertEqual(arguments, ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"])
        return .init(output: Data(csv.utf8), exitStatus: status)
    }
    func cancel() async {}
}

private actor SuspendedNetTopRunner: NetTopCommandRunning {
    var started = false
    var cancelled = false
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        if cancelled { return .init(output: Data(",bytes_in,bytes_out\nApp.42,1200,300".utf8), exitStatus: 0) }
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        throw CancellationError()
    }
    func cancel() { cancelled = true }
    func waitUntilStarted() async { while !started { await Task.yield() } }
}

private actor ImmediatelyTerminatingRunner: NetTopCommandRunning {
    private var pending: Task<NetTopCommandResult, Error>?
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        let task = Task<NetTopCommandResult, Error> {
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        pending = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func cancel() async {
        pending?.cancel()
        _ = await pending?.result
        try? await Task.sleep(for: .milliseconds(100))
    }
}

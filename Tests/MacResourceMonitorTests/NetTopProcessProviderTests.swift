import Foundation
import Darwin
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

    // Catches cancel returning while a command is still unwinding its pipe/resource cleanup.
    func testProviderCancelWaitsForCommandCleanupThenAllowsImmediateRestart() async throws {
        let runner = GatedCleanupRunner()
        let provider = NetTopProcessProvider(runner: runner, identities: FixtureIdentities())
        let sample = Task { try await provider.sample() }
        await runner.waitUntilStarted()
        let returned = CompletionFlag()
        let cancellation = Task { await provider.cancel(); await returned.mark() }
        await runner.cleanup.waitUntilWaiting()
        try await Task.sleep(for: .milliseconds(30))
        let premature = await returned.value
        XCTAssertFalse(premature, "cancel must await command cleanup")
        await runner.cleanup.release()
        await cancellation.value
        let restarted = try await provider.sample()
        XCTAssertEqual(restarted.first?.receivedBytes, 1200)
        do { _ = try await sample.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, .cancelled) }
    }

    // Uses real pipes and the production readers; only OS child lifecycle is controlled.
    func testFoundationCancelWaitsForChildExitAndBothPipeReadersThenCanRestart() async throws {
        let first = ControlledChildProcess()
        let second = ControlledChildProcess()
        let factory = ControlledProcessFactory([first, second])
        let runner = FoundationNetTopCommandRunner(processFactory: { factory.next() })
        let running = Task { try await runner.run(executable: NetTopProcessProvider.executable, arguments: NetTopProcessProvider.arguments) }
        await waitFor { first.hasStarted }
        let returned = CompletionFlag()
        let cancelling = Task { await runner.cancel(); await returned.mark() }
        await waitFor { first.wasTerminated }
        try await assertNotReturned(returned, "cancel returned before waitUntilExit completed")
        first.releaseExit()
        await waitFor { first.didWaitForExit }
        try await assertNotReturned(returned, "cancel returned before either reader reached EOF")
        first.closeStdout()
        try await assertNotReturned(returned, "cancel returned while stderr reader still blocked")
        first.closeStderr()
        await cancelling.value
        XCTAssertTrue(first.readDescriptorsAreClosed)
        do { _ = try await running.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, .cancelled) }

        let restarted = Task { try await runner.run(executable: NetTopProcessProvider.executable, arguments: NetTopProcessProvider.arguments) }
        await waitFor { second.hasStarted }
        second.releaseExit()
        second.closeStdout()
        second.closeStderr()
        let result = try await restarted.value
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(second.readDescriptorsAreClosed)
    }

    func testFoundationTimeoutThenCancelWaitsForCleanupAndKeepsTimeoutReason() async throws {
        try await verifyTerminalFailureCleanup(.timedOut, overflow: false)
    }

    func testFoundationStreamingOutputLimitThenCancelWaitsForCleanupAndKeepsLimitReason() async throws {
        try await verifyTerminalFailureCleanup(.outputTooLarge, overflow: true)
    }

    private func verifyTerminalFailureCleanup(_ expected: NetTopProcessProviderError, overflow: Bool) async throws {
        let process = ControlledChildProcess()
        let runner = FoundationNetTopCommandRunner(processFactory: { process })
        let running = Task { try await runner.run(executable: NetTopProcessProvider.executable, arguments: NetTopProcessProvider.arguments) }
        await waitFor { process.hasStarted }
        let writing = Task.detached {
            if overflow { try process.writeStdout(Data(repeating: 65, count: 1_048_577)) }
        }
        await waitFor { process.wasTerminated }
        try await writing.value
        let returned = CompletionFlag()
        let cancelling = Task { await runner.cancel(); await returned.mark() }
        try await assertNotReturned(returned, "terminal failure must still await the child and readers")
        process.releaseExit()
        process.closeStdout()
        process.closeStderr()
        await cancelling.value
        XCTAssertTrue(process.didWaitForExit)
        XCTAssertTrue(process.readDescriptorsAreClosed)
        do { _ = try await running.value; XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, expected) }
    }

    private func assertNotReturned(_ returned: CompletionFlag, _ message: String) async throws {
        try await Task.sleep(for: .milliseconds(30))
        let value = await returned.value
        XCTAssertFalse(value, message)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Lifecycle gate was not reached")
    }

    private func expectError(_ expected: NetTopProcessProviderError, provider: NetTopProcessProvider) async {
        do { _ = try await provider.sample(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? NetTopProcessProviderError, expected) }
    }
}

private final class ControlledProcessFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ControlledChildProcess]
    init(_ processes: [ControlledChildProcess]) { self.processes = processes }
    func next() -> Process {
        lock.lock(); defer { lock.unlock() }
        return processes.removeFirst()
    }
}

private final class ControlledChildProcess: Process, @unchecked Sendable {
    private var commandURL: URL?
    private var commandArguments: [String]?
    private var outputPipe: Any?
    private var errorPipe: Any?
    override var executableURL: URL? { get { commandURL } set { commandURL = newValue } }
    override var arguments: [String]? { get { commandArguments } set { commandArguments = newValue } }
    override var standardOutput: Any? { get { outputPipe } set { outputPipe = newValue } }
    override var standardError: Any? { get { errorPipe } set { errorPipe = newValue } }
    private let condition = NSCondition()
    private var started = false
    private var childRunning = false
    private var terminated = false
    private var waited = false
    private var readDescriptors: [Int32] = []
    var hasStarted: Bool { condition.lock(); defer { condition.unlock() }; return started }
    var wasTerminated: Bool { condition.lock(); defer { condition.unlock() }; return terminated }
    var didWaitForExit: Bool { condition.lock(); defer { condition.unlock() }; return waited }
    var readDescriptorsAreClosed: Bool {
        condition.lock(); defer { condition.unlock() }
        return readDescriptors.count == 2 && readDescriptors.allSatisfy { fcntl($0, F_GETFD) == -1 && errno == EBADF }
    }
    override var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return childRunning }
    override var terminationStatus: Int32 { 0 }
    override func run() throws {
        condition.lock(); defer { condition.unlock() }
        XCTAssertEqual(executableURL?.path, "/usr/bin/nettop")
        XCTAssertEqual(arguments, ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"])
        readDescriptors = [(standardOutput as! Pipe).fileHandleForReading.fileDescriptor,
                           (standardError as! Pipe).fileHandleForReading.fileDescriptor]
        childRunning = true
        started = true
    }
    override func terminate() { condition.lock(); terminated = true; condition.unlock() }
    override func waitUntilExit() {
        condition.lock(); defer { condition.unlock() }
        while childRunning { condition.wait() }
        waited = true
    }
    func releaseExit() { condition.lock(); childRunning = false; condition.broadcast(); condition.unlock() }
    func closeStdout() { try? (standardOutput as! Pipe).fileHandleForWriting.close() }
    func closeStderr() { try? (standardError as! Pipe).fileHandleForWriting.close() }
    func writeStdout(_ data: Data) throws { try (standardOutput as! Pipe).fileHandleForWriting.write(contentsOf: data) }
}

private actor CompletionFlag {
    var value = false
    func mark() { value = true }
}

private actor CleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var waiting = false
    func wait() async {
        waiting = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilWaiting() async { while !waiting { await Task.yield() } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor GatedCleanupRunner: NetTopCommandRunning {
    let cleanup = CleanupGate()
    private var started = false
    private var reusable = false
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        if reusable { return .init(output: Data(",bytes_in,bytes_out\nApp.42,1200,300".utf8), exitStatus: 0) }
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch {
            await cleanup.wait()
            reusable = true
            throw error
        }
        throw CancellationError()
    }
    func cancel() async {}
    func waitUntilStarted() async { while !started { await Task.yield() } }
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

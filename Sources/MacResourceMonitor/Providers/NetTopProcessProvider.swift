import Foundation
import Darwin

enum NetTopProcessProviderError: Error, Equatable {
    case invalidCSV
    case missingColumns
    case noProcessRows
    case nonzeroExit(Int32)
    case outputTooLarge
    case timedOut
    case cancelled
    case alreadyRunning
    case commandFailed
}

struct NetTopRow: Equatable, Sendable {
    let pid: Int32
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

enum NetTopCSVParser {
    static func parse(_ data: Data) throws -> [NetTopRow] {
        guard let text = String(data: data, encoding: .utf8) else { throw NetTopProcessProviderError.invalidCSV }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let first = lines.first else { throw NetTopProcessProviderError.missingColumns }
        let header = try fields(first)
        guard let incoming = header.firstIndex(of: "bytes_in"), let outgoing = header.firstIndex(of: "bytes_out") else {
            throw NetTopProcessProviderError.missingColumns
        }
        var rows: [NetTopRow] = []
        for line in lines.dropFirst() {
            guard let columns = try? fields(line), columns.count > max(incoming, outgoing),
                  let label = columns.first, let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...]), pid > 0,
                  let received = UInt64(columns[incoming]), let sent = UInt64(columns[outgoing]) else { continue }
            rows.append(.init(pid: pid, name: String(label[..<dot]), receivedBytes: received, sentBytes: sent))
        }
        guard !rows.isEmpty else { throw NetTopProcessProviderError.noProcessRows }
        return rows
    }

    // nettop produces one record per line; quoted fields may contain commas and escaped quotes.
    private static func fields(_ line: String) throws -> [String] {
        var result: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < line.endIndex, line[next] == "\"" {
                        field.append("\"")
                        index = line.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else { field.append(character) }
            } else if character == "," {
                result.append(field)
                field = ""
                closedQuote = false
            } else if character == "\"", field.isEmpty, !closedQuote {
                quoted = true
            } else {
                guard !closedQuote, character != "\"" else { throw NetTopProcessProviderError.invalidCSV }
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw NetTopProcessProviderError.invalidCSV }
        result.append(field)
        return result
    }
}

struct NetTopCommandResult: Sendable {
    let output: Data
    let exitStatus: Int32
}

protocol NetTopCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult
    func cancel() async
}

actor NetTopProcessProvider {
    static let executable = "/usr/bin/nettop"
    static let arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
    static let outputLimit = 1_048_576
    private let runner: any NetTopCommandRunning
    private let identities: any ProcessIdentityResolving
    private var active: (id: UUID, task: Task<NetTopCommandResult, Error>)?

    init(runner: any NetTopCommandRunning = FoundationNetTopCommandRunner(),
         identities: any ProcessIdentityResolving = ProcessSystemProvider()) {
        self.runner = runner
        self.identities = identities
    }

    func sample() async throws -> [ProcessNetworkCounter] {
        guard active == nil else { throw NetTopProcessProviderError.alreadyRunning }
        let runner = runner
        let task = Task { try await runner.run(executable: Self.executable, arguments: Self.arguments) }
        let id = UUID()
        active = (id, task)
        defer { clearActive(id) }
        let result: NetTopCommandResult
        do {
            result = try await withTaskCancellationHandler {
                return try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError { throw NetTopProcessProviderError.cancelled }
        guard result.output.count <= Self.outputLimit else { throw NetTopProcessProviderError.outputTooLarge }
        guard result.exitStatus == 0 else { throw NetTopProcessProviderError.nonzeroExit(result.exitStatus) }
        var counters: [ProcessIdentity: ProcessNetworkCounter] = [:]
        var order: [ProcessIdentity] = []
        for row in try NetTopCSVParser.parse(result.output) {
            guard let identity = identities.identity(for: row.pid) else { continue }
            if let previous = counters[identity] {
                let received = previous.receivedBytes.addingReportingOverflow(row.receivedBytes)
                let sent = previous.sentBytes.addingReportingOverflow(row.sentBytes)
                guard !received.overflow, !sent.overflow else { throw NetTopProcessProviderError.invalidCSV }
                counters[identity] = .init(identity: identity, name: previous.name.isEmpty ? row.name : previous.name,
                    receivedBytes: received.partialValue, sentBytes: sent.partialValue)
            } else {
                order.append(identity)
                counters[identity] = .init(identity: identity, name: row.name,
                    receivedBytes: row.receivedBytes, sentBytes: row.sentBytes)
            }
        }
        return order.compactMap { counters[$0] }
    }

    func cancel() async {
        guard let active else { return }
        active.task.cancel()
        // The sample task owns the runner invocation and its structured cleanup.
        // Await it rather than allowing cancel to race a later invocation.
        _ = await active.task.result
        clearActive(active.id)
    }

    private func clearActive(_ id: UUID) {
        if active?.id == id { active = nil }
    }
}

actor FoundationNetTopCommandRunner: NetTopCommandRunning {
    private var active: (id: UUID, task: Task<NetTopCommandResult, Error>)?
    private let processFactory: @Sendable () -> Process
    private let timeout: Duration
    private let terminationGrace: Duration
    private let forceKill: @Sendable (Process) -> Void

    init(processFactory: @escaping @Sendable () -> Process = { Process() },
         timeout: Duration = .milliseconds(800),
         terminationGrace: Duration = .milliseconds(200),
         forceKill: @escaping @Sendable (Process) -> Void = { process in
             guard process.isRunning, process.processIdentifier > 0 else { return }
             Darwin.kill(process.processIdentifier, SIGKILL)
         }) {
        self.processFactory = processFactory
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.forceKill = forceKill
    }

    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        guard active == nil else { throw NetTopProcessProviderError.alreadyRunning }
        guard executable == NetTopProcessProvider.executable, arguments == NetTopProcessProvider.arguments else {
            throw NetTopProcessProviderError.commandFailed
        }
        let command = NetTopExecution(
            process: processFactory(),
            terminationGrace: terminationGrace,
            forceKill: forceKill
        )
        let timeout = timeout
        let task = Task {
            try await withTaskCancellationHandler {
                let watchdog = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    command.stop(.timedOut)
                }
                defer { watchdog.cancel() }
                // collect is the single completion path: it waits for the
                // termination callback, drains both readers and closes all
                // handles. Only its stored first failure decides the outcome.
                return try await command.collect()
            } onCancel: { command.stop(.cancelled) }
        }
        let id = UUID()
        active = (id, task)
        defer { clearActive(id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancel() async {
        guard let active else { return }
        active.task.cancel()
        _ = await active.task.result
        clearActive(active.id)
    }

    private func clearActive(_ id: UUID) {
        if active?.id == id { active = nil }
    }
}

private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}

// The lock protects Process launch/termination and data shared by the two pipe
// readers. Every exit path waits for the termination callback and both readers
// before closing their handles.
private final class NetTopExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let termination = ProcessTerminationLatch()
    private let terminationGrace: Duration
    private let forceKill: @Sendable (Process) -> Void
    private var failure: NetTopProcessProviderError?
    private var output = Data()
    private var byteCount = 0
    private var launched = false
    private var terminationRequested = false
    private var forceKillTask: Task<Void, Never>?

    init(process: Process,
         terminationGrace: Duration,
         forceKill: @escaping @Sendable (Process) -> Void) {
        self.process = process
        self.terminationGrace = terminationGrace
        self.forceKill = forceKill
        process.executableURL = URL(fileURLWithPath: NetTopProcessProvider.executable)
        process.arguments = NetTopProcessProvider.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let termination = termination
        process.terminationHandler = { process in
            termination.finish(process.terminationStatus)
        }
    }

    func collect() async throws -> NetTopCommandResult {
        defer {
            cancelForceKill()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        try launch()
        let outReader = Task.detached { self.read(self.stdout.fileHandleForReading, capture: true) }
        let errReader = Task.detached { self.read(self.stderr.fileHandleForReading, capture: false) }
        let exitStatus = await termination.wait()
        await outReader.value
        await errReader.value
        return try result(exitStatus: exitStatus)
    }

    private func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        do { try process.run(); launched = true }
        catch { throw NetTopProcessProviderError.commandFailed }
    }

    func stop(_ reason: NetTopProcessProviderError) {
        lock.lock()
        if failure == nil { failure = reason }
        guard launched, process.isRunning, !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        let process = process
        let grace = terminationGrace
        let forceKill = forceKill
        forceKillTask = Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            forceKill(process)
        }
        lock.unlock()
        process.terminate()
    }

    private func read(_ handle: FileHandle, capture: Bool) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            // A single POSIX read returns available pipe bytes. FileHandle's
            // length-based read may wait to fill the buffer and hide an overrun.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                stop(.commandFailed)
                return
            }
            lock.lock()
            byteCount += count
            let tooLarge = byteCount > NetTopProcessProvider.outputLimit
            if !tooLarge, capture, failure == nil { output.append(contentsOf: buffer.prefix(count)) }
            lock.unlock()
            if tooLarge { stop(.outputTooLarge); return }
        }
    }

    private func cancelForceKill() {
        lock.lock()
        let task = forceKillTask
        forceKillTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func result(exitStatus: Int32) throws -> NetTopCommandResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return .init(output: output, exitStatus: exitStatus)
    }
}

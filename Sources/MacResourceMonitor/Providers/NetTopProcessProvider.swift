import Foundation

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
    private var active: Task<NetTopCommandResult, Error>?

    init(runner: any NetTopCommandRunning = FoundationNetTopCommandRunner(),
         identities: any ProcessIdentityResolving = ProcessSystemProvider()) {
        self.runner = runner
        self.identities = identities
    }

    func sample() async throws -> [ProcessNetworkCounter] {
        guard active == nil else { throw NetTopProcessProviderError.alreadyRunning }
        let runner = runner
        let task = Task {
            try await withThrowingTaskGroup(of: NetTopCommandResult.self) { group in
                group.addTask { try await runner.run(executable: Self.executable, arguments: Self.arguments) }
                group.addTask {
                    try await Task.sleep(until: ContinuousClock.now.advanced(by: .milliseconds(800)), clock: .continuous)
                    throw NetTopProcessProviderError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        active = task
        defer { active = nil }
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
        active?.cancel()
        await runner.cancel()
    }
}

actor FoundationNetTopCommandRunner: NetTopCommandRunning {
    private var execution: NetTopExecution?

    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult {
        guard execution == nil else { throw NetTopProcessProviderError.alreadyRunning }
        guard executable == NetTopProcessProvider.executable, arguments == NetTopProcessProvider.arguments else {
            throw NetTopProcessProviderError.commandFailed
        }
        let command = NetTopExecution()
        execution = command
        defer { execution = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: NetTopCommandResult.self) { group in
                group.addTask { try await command.collect() }
                group.addTask {
                    try await Task.sleep(until: ContinuousClock.now.advanced(by: .milliseconds(800)), clock: .continuous)
                    command.stop(.timedOut)
                    throw NetTopProcessProviderError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { command.stop(.cancelled) }
    }

    func cancel() { execution?.stop(.cancelled) }
}

// The lock protects Process launch/termination and data shared by the two pipe readers.
// Every exit path waits for the child and both readers before closing their handles.
private final class NetTopExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var failure: NetTopProcessProviderError?
    private var output = Data()
    private var byteCount = 0
    private var launched = false

    init() {
        process.executableURL = URL(fileURLWithPath: NetTopProcessProvider.executable)
        process.arguments = NetTopProcessProvider.arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func collect() async throws -> NetTopCommandResult {
        defer {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        try launch()
        let outReader = Task.detached { self.read(self.stdout.fileHandleForReading, capture: true) }
        let errReader = Task.detached { self.read(self.stderr.fileHandleForReading, capture: false) }
        await Task.detached { self.process.waitUntilExit() }.value
        await outReader.value
        await errReader.value
        return try result()
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
        defer { lock.unlock() }
        if failure == nil { failure = reason }
        if launched, process.isRunning { process.terminate() }
    }

    private func read(_ handle: FileHandle, capture: Bool) {
        do {
            while let data = try handle.read(upToCount: 16_384), !data.isEmpty {
                lock.lock()
                byteCount += data.count
                let tooLarge = byteCount > NetTopProcessProvider.outputLimit
                if !tooLarge, capture, failure == nil { output.append(data) }
                lock.unlock()
                if tooLarge { stop(.outputTooLarge); return }
            }
        } catch { stop(.commandFailed) }
    }

    private func result() throws -> NetTopCommandResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return .init(output: output, exitStatus: process.terminationStatus)
    }
}

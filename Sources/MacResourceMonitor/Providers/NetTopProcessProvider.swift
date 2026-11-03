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
    /// 将 nettop CSV 输出解析为进程累计网络行；命令成功退出后由网络进程提供器调用。
    /// 先按表头定位 bytes_in/bytes_out，再从最后一个点拆分 name.pid；无合法进程行视为格式错误而非空成功。
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

    // nettop 每行一条记录；带引号字段可能包含逗号和转义双引号。
    /// 按 CSV 规则拆分单行字段；解析表头和每条进程记录时调用。
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
    /// 启动受限的 nettop 命令并收集结果；进程网络采样开始时调用。
    func run(executable: String, arguments: [String]) async throws -> NetTopCommandResult
    /// 取消当前命令并等待清理完成；板块切换、睡眠或停止监控时调用。
    func cancel() async
}

actor NetTopProcessProvider {
    static let executable = "/usr/bin/nettop"
    static let arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
    static let outputLimit = 1_048_576
    private let runner: any NetTopCommandRunning
    private let identities: any ProcessIdentityResolving
    private var active: (id: UUID, task: Task<NetTopCommandResult, Error>)?

    /// 组装命令执行器和进程身份解析器；应用启动或测试注入替身时调用。
    init(runner: any NetTopCommandRunning = FoundationNetTopCommandRunner(),
         identities: any ProcessIdentityResolving = ProcessSystemProvider()) {
        self.runner = runner
        self.identities = identities
    }

    /// 执行一次 nettop 并按稳定进程身份合并网络计数；上传/下载进程榜单启用时调用。
    /// actor 通过 active 实现单实例；相同 PID+启动时间的多行用溢出检测累加，退出或 PID 复用的行会被跳过。
    func sample() async throws -> [ProcessNetworkCounter] {
        guard active == nil else { throw NetTopProcessProviderError.alreadyRunning }
        let runner = runner
        // 命令参数固定在白名单内，避免采样路径执行任意外部命令。
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
        // 解析后重新读取 PID 启动时间，避免 PID 复用把不同进程累计到一起。
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

    /// 取消并等待当前采样任务收尾；监控引擎清理进程采集时调用。
    func cancel() async {
        guard let active else { return }
        active.task.cancel()
        // sample 任务拥有 runner 及结构化清理，等待完成可避免取消与下一次调用竞争。
        _ = await active.task.result
        clearActive(active.id)
    }

    /// 仅清理匹配的活跃任务；采样结束或取消完成后调用，防止旧任务覆盖新状态。
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

    /// 配置 Process 工厂、超时和强制结束策略；生产环境初始化或测试控制时序时调用。
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

    /// 校验固定命令并在超时保护下执行；NetTopProcessProvider 发起采样时调用。
    /// 只允许预定义可执行文件和参数；看门狗 800ms 后请求停止，取消处理器与 collect 共享统一清理路径。
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
                // 看门狗只负责在超时后请求停止，实际资源回收统一由 collect 完成。
                let watchdog = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    command.stop(.timedOut)
                }
                defer { watchdog.cancel() }
                // collect 是唯一完成路径：等待退出、排空两条管道并关闭句柄，最终以首次错误为准。
                return try await command.collect()
            } onCancel: { command.stop(.cancelled) }
        }
        let id = UUID()
        active = (id, task)
        defer { clearActive(id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// 取消活跃命令并等待其结构化清理；上层提供器取消采样时调用。
    func cancel() async {
        guard let active else { return }
        active.task.cancel()
        _ = await active.task.result
        clearActive(active.id)
    }

    /// 仅清理匹配的 runner 任务；命令完成或取消后调用。
    private func clearActive(_ id: UUID) {
        if active?.id == id { active = nil }
    }
}

private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    /// 异步等待 Process 终止状态；启动成功并开始读取管道后调用。
    /// CheckedContinuation 与 NSLock 共同处理“先退出后等待”和“先等待后退出”两种时序，且只恢复一次。
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

    /// 只发布一次终止状态并唤醒等待者；Process terminationHandler 回调时调用。
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

// 锁保护 Process 启停及两条管道共享数据；所有退出路径都会等待终止回调和读任务后再关闭句柄。
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

    /// 配置固定 nettop 进程、管道和终止回调；runner 每次执行命令时创建。
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
            // 系统终止回调只发布退出码，完整收尾仍由 collect 串行完成。
            termination.finish(process.terminationStatus)
        }
    }

    /// 启动进程、并行排空输出并返回结果；runner 创建执行对象后调用。
    /// stdout/stderr 由 detached Task 并行执行 POSIX read，终止回调与两条读取都结束后才关闭四个管道句柄。
    func collect() async throws -> NetTopCommandResult {
        defer {
            cancelForceKill()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        try launch()
        // stdout 和 stderr 必须并行排空，避免任一管道填满后阻塞子进程退出。
        let outReader = Task.detached { self.read(self.stdout.fileHandleForReading, capture: true) }
        let errReader = Task.detached { self.read(self.stderr.fileHandleForReading, capture: false) }
        let exitStatus = await termination.wait()
        await outReader.value
        await errReader.value
        return try result(exitStatus: exitStatus)
    }

    /// 在锁内启动已配置进程；collect 建立资源清理范围后调用。
    private func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        do { try process.run(); launched = true }
        catch { throw NetTopProcessProviderError.commandFailed }
    }

    /// 记录首次停止原因并先温和终止、超时后强制结束；取消、超时或读取失败时调用。
    /// 锁内采用 first-error-wins，先发送 SIGTERM；宽限期后独立任务按注入策略发送 SIGKILL，保证不可响应子进程可回收。
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
        // 先发送 terminate，宽限期后仍未退出才调用注入的 SIGKILL 策略。
        forceKillTask = Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            forceKill(process)
        }
        lock.unlock()
        process.terminate()
    }

    /// 持续读取单条管道并执行总输出限额；collect 为 stdout/stderr 各启动一次。
    /// 两条管道共享 1 MiB 总字节计数，仅 stdout 写入结果；EINTR 重试，其他 errno 转为命令失败。
    private func read(_ handle: FileHandle, capture: Bool) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            // POSIX read 返回当前可用字节；FileHandle 定长读取可能等待填满缓冲区而延迟发现超限。
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

    /// 取消尚未触发的强制结束任务；collect 的统一清理阶段调用。
    private func cancelForceKill() {
        lock.lock()
        let task = forceKillTask
        forceKillTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// 在锁内生成最终结果或抛出首次失败；进程退出且两条管道排空后调用。
    private func result(exitStatus: Int32) throws -> NetTopCommandResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return .init(output: output, exitStatus: exitStatus)
    }
}

import Foundation

enum DiagnosticComponent: String, Sendable {
    case cpu, memory, network, disk, sensors, processSystem, processNetwork
}

protocol DiagnosticLogging: Sendable {
    /// 记录或清除组件失败状态；每轮采样完成后的诊断阶段调用。
    func record(component: DiagnosticComponent, failure: String?, at date: Date) async throws
}

actor DiagnosticLogger: DiagnosticLogging {
    static let live = DiagnosticLogger()
    static let displayPath = "~/Library/Logs/MacResourceMonitor/diagnostics.log"
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/MacResourceMonitor/diagnostics.log")
    private static let knownCategories: Set<String> = [
        "machCallFailed", "counterOverflow", "missingInterfaceData",
        "invalidBootDevice", "deviceNotFound", "storageDriverNotFound",
        "ambiguousStorageDrivers", "registryChanged", "statisticsUnavailable",
        "capacityUnavailable", "unsupportedType", "insufficientBytes", "invalidKey",
        "invalidLayout", "serviceUnavailable", "ioFailure", "deviceFailure",
        "invalidResponseSize", "invalidDataSize", "invalidKeyCount",
        "invalidFanCount", "invalidFanSpeed", "processListFailed", "nettopLaunchFailed",
        "nettopTimedOut", "nettopOutputTooLarge", "nettopExitFailed", "nettopInvalidCSV"
    ]

    private let logURL: URL
    private var lastFailure: [DiagnosticComponent: String] = [:]

    /// 创建诊断日志记录器；生产环境使用默认日志路径，测试可注入临时文件。
    init(logURL: URL = DiagnosticLogger.logURL) {
        self.logURL = logURL
    }

    /// 仅在错误状态发生变化时追加安全日志；采集器返回失败或恢复成功后调用。
    /// Actor 串行化文件写入与去重字典；恢复成功只清除内存状态，不写冗余行，失败文本先经过白名单脱敏。
    func record(component: DiagnosticComponent, failure: String?, at date: Date) async throws {
        guard let failure else {
            lastFailure.removeValue(forKey: component)
            return
        }
        let safeDescription = Self.safeDescription(failure)
        guard lastFailure[component] != failure else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let line = "\(formatter.string(from: date)) \(component.rawValue) \(safeDescription)\n"
        let fileManager = FileManager.default
        // 首次写入前创建日志目录，避免用户从未运行过应用时文件路径不存在。
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let data = Data(line.utf8)
        if fileManager.fileExists(atPath: logURL.path) {
            // 已有文件通过 seekToEnd 追加，句柄由 defer 关闭；新文件则使用原子写入避免半截日志。
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL, options: .atomic)
        }
        lastFailure[component] = failure
    }

    /// 将内部错误裁剪为白名单分类；写入日志前调用，避免泄露路径或系统细节。
    /// 只接受 ASCII 字母、数字和下划线组成的前 64 字符分类，其余统一映射为“采集失败”。
    private static func safeDescription(_ description: String) -> String {
        let category = String(description.prefix {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }.prefix(64))
        return knownCategories.contains(category) ? category : "采集失败"
    }
}

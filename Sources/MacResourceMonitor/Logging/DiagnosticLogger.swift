import Foundation

enum DiagnosticComponent: String, Sendable {
    case cpu, memory, network, disk, sensors
}

protocol DiagnosticLogging: Sendable {
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
        "invalidFanCount", "invalidFanSpeed"
    ]

    private let logURL: URL
    private var lastFailure: [DiagnosticComponent: String] = [:]

    init(logURL: URL = DiagnosticLogger.logURL) {
        self.logURL = logURL
    }

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
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let data = Data(line.utf8)
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL, options: .atomic)
        }
        lastFailure[component] = failure
    }

    private static func safeDescription(_ description: String) -> String {
        let category = String(description.prefix {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }.prefix(64))
        return knownCategories.contains(category) ? category : "采集失败"
    }
}

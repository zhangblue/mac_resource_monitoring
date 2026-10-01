import Darwin

protocol CPUProviding: Sendable {
    func sample() throws -> CPUTicks
}

protocol MemoryProviding: Sendable {
    func sample() throws -> MemoryMetric
}

enum SystemProviderError: Error {
    case machCallFailed(String, kern_return_t)

    static func check(_ operation: String, result: kern_return_t) throws {
        guard result == KERN_SUCCESS else {
            throw machCallFailed(operation, result)
        }
    }
}

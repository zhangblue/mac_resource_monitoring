import Darwin

protocol CPUProviding: Sendable {
    func sample() throws -> CPUTicks
}

protocol MemoryProviding: Sendable {
    func sample() throws -> MemoryMetric
}

enum SystemProviderError: Error {
    case machCallFailed(String, kern_return_t)
}

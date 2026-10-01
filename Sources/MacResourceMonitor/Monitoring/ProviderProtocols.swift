import Darwin

protocol CPUProviding: Sendable {
    func sample() async throws -> CPUTicks
}

protocol MemoryProviding: Sendable {
    func sample() async throws -> MemoryMetric
}

protocol NetworkProviding: Sendable {
    func sample() async throws -> NetworkCounters
}

protocol DiskProviding: Sendable {
    func sample() async throws -> DiskMetric
}

protocol SensorProviding: Sendable {
    func sample() async throws -> ThermalMetric
}

extension NetworkProvider: NetworkProviding {}
extension DiskProvider: DiskProviding {}
extension AppleSiliconSensorProvider: SensorProviding {}

struct ProviderSet: Sendable {
    let cpu: any CPUProviding
    let memory: any MemoryProviding
    let network: any NetworkProviding
    let disk: any DiskProviding
    let sensors: any SensorProviding

    static var live: ProviderSet {
        ProviderSet(cpu: CPUProvider(), memory: MemoryProvider(), network: NetworkProvider(),
                    disk: DiskProvider(), sensors: SystemSensorProvider())
    }
}

// Opening SMC can fail independently of every other provider. Defer opening to
// sampling so the engine can represent that error as an unavailable sensor.
private actor SystemSensorProvider: SensorProviding {
    private var provider: AppleSiliconSensorProvider?

    func sample() throws -> ThermalMetric {
        if provider == nil { provider = try AppleSiliconSensorProvider() }
        return try provider!.sample()
    }
}

enum SystemProviderError: Error {
    case machCallFailed(String, kern_return_t)

    static func check(_ operation: String, result: kern_return_t) throws {
        guard result == KERN_SUCCESS else {
            throw machCallFailed(operation, result)
        }
    }
}

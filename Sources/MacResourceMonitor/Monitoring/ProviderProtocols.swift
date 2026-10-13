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
extension IntelSensorProvider: SensorProviding {}

struct ProviderSet: Sendable {
    let cpu: any CPUProviding
    let memory: any MemoryProviding
    let network: any NetworkProviding
    let disk: any DiskProviding
    let sensors: any SensorProviding

    static var live: ProviderSet {
        live(intelSensor: { try IntelSensorProvider() },
             appleSiliconSensor: { try AppleSiliconSensorProvider() })
    }

    static func live(
        intelSensor: @escaping @Sendable () throws -> any SensorProviding,
        appleSiliconSensor: @escaping @Sendable () throws -> any SensorProviding
    ) -> ProviderSet {
        ProviderSet(cpu: CPUProvider(), memory: MemoryProvider(), network: NetworkProvider(),
                    disk: DiskProvider(), sensors: SystemSensorProvider(factory: {
                        #if arch(x86_64)
                        return try intelSensor()
                        #elseif arch(arm64)
                        return try appleSiliconSensor()
                        #else
                        #error("Unsupported sensor architecture")
                        #endif
                    }))
    }
}

// Opening SMC can fail independently of every other provider. Defer opening to
// sampling so the engine can represent that error as an unavailable sensor.
actor SystemSensorProvider: SensorProviding {
    private let factory: @Sendable () throws -> any SensorProviding
    private var provider: (any SensorProviding)?

    init(factory: @escaping @Sendable () throws -> any SensorProviding) {
        self.factory = factory
    }

    func sample() async throws -> ThermalMetric {
        if provider == nil { provider = try factory() }
        return try await provider!.sample()
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

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
    func sample(temperature: Bool, fan: Bool) async -> SensorReadings
}

extension SensorProviding {
    func sample(temperature: Bool, fan: Bool) async -> SensorReadings {
        guard temperature || fan else {
            return .init(temperature: .unavailable("notSelected"), fan: .unavailable("notSelected"))
        }
        do {
            let metric = try await sample()
            return .init(temperature: temperature ? metric.chipTemperatureCelsius.map(Reading.value)
                ?? .unavailable("temperatureUnavailable") : .unavailable("notSelected"),
                fan: fan ? .value(metric.fan) : .unavailable("notSelected"))
        } catch {
            return .init(temperature: temperature ? .unavailable("temperatureUnavailable") : .unavailable("notSelected"),
                         fan: fan ? .unavailable("fanUnavailable") : .unavailable("notSelected"))
        }
    }
}

protocol ProcessMetricsProviding: Sendable {
    func sample() async -> ProcessRawSnapshot
    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot
    func cancel() async
}

extension ProcessMetricsProviding {
    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot {
        guard system || network else {
            return .init(system: .unavailable("notSelected"), network: .unavailable("notSelected"))
        }
        let snapshot = await sample()
        return .init(system: system ? snapshot.system : .unavailable("notSelected"),
                     network: network ? snapshot.network : .unavailable("notSelected"))
    }
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
    let processes: any ProcessMetricsProviding

    static var live: ProviderSet {
        ProviderSet(cpu: CPUProvider(), memory: MemoryProvider(), network: NetworkProvider(),
                    disk: DiskProvider(), sensors: SystemSensorProvider(), processes: ProcessMetricsProvider())
    }
}

// Opening SMC can fail independently of every other provider. Defer opening to
// sampling so the engine can represent that error as an unavailable sensor.
actor SystemSensorProvider: SensorProviding {
    private let makeProvider: @Sendable () throws -> AppleSiliconSensorProvider
    private var provider: AppleSiliconSensorProvider?

    init(makeProvider: @escaping @Sendable () throws -> AppleSiliconSensorProvider = { try AppleSiliconSensorProvider() }) {
        self.makeProvider = makeProvider
    }

    func sample() throws -> ThermalMetric {
        if provider == nil { provider = try makeProvider() }
        return try provider!.sample()
    }

    func sample(temperature: Bool, fan: Bool) async -> SensorReadings {
        guard temperature || fan else {
            return .init(temperature: .unavailable("notSelected"), fan: .unavailable("notSelected"))
        }
        do {
            if provider == nil { provider = try makeProvider() }
            return await provider!.sample(temperature: temperature, fan: fan)
        } catch {
            return .init(temperature: temperature ? .unavailable("temperatureUnavailable") : .unavailable("notSelected"),
                         fan: fan ? .unavailable("fanUnavailable") : .unavailable("notSelected"))
        }
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

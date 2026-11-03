import Darwin

protocol CPUProviding: Sendable {
    /// 读取累计 CPU 时钟计数；监控引擎在 CPU 板块启用的每轮采样中调用。
    func sample() async throws -> CPUTicks
}

protocol MemoryProviding: Sendable {
    /// 读取当前内存用量；监控引擎在内存板块启用的每轮采样中调用。
    func sample() async throws -> MemoryMetric
}

protocol NetworkProviding: Sendable {
    /// 读取累计网络字节计数；上传或下载板块启用时由监控引擎调用。
    func sample() async throws -> NetworkCounters
}

protocol DiskProviding: Sendable {
    /// 读取系统启动卷容量；磁盘容量板块启用时由监控引擎调用。
    func sample() async throws -> DiskMetric
}

protocol SensorProviding: Sendable {
    /// 读取完整温度和风扇指标；兼容旧采样接口或全量传感器读取时调用。
    func sample() async throws -> ThermalMetric
    /// 按选择读取温度和风扇；监控引擎根据启用板块构建采样计划后调用。
    func sample(temperature: Bool, fan: Bool) async -> SensorReadings
}

extension SensorProviding {
    /// 为仅支持全量读取的传感器提供按需适配；具体提供器未重写选择性采样时调用。
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
    /// 读取全部进程系统与网络计数；兼容旧调用或全量进程采样时调用。
    func sample() async -> ProcessRawSnapshot
    /// 按需读取进程系统或网络计数；相应板块启用时由监控引擎调用。
    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot
    /// 取消进行中的进程采集；停止监控、切换板块或系统睡眠时调用。
    func cancel() async
}

extension ProcessMetricsProviding {
    /// 为仅支持全量读取的进程提供器过滤未选择结果；未实现按需接口的替身或兼容实现会调用。
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

    /// 组装生产环境全部系统采集器；MonitoringEngine 使用默认依赖初始化时读取。
    /// 通过协议存在类型保存不同实现，使引擎可注入独立替身并验证单项失败隔离。
    static var live: ProviderSet {
        // 应用启动时集中组装真实采集器，便于监控引擎和测试统一注入依赖。
        ProviderSet(cpu: CPUProvider(), memory: MemoryProvider(), network: NetworkProvider(),
                    disk: DiskProvider(), sensors: SystemSensorProvider(), processes: ProcessMetricsProvider())
    }
}

// SMC 打开失败不应影响其他采集器，因此延迟到采样时创建，并将失败转换为传感器不可用。
actor SystemSensorProvider: SensorProviding {
    private let makeProvider: @Sendable () throws -> AppleSiliconSensorProvider
    private var provider: AppleSiliconSensorProvider?

    /// 保存传感器工厂但不立即打开 SMC；应用组装或测试注入传感器时调用。
    init(makeProvider: @escaping @Sendable () throws -> AppleSiliconSensorProvider = { try AppleSiliconSensorProvider() }) {
        self.makeProvider = makeProvider
    }

    /// 延迟创建并读取完整传感器指标；兼容全量传感器接口时调用。
    func sample() throws -> ThermalMetric {
        if provider == nil { provider = try makeProvider() }
        return try provider!.sample()
    }

    /// 延迟创建并按选择读取传感器；温度或风扇板块启用的采样周期调用。
    /// Actor 串行保护惰性实例；初始化失败被转换为两个独立 Reading，而不会向上抛出并中断整轮采样。
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

    /// 校验 Mach 系统调用返回值；各底层采集器完成系统调用后立即调用。
    static func check(_ operation: String, result: kern_return_t) throws {
        guard result == KERN_SUCCESS else {
            throw machCallFailed(operation, result)
        }
    }
}

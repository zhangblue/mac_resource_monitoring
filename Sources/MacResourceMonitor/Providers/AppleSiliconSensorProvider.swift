import Foundation

enum SensorSelection {
    /// 从 SMC 的处理器温度键中选择最高可信值；温度采样完成后调用。
    /// 只接受 Tp 前缀、有限且位于 10...125°C 的值，并取最大值代表芯片热点温度。
    static func chipTemperature(_ values: [String: Double]) -> Double? {
        values.filter { $0.key.hasPrefix("Tp") && $0.value.isFinite && (10...125).contains($0.value) }
            .values.max()
    }
}

struct SensorReadings: Sendable {
    let temperature: Reading<Double>
    let fan: Reading<FanMetric>
}

struct AppleSiliconSensorProvider: Sendable {
    private let transport: any SMCTransport

    /// 使用可替换的 SMC 传输层初始化；系统提供器创建实例或测试注入模拟传输时调用。
    init(transport: any SMCTransport) {
        self.transport = transport
    }

    /// 打开真实 AppleSMC 连接；首次需要传感器数据时由延迟提供器调用。
    init() throws {
        transport = try SMCClient()
    }

    // 兼容旧全量采样语义：风扇失败抛错，温度失败仅返回空值。
    /// 读取完整温度和风扇数据；兼容全量传感器接口时调用。
    func sample() throws -> ThermalMetric {
        let fan = try readFan()
        return ThermalMetric(chipTemperatureCelsius: try? readTemperature(), fan: fan)
    }

    /// 按板块选择分别读取温度和风扇；监控引擎按需采样时调用，单项失败互不影响。
    /// 两个分支分别捕获错误并生成 Reading；未选择分支完全跳过 SMC 调用，满足按需采集。
    func sample(temperature: Bool, fan: Bool) async -> SensorReadings {
        let temperatureReading: Reading<Double>
        if temperature {
            do { temperatureReading = .value(try readTemperature()) }
            catch { temperatureReading = .unavailable("temperatureUnavailable") }
        } else {
            temperatureReading = .unavailable("notSelected")
        }
        let fanReading: Reading<FanMetric>
        if fan {
            do { fanReading = .value(try readFan()) }
            catch { fanReading = .unavailable("fanUnavailable") }
        } else {
            fanReading = .unavailable("notSelected")
        }
        return .init(temperature: temperatureReading, fan: fanReading)
    }

    /// 读取风扇数量及最高转速；风扇板块启用或全量传感器采样时调用。
    /// FNum 必须是 0...10 的整数，再读取每个 F{n}Ac；多风扇取最高 RPM，零风扇映射为 fanless。
    private func readFan() throws -> FanMetric {
        let fanCount = try transport.read("FNum").decoded()
        guard fanCount.isFinite, fanCount >= 0, fanCount <= 10,
              fanCount.rounded(.towardZero) == fanCount else {
            throw SMCError.invalidFanCount
        }
        if fanCount == 0 { return .fanless }
        var speeds: [Double] = []
        for index in 0..<Int(fanCount) {
            let key = "F\(index)Ac"
            let speed = try transport.read(key).decoded()
            guard speed.isFinite, speed >= 0 else { throw SMCError.invalidFanSpeed(key) }
            speeds.append(speed)
        }
        return .rpm(speeds.max()!)
    }

    private enum TemperatureError: Error { case noPlausibleReading }

    /// 汇总可信芯片温度；温度板块启用或全量传感器采样时调用。
    private func readTemperature() throws -> Double {
        var temperatures: [String: Double] = [:]
        // 单个温度键缺失不应遮蔽其他处理器温度，因此逐键容错读取。
        for key in try transport.allKeys() where key.hasPrefix("Tp") {
            if let value = try? transport.read(key).decoded() { temperatures[key] = value }
        }
        guard let temperature = SensorSelection.chipTemperature(temperatures) else {
            throw TemperatureError.noPlausibleReading
        }
        return temperature
    }
}

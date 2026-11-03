import Foundation

enum Reading<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable(String)
}

extension Reading {
    /// 提取成功采集的值；展示层和计算层需要忽略不可用原因时调用。
    /// 该计算属性利用枚举模式匹配把 Reading<Value> 安全降为可选值，不会吞并或改写原始失败原因。
    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    /// 判断本次采集是否不可用；状态展示或错误分支判断时调用。
    /// 判断只读取枚举分支，不触发采集、日志或其他副作用。
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

struct MemoryMetric: Equatable, Sendable {
    let usage: Double
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct NetworkMetric: Equatable, Sendable {
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
}

enum FanMetric: Equatable, Sendable {
    case rpm(Double)
    case fanless
}

struct ThermalMetric: Equatable, Sendable {
    let chipTemperatureCelsius: Double?
    let fan: FanMetric
}

struct DiskMetric: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct MetricSnapshot: Sendable {
    let timestamp: Date
    let cpuUsage: Reading<Double>
    let memory: Reading<MemoryMetric>
    let network: Reading<NetworkMetric>
    let thermal: Reading<ThermalMetric>
    // 兼容字段无法分别表达温度与风扇失败，因此同时保留拆分后的独立读数。
    let temperature: Reading<Double>
    let fan: Reading<FanMetric>
    let disk: Reading<DiskMetric>
    let processes: ProcessRankings

    /// 组装一次完整采样快照；监控引擎完成各采集器读取后调用，兼容字段缺省时从综合传感器结果推导。
    /// 快照是不可变的 Sendable 值，可安全跨 Actor 发布；独立温度/风扇读数优先于旧综合字段，避免单项失败相互覆盖。
    init(timestamp: Date, cpuUsage: Reading<Double>, memory: Reading<MemoryMetric>,
         network: Reading<NetworkMetric>, thermal: Reading<ThermalMetric>, disk: Reading<DiskMetric>,
         processes: ProcessRankings = .waiting(),
         temperature: Reading<Double>? = nil, fan: Reading<FanMetric>? = nil) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.memory = memory
        self.network = network
        self.thermal = thermal
        self.temperature = temperature ?? thermal.value?.chipTemperatureCelsius.map(Reading.value)
            ?? .unavailable("temperatureUnavailable")
        self.fan = fan ?? thermal.value.map { .value($0.fan) } ?? .unavailable("fanUnavailable")
        self.disk = disk
        self.processes = processes
    }
}

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let value: Double?
    let startsNewSegment: Bool

    /// 创建一个历史点；监控引擎追加趋势数据时调用，时间中断时通过 startsNewSegment 断开折线。
    /// nil 表示本次值不可用而非零值，UUID 仅供 SwiftUI 稳定标识，时间戳负责窗口裁剪和悬停定位。
    init(timestamp: Date, value: Double?, startsNewSegment: Bool = false) {
        self.timestamp = timestamp
        self.value = value
        self.startsNewSegment = startsNewSegment
    }
}

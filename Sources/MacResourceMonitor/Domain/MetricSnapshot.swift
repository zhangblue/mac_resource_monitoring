import Foundation

enum Reading<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable(String)
}

extension Reading {
    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }

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
    let disk: Reading<DiskMetric>
}

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let value: Double?
}

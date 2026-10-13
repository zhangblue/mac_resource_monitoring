import Foundation

struct MenuBarPresentation {
    let cpu: Reading<Double>
    let memory: Reading<Double>
    let upload: Reading<Double>
    let download: Reading<Double>

    init(cpu: Reading<Double>, memory: Reading<Double>, upload: Reading<Double>, download: Reading<Double>) {
        self.cpu = cpu
        self.memory = memory
        self.upload = upload
        self.download = download
    }

    init(snapshot: MetricSnapshot?) {
        cpu = snapshot?.cpuUsage ?? .unavailable("等待下一次采样")
        memory = snapshot?.memory.map(\.usage) ?? .unavailable("等待下一次采样")
        upload = snapshot?.network.map { $0.uploadBytesPerSecond }.flatMap ?? .unavailable("等待下一次采样")
        download = snapshot?.network.map { $0.downloadBytesPerSecond }.flatMap ?? .unavailable("等待下一次采样")
    }

    var text: String {
        "C \(Self.compactPercent(cpu))   M \(Self.compactPercent(memory))   ↑ \(Self.compactRate(upload))   ↓ \(Self.compactRate(download))"
    }

    static func compactPercent(_ reading: Reading<Double>) -> String {
        guard let value = reading.value else { return "—" }
        return MetricFormatter.percent(value * 100)
    }

    static func compactRate(_ reading: Reading<Double>) -> String {
        guard let value = reading.value else { return "—" }
        return MetricFormatter.menuRate(value)
    }
}

extension Reading {
    func map<Output: Sendable>(_ transform: (Value) -> Output) -> Reading<Output> {
        switch self {
        case let .value(value): return .value(transform(value))
        case let .unavailable(reason): return .unavailable(reason)
        }
    }
}

private extension Reading where Value == Double? {
    var flatMap: Reading<Double> {
        switch self {
        case let .value(value):
            return value.map(Reading<Double>.value) ?? .unavailable("等待下一次采样")
        case let .unavailable(reason): return .unavailable(reason)
        }
    }
}

struct SparklinePresentation {
    let segments: [[HistoryPoint]]
    let timeDomain: ClosedRange<Date>

    var visibleValues: [Double] { segments.flatMap { $0.compactMap(\.value) } }

    init(points: [HistoryPoint], historyDuration: HistoryDuration, refreshInterval: RefreshInterval) {
        var segments: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        let end = points.last?.timestamp ?? .distantPast
        let cutoff = end.addingTimeInterval(-TimeInterval(historyDuration.rawValue))
        timeDomain = cutoff...end
        let discontinuityThreshold = TimeInterval(refreshInterval.rawValue * 3)
        for point in points {
            // Allow up to three expected intervals of jitter, but split duplicate
            // and backward wall-clock timestamps as well as longer gaps.
            if let previous = current.last {
                let interval = point.timestamp.timeIntervalSince(previous.timestamp)
                if point.startsNewSegment || interval <= 0 || interval > discontinuityThreshold {
                    segments.append(current)
                    current = []
                }
            }
            if let value = point.value, value.isFinite {
                current.append(point)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        // Detect discontinuities before clipping: an excluded future sample can
        // still establish a rollback into the visible window.
        self.segments = segments.map { segment in
            segment.filter { $0.timestamp >= cutoff && $0.timestamp <= end }
        }.filter { !$0.isEmpty }
    }
}

enum MetricPresentation {
    static func status<Value>(for reading: Reading<Value>?, historyDuration: HistoryDuration) -> String {
        guard let reading else { return "等待下一次采样" }
        switch reading {
        case .value: return historyDuration.recentLabel
        case let .unavailable(reason):
            return reason == "等待 CPU 采样基线" ? "等待下一次采样" : "暂不可用"
        }
    }

    static func temperatureStatus(for reading: Reading<ThermalMetric>?) -> String {
        guard let reading else { return "等待下一次采样" }
        switch reading {
        case .unavailable: return "暂不可用"
        case let .value(thermal):
            return thermal.temperature.value.map { (10...125).contains($0) && $0.isFinite } == true
                ? "" : "暂不可用"
        }
    }

    static func temperatureText(for reading: Reading<ThermalMetric>?) -> String {
        guard let value = reading?.value?.temperature.value,
              value.isFinite, (10...125).contains(value) else { return "—" }
        return String(format: "%.0f °C", value)
    }

    static func fanStatus(for reading: Reading<ThermalMetric>?) -> String {
        guard let reading else { return "等待下一次采样" }
        guard let fan = reading.value?.fan.value else { return "暂不可用" }
        switch fan {
        case let .rpm(value): return value.isFinite && value >= 0 ? "" : "暂不可用"
        case .fanless: return ""
        }
    }

    static func fanText(for reading: Reading<ThermalMetric>?) -> String {
        guard let fan = reading?.value?.fan.value else { return "—" }
        switch fan {
        case let .rpm(value): return value.isFinite && value >= 0 ? MetricFormatter.rpm(value) : "—"
        case .fanless: return "无风扇"
        }
    }
}

struct DiskPresentation {
    let status: String
    let capacityText: String
    let usedFraction: Double?

    init(reading: Reading<DiskMetric>?) {
        guard let reading else {
            status = "等待下一次采样"
            capacityText = "—"
            usedFraction = nil
            return
        }
        switch reading {
        case .unavailable:
            status = "暂不可用"
            capacityText = "—"
            usedFraction = nil
        case let .value(disk):
            status = ""
            capacityText = "已用 \(MetricFormatter.memory(disk.usedBytes)) / \(MetricFormatter.memory(disk.totalBytes))"
            usedFraction = disk.totalBytes == 0
                ? 0 : min(Double(disk.usedBytes) / Double(disk.totalBytes), 1)
        }
    }
}

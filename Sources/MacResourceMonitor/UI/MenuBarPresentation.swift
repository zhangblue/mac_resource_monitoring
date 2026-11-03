import Foundation

struct MenuBarPresentation {
    let cpu: Reading<Double>
    let memory: Reading<Double>
    let upload: Reading<Double>
    let download: Reading<Double>
    let selection: MetricSelection

    /// 使用四类已格式化前的读数构造菜单栏模型；单元测试或明确提供读数时调用。
    init(cpu: Reading<Double>, memory: Reading<Double>, upload: Reading<Double>, download: Reading<Double>,
         selection: MetricSelection = .all) {
        self.cpu = cpu
        self.memory = memory
        self.upload = upload
        self.download = download
        self.selection = selection
    }

    /// 从最新快照构造菜单栏模型；菜单栏标签每次刷新时调用。
    /// 通过 Reading.map 提取复合字段并保留失败原因，网络可选方向再由 flatMap 转成等待状态。
    init(snapshot: MetricSnapshot?, selection: MetricSelection = .all) {
        self.selection = selection
        cpu = snapshot?.cpuUsage ?? .unavailable("等待下一次采样")
        memory = snapshot?.memory.map(\.usage) ?? .unavailable("等待下一次采样")
        upload = snapshot?.network.map { $0.uploadBytesPerSecond }.flatMap ?? .unavailable("等待下一次采样")
        download = snapshot?.network.map { $0.downloadBytesPerSecond }.flatMap ?? .unavailable("等待下一次采样")
    }

    /// 生成仅包含已选择 CPU、内存、上传和下载的菜单栏文本；菜单栏标签渲染时读取。
    /// 按固定枚举顺序拼接短字段；全部关闭时保留“监控”文字，确保 MenuBarExtra 仍有可点击区域。
    var text: String {
        var parts: [String] = []
        if selection.contains(.cpu) { parts.append("C \(Self.compactPercent(cpu))") }
        if selection.contains(.memory) { parts.append("M \(Self.compactPercent(memory))") }
        if selection.contains(.upload) { parts.append("↑ \(Self.compactRate(upload))") }
        if selection.contains(.download) { parts.append("↓ \(Self.compactRate(download))") }
        return parts.isEmpty ? "监控" : parts.joined(separator: "   ")
    }

    /// 将比例 Reading 压缩为菜单栏百分比；拼接 CPU 或内存文本时调用。
    static func compactPercent(_ reading: Reading<Double>) -> String {
        guard let value = reading.value else { return "—" }
        return MetricFormatter.percent(value * 100)
    }

    /// 将速率 Reading 压缩为菜单栏短单位；拼接上传或下载文本时调用。
    static func compactRate(_ reading: Reading<Double>) -> String {
        guard let value = reading.value else { return "—" }
        return MetricFormatter.menuRate(value)
    }
}

extension Reading {
    /// 保留不可用原因并映射成功值；从复合指标提取展示字段时调用。
    func map<Output: Sendable>(_ transform: (Value) -> Output) -> Reading<Output> {
        switch self {
        case let .value(value): return .value(transform(value))
        case let .unavailable(reason): return .unavailable(reason)
        }
    }
}

private extension Reading where Value == Double? {
    /// 将成功但为空的可选数值转换为等待状态；提取网络方向速率时读取。
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

    /// 汇总所有可绘制数值；动态计算纵轴范围时读取。
    var visibleValues: [Double] { segments.flatMap { $0.compactMap(\.value) } }

    /// 按时间窗口和采样间隔切分连续线段；趋势图每次渲染时调用。
    /// nil/非有限值、重复或回拨时间、超过三倍刷新间隔都会断段；裁剪后仅保留闭区间内有效点。
    init(points: [HistoryPoint], historyDuration: HistoryDuration, refreshInterval: RefreshInterval) {
        var segments: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        let end = points.last?.timestamp ?? .distantPast
        let cutoff = end.addingTimeInterval(-TimeInterval(historyDuration.rawValue))
        timeDomain = cutoff...end
        let discontinuityThreshold = TimeInterval(refreshInterval.rawValue * 3)
        for point in points {
            // 容许三个采样间隔内的抖动；重复、回拨时间或更长间隔必须断开折线。
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
        // 先识别中断再裁剪，窗口外的未来点仍可能证明可见区域发生过时间回拨。
        self.segments = segments.map { segment in
            segment.filter { $0.timestamp >= cutoff && $0.timestamp <= end }
        }.filter { !$0.isEmpty }
    }
}

enum MetricPresentation {
    /// 将通用指标读数转换为状态文字；各详情卡片刷新说明文字时调用。
    static func status<Value>(for reading: Reading<Value>?, historyDuration: HistoryDuration) -> String {
        guard let reading else { return "等待下一次采样" }
        switch reading {
        case .value: return historyDuration.recentLabel
        case let .unavailable(reason):
            return reason == "等待 CPU 采样基线" ? "等待下一次采样" : "暂不可用"
        }
    }

    /// 判断独立温度读数是否可展示；温度卡片刷新状态时调用。
    static func temperatureReadingStatus(for reading: Reading<Double>?) -> String {
        guard let reading else { return "等待下一次采样" }
        guard let value = reading.value, value.isFinite else { return "暂不可用" }
        return ""
    }

    /// 判断兼容综合传感器读数是否含有效温度；旧展示路径或测试验证时调用。
    static func temperatureStatus(for reading: Reading<ThermalMetric>?) -> String {
        guard let reading else { return "等待下一次采样" }
        switch reading {
        case .unavailable: return "暂不可用"
        case let .value(thermal):
            guard let temperature = thermal.chipTemperatureCelsius,
                  temperature.isFinite else { return "暂不可用" }
            return ""
        }
    }
}

struct DiskPresentation {
    let status: String
    let capacityText: String
    let usedFraction: Double?

    /// 将磁盘 Reading 转换为状态、容量和进度比例；磁盘卡片刷新时调用。
    /// Presentation 是纯值转换，不保存状态；total 为零时比例为零，其余结果钳制到 1 防止异常属性破坏进度条。
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

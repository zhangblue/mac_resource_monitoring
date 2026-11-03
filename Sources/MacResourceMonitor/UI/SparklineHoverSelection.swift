import Foundation

struct SparklineHoverSelection: Equatable {
    let timestamp: Date
    let value: Double

    /// 查找时间上最接近鼠标位置的有效历史点；折线图悬停位置变化时调用。
    /// 单次 O(n) 扫描忽略 nil 和非有限值；等距离时选择较新点，保证向右移动时结果稳定。
    init?(nearestTo target: Date, points: [HistoryPoint]) {
        var nearest: (timestamp: Date, value: Double)?

        for point in points {
            guard let value = point.value, value.isFinite else { continue }
            guard let current = nearest else {
                nearest = (point.timestamp, value)
                continue
            }

            let candidateDistance = abs(point.timestamp.timeIntervalSince(target))
            let currentDistance = abs(current.timestamp.timeIntervalSince(target))
            if candidateDistance < currentDistance
                || (candidateDistance == currentDistance && point.timestamp > current.timestamp) {
                nearest = (point.timestamp, value)
            }
        }

        guard let nearest else { return nil }
        timestamp = nearest.timestamp
        value = nearest.value
    }

    /// 按纵轴类型格式化选中数值；悬停提示框渲染时调用。
    func valueLabel(for kind: SparklineAxisKind) -> String {
        switch kind {
        case .percentage: return MetricFormatter.percent(value * 100)
        case .rate: return MetricFormatter.rate(value)
        }
    }

    /// 将选中时间格式化为相对当前点的中文描述；悬停提示框渲染时调用。
    func timeLabel(relativeTo referenceDate: Date) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(timestamp).rounded()))
        guard seconds > 0 else { return "现在" }
        guard seconds >= 60 else { return "\(seconds) 秒前" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) 分钟前" : "\(minutes) 分 \(remainder) 秒前"
    }
}

import Foundation

struct SparklineHoverSelection: Equatable {
    let timestamp: Date
    let value: Double

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

    func valueLabel(for kind: SparklineAxisKind) -> String {
        switch kind {
        case .percentage: return MetricFormatter.percent(value * 100)
        case .rate: return MetricFormatter.rate(value)
        }
    }

    func timeLabel(relativeTo referenceDate: Date) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(timestamp).rounded()))
        guard seconds > 0 else { return "现在" }
        guard seconds >= 60 else { return "\(seconds) 秒前" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) 分钟前" : "\(minutes) 分 \(remainder) 秒前"
    }
}

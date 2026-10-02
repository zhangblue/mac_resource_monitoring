import SwiftUI

struct MetricCardView: View {
    let title: String
    let value: String
    let detail: String
    let points: [HistoryPoint]?
    let sparklineStyle: SparklineStyle?
    let historyDuration: HistoryDuration?
    let refreshInterval: RefreshInterval?

    init(title: String, value: String, detail: String) {
        self.title = title
        self.value = value
        self.detail = detail
        self.points = nil
        self.sparklineStyle = nil
        self.historyDuration = nil
        self.refreshInterval = nil
    }

    init(title: String, value: String, detail: String, points: [HistoryPoint], sparklineStyle: SparklineStyle,
         historyDuration: HistoryDuration, refreshInterval: RefreshInterval) {
        self.title = title
        self.value = value
        self.detail = detail
        self.points = points
        self.sparklineStyle = sparklineStyle
        self.historyDuration = historyDuration
        self.refreshInterval = refreshInterval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let points, let sparklineStyle, let historyDuration, let refreshInterval {
                SparklineView(points: points, style: sparklineStyle,
                              emptyMessage: detail == "暂不可用" ? "暂不可用" : "等待下一次采样",
                              historyDuration: historyDuration, refreshInterval: refreshInterval)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

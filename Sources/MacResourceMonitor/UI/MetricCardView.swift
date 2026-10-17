import SwiftUI

struct MetricCardView: View {
    let title: String
    let value: String
    let detail: String
    let points: [HistoryPoint]?
    let sparklineStyle: SparklineStyle?
    let historyDuration: HistoryDuration?
    let refreshInterval: RefreshInterval?
    let processes: Reading<[ProcessRankingEntry]>?
    let processStyle: ProcessRankingStyle?

    init(title: String, value: String, detail: String) {
        self.title = title
        self.value = value
        self.detail = detail
        self.points = nil
        self.sparklineStyle = nil
        self.historyDuration = nil
        self.refreshInterval = nil
        self.processes = nil
        self.processStyle = nil
    }

    init(title: String, value: String, detail: String, points: [HistoryPoint], sparklineStyle: SparklineStyle,
         historyDuration: HistoryDuration, refreshInterval: RefreshInterval,
         processes: Reading<[ProcessRankingEntry]>?, processStyle: ProcessRankingStyle) {
        self.title = title
        self.value = value
        self.detail = detail
        self.points = points
        self.sparklineStyle = sparklineStyle
        self.historyDuration = historyDuration
        self.refreshInterval = refreshInterval
        self.processes = processes
        self.processStyle = processStyle
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
            if let processStyle {
                Divider()
                ProcessRankingView(processes: processes, style: processStyle)
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

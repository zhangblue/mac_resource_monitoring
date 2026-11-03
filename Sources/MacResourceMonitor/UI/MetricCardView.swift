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

    /// 创建无趋势和进程榜单的简洁卡片；温度或风扇板块渲染时调用。
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

    /// 创建包含趋势和 Top 5 榜单的指标卡片；CPU、内存或网络板块渲染时调用。
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

    /// 构建卡片内容并按配置选择趋势和进程榜单；SwiftUI 刷新详情卡片时调用。
    /// 两个初始化器用可选字段表达卡片能力，body 通过可选绑定条件组合子视图，避免为传感器创建无意义图表状态。
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
                // 仅对具备历史数据配置的指标创建折线图，传感器卡片不会触发此路径。
                SparklineView(points: points, style: sparklineStyle,
                              emptyMessage: detail == "暂不可用" ? "暂不可用" : "等待下一次采样",
                              historyDuration: historyDuration, refreshInterval: refreshInterval)
            }
            if let processStyle {
                Divider()
                // Top 5 仅用于 CPU、内存和网络板块，并始终保持五行高度。
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

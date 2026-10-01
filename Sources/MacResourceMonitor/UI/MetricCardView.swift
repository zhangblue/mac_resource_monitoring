import SwiftUI

struct MetricCardView: View {
    let title: String
    let value: String
    let detail: String
    var points: [HistoryPoint]? = nil
    var fixedRange: ClosedRange<Double>? = nil

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
            if let points {
                SparklineView(points: points, fixedRange: fixedRange,
                              emptyMessage: detail == "暂不可用" ? "暂不可用" : "等待下一次采样")
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

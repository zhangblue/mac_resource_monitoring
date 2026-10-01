import Charts
import SwiftUI

struct SparklineView: View {
    let points: [HistoryPoint]
    let fixedRange: ClosedRange<Double>?
    let emptyMessage: String

    private var segments: [[HistoryPoint]] { SparklinePresentation(points: points).segments }

    var body: some View {
        Group {
            if segments.isEmpty {
                HStack(spacing: 6) {
                    Text("—")
                    Text(emptyMessage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart {
                    ForEach(segments.indices, id: \.self) { segmentIndex in
                        ForEach(segments[segmentIndex]) { point in
                            if let value = point.value {
                                if segments[segmentIndex].count == 1 {
                                    PointMark(x: .value("时间", point.timestamp), y: .value("数值", value))
                                        .foregroundStyle(Color.accentColor)
                                } else {
                                    LineMark(
                                        x: .value("时间", point.timestamp),
                                        y: .value("数值", value),
                                        series: .value("段", segmentIndex)
                                    )
                                    .interpolationMethod(.linear)
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: (points.last?.timestamp.addingTimeInterval(-300) ?? .distantPast)...(points.last?.timestamp ?? Date()))
                .modifier(ChartRangeModifier(range: fixedRange))
                .accessibilityLabel("最近五分钟趋势")
            }
        }
        .frame(height: 40)
    }
}

private struct ChartRangeModifier: ViewModifier {
    let range: ClosedRange<Double>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let range {
            content.chartYScale(domain: range)
        } else {
            content
        }
    }
}

import Charts
import SwiftUI

enum SparklineStyle {
    case cpu, memory, upload, download

    var axisKind: SparklineAxisKind {
        switch self {
        case .cpu, .memory: return .percentage
        case .upload, .download: return .rate
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .purple
        case .upload: return .orange
        case .download: return .green
        }
    }

    var name: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .upload: return "上传"
        case .download: return "下载"
        }
    }
}

struct SparklineView: View {
    let points: [HistoryPoint]
    let style: SparklineStyle
    let emptyMessage: String
    let historyDuration: HistoryDuration
    let refreshInterval: RefreshInterval

    var body: some View {
        let presentation = SparklinePresentation(points: points, historyDuration: historyDuration,
                                                 refreshInterval: refreshInterval)
        let segments = presentation.segments
        let axis = SparklineAxisPresentation(values: presentation.visibleValues, kind: style.axisKind)

        Group {
            if segments.isEmpty || axis == nil {
                HStack(spacing: 6) {
                    Text("—")
                    Text(emptyMessage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let axis {
                Chart {
                    ForEach(segments.indices, id: \.self) { segmentIndex in
                        ForEach(segments[segmentIndex]) { point in
                            if let value = point.value {
                                if segments[segmentIndex].count == 1 {
                                    PointMark(x: .value("时间", point.timestamp), y: .value("数值", value))
                                        .foregroundStyle(style.tint)
                                } else {
                                    LineMark(
                                        x: .value("时间", point.timestamp),
                                        y: .value("数值", value),
                                        series: .value("段", segmentIndex)
                                    )
                                    .interpolationMethod(.linear)
                                    .foregroundStyle(style.tint)
                                }
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: axis.domain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: axis.ticks) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let tick = value.as(Double.self),
                               let index = axis.ticks.firstIndex(where: { abs($0 - tick) < 0.000_001 }) {
                                Text(axis.labels[index])
                            }
                        }
                    }
                }
                .chartXScale(domain: presentation.timeDomain)
                .accessibilityLabel("\(style.name)\(historyDuration.recentLabel)趋势，纵轴范围 \(axis.labels[0]) 至 \(axis.labels[2])")
            }
        }
        .frame(height: 64)
    }
}

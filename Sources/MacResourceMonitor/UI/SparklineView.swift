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
    @State private var hoverTarget: Date?

    var body: some View {
        let presentation = SparklinePresentation(points: points, historyDuration: historyDuration,
                                                 refreshInterval: refreshInterval)
        let hoverPoints = presentation.segments.flatMap { $0 }
        let hoverSelection = hoverTarget.flatMap {
            SparklineHoverSelection(nearestTo: $0, points: hoverPoints)
        }
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
                    if let hoverSelection {
                        RuleMark(x: .value("悬停时间", hoverSelection.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.55))
                        PointMark(
                            x: .value("悬停时间", hoverSelection.timestamp),
                            y: .value("悬停数值", hoverSelection.value)
                        )
                        .symbolSize(34)
                        .foregroundStyle(style.tint)
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: axis.domain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: axis.ticks) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75))
                            .foregroundStyle(.secondary.opacity(0.32))
                        AxisValueLabel {
                            if let tick = value.as(Double.self),
                               let index = axis.ticks.firstIndex(where: { abs($0 - tick) < 0.000_001 }) {
                                Text(axis.labels[index])
                            }
                        }
                    }
                }
                .chartXScale(domain: presentation.timeDomain)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plotFrame = geometry[proxy.plotAreaFrame]
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        guard plotFrame.contains(location),
                                              let target = proxy.value(
                                                  atX: location.x - plotFrame.minX,
                                                  as: Date.self
                                              ) else {
                                            hoverTarget = nil
                                            return
                                        }
                                        hoverTarget = target
                                    case .ended:
                                        hoverTarget = nil
                                    }
                                }

                            if let hoverSelection,
                               let pointX = proxy.position(forX: hoverSelection.timestamp),
                               let pointY = proxy.position(forY: hoverSelection.value) {
                                hoverTooltip(for: hoverSelection, referenceDate: presentation.timeDomain.upperBound)
                                    .frame(width: 108, alignment: .leading)
                                    .position(
                                        x: tooltipX(pointX: plotFrame.minX + pointX, plotFrame: plotFrame),
                                        y: max(plotFrame.minY + 18, plotFrame.minY + pointY - 22)
                                    )
                            }
                        }
                    }
                }
                .onChange(of: historyDuration) { _ in hoverTarget = nil }
                .onChange(of: refreshInterval) { _ in hoverTarget = nil }
                .accessibilityLabel("\(style.name)\(historyDuration.recentLabel)趋势，纵轴范围 \(axis.labels[0]) 至 \(axis.labels[2])")
            }
        }
        .frame(height: 64)
    }

    private let tooltipWidth: CGFloat = 108

    private func tooltipX(pointX: CGFloat, plotFrame: CGRect) -> CGFloat {
        let halfWidth = tooltipWidth / 2
        let proposed = pointX <= plotFrame.midX
            ? pointX + halfWidth + 8
            : pointX - halfWidth - 8
        return min(max(proposed, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
    }

    private func hoverTooltip(for selection: SparklineHoverSelection, referenceDate: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(selection.timeLabel(relativeTo: referenceDate))
                .foregroundStyle(.secondary)
            Text(selection.valueLabel(for: style.axisKind))
                .fontWeight(.medium)
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

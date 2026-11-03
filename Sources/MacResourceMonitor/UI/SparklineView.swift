import AppKit
import Charts
import SwiftUI

enum SparklineStyle {
    case cpu, memory, upload, download

    /// 返回对应纵轴类型；折线图计算动态刻度时读取。
    var axisKind: SparklineAxisKind {
        switch self {
        case .cpu, .memory: return .percentage
        case .upload, .download: return .rate
        }
    }

    /// 返回指标主题色；绘制折线和悬停点时读取。
    var tint: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .purple
        case .upload: return .orange
        case .download: return .green
        }
    }

    /// 返回辅助功能使用的指标名称；生成趋势图描述时读取。
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
    @State private var hoverPosition: SparklineHoverPosition?
    @State private var hoverPlotFrame: CGRect = .zero

    /// 构建动态纵轴、折线和悬停交互；指标卡片刷新趋势时由 SwiftUI 调用。
    /// Swift Charts 使用显式时间 domain 与动态 y domain；分段数据使用 series 区分，避免采样空洞被 LineMark 自动连接。
    var body: some View {
        let presentation = SparklinePresentation(points: points, historyDuration: historyDuration,
                                                 refreshInterval: refreshInterval)
        let hoverPoints = presentation.segments.flatMap { $0 }
        // 先把鼠标横坐标映射为时间，再选择最接近的有效历史点。
        let hoverSelection = hoverPosition.flatMap {
            $0.timestamp(in: presentation.timeDomain, plotFrame: hoverPlotFrame)
        }.flatMap {
            SparklineHoverSelection(nearestTo: $0, points: hoverPoints)
        }
        let segments = presentation.segments
        let axis = SparklineAxisPresentation(values: presentation.visibleValues, kind: style.axisKind)
        let isEmpty = segments.isEmpty || axis == nil

        Group {
            if isEmpty {
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
                        let overlaySelection = hoverPosition.flatMap {
                            $0.timestamp(in: presentation.timeDomain, plotFrame: plotFrame)
                        }.flatMap {
                            SparklineHoverSelection(nearestTo: $0, points: hoverPoints)
                        }
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                // 连续悬停仅更新轻量位置状态，避免焦点切换时保留旧提示。
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        hoverPlotFrame = plotFrame
                                        hoverPosition = SparklineHoverPosition(location: location)
                                    case .ended:
                                        hoverPosition = nil
                                    }
                                }

                            if let overlaySelection,
                               let pointX = proxy.position(forX: overlaySelection.timestamp),
                               let pointY = proxy.position(forY: overlaySelection.value) {
                                // 根据数据点所在半区把提示框放到另一侧，避免遮挡曲线且不越界。
                                let tooltipLayout = SparklineHoverTooltipLayout(
                                    pointX: plotFrame.minX + pointX, plotFrame: plotFrame
                                )
                                hoverTooltip(for: overlaySelection, referenceDate: presentation.timeDomain.upperBound)
                                    .frame(width: tooltipLayout.width, alignment: .leading)
                                    .position(
                                        x: tooltipLayout.centerX,
                                        y: max(plotFrame.minY + 18, plotFrame.minY + pointY - 22)
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { hoverPlotFrame = plotFrame }
                        .onChange(of: plotFrame) { hoverPlotFrame = $0 }
                    }
                }
                .background(SparklineWindowFocusObserver { hoverPosition = nil })
                .onChange(of: historyDuration) { _ in hoverPosition = nil }
                .onChange(of: refreshInterval) { _ in hoverPosition = nil }
                .accessibilityLabel("\(style.name)\(historyDuration.recentLabel)趋势，纵轴范围 \(axis.labels[0]) 至 \(axis.labels[2])")
            }
        }
        .frame(height: 64)
        .onDisappear { hoverPosition = nil }
        .onChange(of: isEmpty) { empty in
            if empty { hoverPosition = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hoverPosition = nil
        }
    }

    /// 构建悬停时间与数值提示；找到有效悬停点后调用。
    /// 提示框使用 monospacedDigit 降低数字变化引起的宽度抖动，并关闭命中测试避免抢占图表悬停事件。
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

private struct SparklineWindowFocusObserver: NSViewRepresentable {
    let onFocusLost: () -> Void

    /// 创建用于监听菜单栏窗口失焦的 AppKit 视图；SwiftUI 首次挂载观察器时调用。
    /// NSViewRepresentable 桥接 AppKit 窗口通知，因为纯 SwiftUI hover 在菜单栏面板失焦隐藏时不一定收到 ended。
    func makeNSView(context: Context) -> FocusObservationView {
        let view = FocusObservationView(frame: .zero)
        view.onFocusLost = onFocusLost
        return view
    }

    /// 更新失焦回调；SwiftUI 重建父视图但复用 NSView 时调用。
    func updateNSView(_ nsView: FocusObservationView, context: Context) {
        nsView.onFocusLost = onFocusLost
    }

    /// 移除窗口通知观察；SwiftUI 卸载观察器时调用。
    static func dismantleNSView(_ nsView: FocusObservationView, coordinator: ()) {
        nsView.stopObserving()
        nsView.onFocusLost = nil
    }

    final class FocusObservationView: NSView {
        var onFocusLost: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        /// 切换所属窗口后重建通知观察；AppKit 将视图挂入或移出窗口时调用。
        /// 每次先移除旧 token，再只观察当前 window 的 resignKey/close，避免跨面板通知和观察者泄漏。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // 窗口失去关键状态或关闭时清除悬停，避免面板再次出现旧提示。
                    self?.onFocusLost?()
                }
            }
        }

        /// 停止并清空全部窗口观察；视图换窗或被拆除时调用。
        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

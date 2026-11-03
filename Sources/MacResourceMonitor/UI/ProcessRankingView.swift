import SwiftUI

enum ProcessRankingStyle {
    case cpu, memory, upload, download

    /// 按榜单类型格式化数值；构建每条进程展示行时调用。
    func format(_ value: Double) -> String {
        switch self {
        case .cpu:
            return MetricFormatter.processPercent(value)
        case .memory:
            guard value.isFinite, value > 0 else { return MetricFormatter.memory(0) }
            let bytes = value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
            return MetricFormatter.memory(bytes)
        case .upload, .download:
            return MetricFormatter.rate(value)
        }
    }
}

enum ProcessRankingContent: Equatable {
    case rows([ProcessRankingRow])
    case message(String)
}

struct ProcessRankingRow: Identifiable, Equatable {
    let id: ProcessIdentity
    let rank: Int
    let displayName: String
    let pidSuffix: String?
    let formattedValue: String
}

struct ProcessRankingSlot: Identifiable, Equatable {
    enum Content: Equatable {
        case process(ProcessRankingRow)
        case message(String)
        case empty
    }

    let id: Int
    let content: Content
}

struct ProcessRankingPresentation {
    let content: ProcessRankingContent
    let slots: [ProcessRankingSlot]

    /// 将进程 Reading 转换为最多五行的稳定展示模型；榜单视图每次渲染时调用。
    /// 只统计可见 Top 5 的重名并附加 PID；状态消息与数据行最终都归一为固定槽位数组。
    init(reading: Reading<[ProcessRankingEntry]>?, style: ProcessRankingStyle) {
        let content: ProcessRankingContent
        switch reading {
        case nil:
            content = .message("等待下一次采样")
        case let .unavailable(reason):
            content = .message(reason == "等待进程采样基线" ? "等待下一次采样" : "暂不可用")
        case let .value(entries):
            let visible = Array(entries.prefix(5))
            guard !visible.isEmpty else {
                self.content = .message("暂无活动进程")
                self.slots = Self.makeSlots(for: self.content)
                return
            }
            let nameCounts = Dictionary(grouping: visible, by: \.name).mapValues(\.count)
            content = .rows(visible.enumerated().map { index, entry in
                let pidSuffix = nameCounts[entry.name, default: 0] > 1
                    ? "(\(entry.identity.pid))" : nil
                return .init(id: entry.identity, rank: index + 1, displayName: entry.name, pidSuffix: pidSuffix,
                             formattedValue: style.format(entry.value))
            })
        }
        self.content = content
        slots = Self.makeSlots(for: content)
    }

    /// 补齐固定五个展示槽位；榜单有数据、无数据或不可用时均调用以保持卡片高度。
    /// 槽位 ID 固定为 0...4，空位使用透明行，避免 SwiftUI diff 时行身份和卡片高度抖动。
    private static func makeSlots(for content: ProcessRankingContent) -> [ProcessRankingSlot] {
        let filled: [ProcessRankingSlot.Content]
        switch content {
        case let .rows(rows):
            filled = rows.map(ProcessRankingSlot.Content.process)
        case let .message(message):
            filled = [.message(message)]
        }
        return (0..<5).map { index in
            .init(id: index, content: index < filled.count ? filled[index] : .empty)
        }
    }
}

struct ProcessRankingView: View {
    let processes: Reading<[ProcessRankingEntry]>?
    let style: ProcessRankingStyle

    /// 构建固定五行的进程榜单；指标卡片需要展示 Top 5 时由 SwiftUI 调用。
    var body: some View {
        let presentation = ProcessRankingPresentation(reading: processes, style: style)
        VStack(alignment: .leading, spacing: 5) {
            Text("进程 Top 5")
                .foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(presentation.slots) { slot in
                    switch slot.content {
                    case let .process(row):
                        GridRow {
                            Text("\(row.rank)")
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .leading)
                            HStack(spacing: 2) {
                                Text(row.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if let suffix = row.pidSuffix {
                                    Text(suffix)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.formattedValue)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: 12)
                    case let .message(message):
                        GridRow {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridCellColumns(3)
                        }
                        .frame(height: 12)
                    case .empty:
                        GridRow {
                            Color.clear
                                .frame(height: 12)
                                .gridCellColumns(3)
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

enum ProcessRankingStyle {
    case cpu, memory, upload, download

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

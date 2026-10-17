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

struct ProcessRankingPresentation {
    let content: ProcessRankingContent

    init(reading: Reading<[ProcessRankingEntry]>?, style: ProcessRankingStyle) {
        switch reading {
        case nil:
            content = .message("等待下一次采样")
        case let .unavailable(reason):
            content = .message(reason == "等待进程采样基线" ? "等待下一次采样" : "暂不可用")
        case let .value(entries):
            let visible = Array(entries.prefix(5))
            guard !visible.isEmpty else {
                content = .message("暂无活动进程")
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
    }
}

struct ProcessRankingView: View {
    let processes: Reading<[ProcessRankingEntry]>?
    let style: ProcessRankingStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("进程 Top 5")
                .foregroundStyle(.secondary)
            switch ProcessRankingPresentation(reading: processes, style: style).content {
            case let .rows(rows):
                Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(rows) { row in
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
                    }
                }
            case let .message(message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

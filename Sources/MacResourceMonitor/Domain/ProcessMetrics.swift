import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
}

struct ProcessSystemCounter: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
}

struct ProcessNetworkCounter: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct ProcessRankingEntry: Identifiable, Equatable, Sendable {
    /// 使用 PID 与启动时间组成稳定行标识；SwiftUI 渲染榜单时读取。
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let name: String
    let value: Double
}

struct ProcessRankings: Sendable {
    let cpu: Reading<[ProcessRankingEntry]>
    let memory: Reading<[ProcessRankingEntry]>
    let upload: Reading<[ProcessRankingEntry]>
    let download: Reading<[ProcessRankingEntry]>

    /// 生成尚未建立差值基线的占位排名；首次采样或重置基线后调用。
    static func waiting(_ reason: String = "等待进程采样基线") -> Self {
        .init(cpu: .unavailable(reason), memory: .unavailable(reason),
              upload: .unavailable(reason), download: .unavailable(reason))
    }
}

struct ProcessRawSnapshot: Sendable {
    let system: Reading<[ProcessSystemCounter]>
    let network: Reading<[ProcessNetworkCounter]>
}

struct ProcessRankingCalculator {
    private var previousSystem: (counters: [ProcessIdentity: ProcessSystemCounter], timestamp: Date)?
    private var previousNetwork: (counters: [ProcessIdentity: ProcessNetworkCounter], timestamp: Date)?

    /// 同时清除系统与网络速率基线；停止监控、睡眠或整体重置时调用。
    mutating func resetRates() {
        resetSystemRates()
        resetNetworkRates()
    }

    /// 仅清除 CPU 进程速率基线；CPU/内存采样被停用或重新启用时调用。
    mutating func resetSystemRates() { previousSystem = nil }
    /// 仅清除网络进程速率基线；上传/下载采样被停用或重新启用时调用。
    mutating func resetNetworkRates() { previousNetwork = nil }

    /// 将当前进程累计计数转换为四类 Top 5；每次进程采样完成后调用，并保存本次计数供下次计算差值。
    /// CPU 输入单位为纳秒累计值、网络为累计字节；速率通过相邻时间戳差计算，内存则直接使用本轮常驻字节。
    mutating func update(
        system: Reading<[ProcessSystemCounter]>, network: Reading<[ProcessNetworkCounter]>, at timestamp: Date
    ) -> ProcessRankings {
        // 系统计数负责计算进程 CPU 差值和当前常驻内存排名。
        let (cpu, memory) = systemRankings(system, at: timestamp)
        // 网络累计计数必须与上一轮比较，才能得到每秒上传和下载速率。
        let (upload, download) = networkRankings(network, at: timestamp)
        return .init(cpu: cpu, memory: memory, upload: upload, download: download)
    }

    /// 计算 CPU 与内存进程排名；进程聚合更新时调用，采集失败会清除旧基线以避免错误差值。
    /// 以 PID+启动时间作为字典键防止 PID 复用；多核进程 CPU 可超过 100%，异常回拨计数仅丢弃对应进程。
    private mutating func systemRankings(
        _ reading: Reading<[ProcessSystemCounter]>, at timestamp: Date
    ) -> (Reading<[ProcessRankingEntry]>, Reading<[ProcessRankingEntry]>) {
        let counters: [ProcessSystemCounter]
        switch reading {
        case let .value(value):
            counters = value
        case let .unavailable(reason):
            previousSystem = nil
            return (.unavailable(reason), .unavailable(reason))
        }
        let memory = Self.topFive(counters.map {
            .init(identity: $0.identity, name: $0.name, value: Double($0.residentBytes))
        })
        let previous = previousSystem
        previousSystem = (Dictionary(counters.map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest }), timestamp)
        guard let previous, timestamp.timeIntervalSince(previous.timestamp) > 0 else {
            return (.unavailable("等待进程采样基线"), .value(memory))
        }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        let cpu = counters.compactMap { counter -> ProcessRankingEntry? in
            guard let old = previous.counters[counter.identity], counter.cpuNanoseconds >= old.cpuNanoseconds else {
                return nil
            }
            return .init(identity: counter.identity, name: counter.name,
                         value: Double(counter.cpuNanoseconds - old.cpuNanoseconds) / elapsed / 10_000_000)
        }
        return (.value(Self.topFive(cpu)), .value(memory))
    }

    /// 计算上传与下载进程排名；进程聚合更新时调用，使用相邻两次累计字节差得到速率。
    /// 上传和下载独立过滤零差值与计数回拨，单位统一为 B/s，避免一侧异常影响另一侧榜单。
    private mutating func networkRankings(
        _ reading: Reading<[ProcessNetworkCounter]>, at timestamp: Date
    ) -> (Reading<[ProcessRankingEntry]>, Reading<[ProcessRankingEntry]>) {
        let counters: [ProcessNetworkCounter]
        switch reading {
        case let .value(value):
            counters = value
        case let .unavailable(reason):
            previousNetwork = nil
            return (.unavailable(reason), .unavailable(reason))
        }
        let previous = previousNetwork
        previousNetwork = (Dictionary(counters.map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest }), timestamp)
        guard let previous, timestamp.timeIntervalSince(previous.timestamp) > 0 else {
            return (.unavailable("等待进程采样基线"), .unavailable("等待进程采样基线"))
        }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        var upload: [ProcessRankingEntry] = []
        var download: [ProcessRankingEntry] = []
        for counter in counters {
            guard let old = previous.counters[counter.identity],
                  counter.receivedBytes >= old.receivedBytes, counter.sentBytes >= old.sentBytes else { continue }
            if counter.sentBytes > old.sentBytes {
                upload.append(.init(identity: counter.identity, name: counter.name,
                                    value: Double(counter.sentBytes - old.sentBytes) / elapsed))
            }
            if counter.receivedBytes > old.receivedBytes {
                download.append(.init(identity: counter.identity, name: counter.name,
                                      value: Double(counter.receivedBytes - old.receivedBytes) / elapsed))
            }
        }
        return (.value(Self.topFive(upload)), .value(Self.topFive(download)))
    }

    /// 按数值、名称和 PID 稳定排序并截取五项；生成任一进程榜单时调用。
    /// 全量排序复杂度 O(n log n)，名称与 PID 作为次级键保证相同数据下界面顺序稳定。
    private static func topFive(_ entries: [ProcessRankingEntry]) -> [ProcessRankingEntry] {
        Array(entries.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.identity.pid < $1.identity.pid
        }.prefix(5))
    }
}

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

    mutating func resetRates() {
        resetSystemRates()
        resetNetworkRates()
    }

    mutating func resetSystemRates() { previousSystem = nil }
    mutating func resetNetworkRates() { previousNetwork = nil }

    mutating func update(
        system: Reading<[ProcessSystemCounter]>, network: Reading<[ProcessNetworkCounter]>, at timestamp: Date
    ) -> ProcessRankings {
        let (cpu, memory) = systemRankings(system, at: timestamp)
        let (upload, download) = networkRankings(network, at: timestamp)
        return .init(cpu: cpu, memory: memory, upload: upload, download: download)
    }

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

    private static func topFive(_ entries: [ProcessRankingEntry]) -> [ProcessRankingEntry] {
        Array(entries.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.identity.pid < $1.identity.pid
        }.prefix(5))
    }
}

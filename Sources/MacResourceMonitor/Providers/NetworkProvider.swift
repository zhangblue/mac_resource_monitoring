import Darwin
import Foundation

struct NetworkCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
    let interfaces: Set<String>
}

struct NetworkRateCalculator {
    private var previous: (counters: NetworkCounters, date: Date)?

    /// 用相邻两次接口累计计数计算速率；监控引擎提交网络读数时调用，异常间隔会重建基线。
    /// 要求接口集合不变、计数单调且间隔在 0.25...10 秒；超过 100 GB/s 的异常差值会被拒绝。
    mutating func update(_ counters: NetworkCounters, at date: Date) -> NetworkMetric? {
        defer { previous = (counters, date) }
        guard let previous,
              previous.counters.interfaces == counters.interfaces,
              counters.received >= previous.counters.received,
              counters.sent >= previous.counters.sent else { return nil }

        let seconds = date.timeIntervalSince(previous.date)
        guard (0.25...10).contains(seconds) else { return nil }
        let download = Double(counters.received - previous.counters.received) / seconds
        let upload = Double(counters.sent - previous.counters.sent) / seconds
        guard download < 100_000_000_000, upload < 100_000_000_000 else { return nil }
        return NetworkMetric(downloadBytesPerSecond: download, uploadBytesPerSecond: upload)
    }
}

struct NetworkProvider: Sendable {
    /// 汇总所有可用 en 网络接口的累计收发字节；上传或下载板块启用时调用。
    /// getifaddrs 返回链表，仅读取 AF_LINK 的 if_data 累计计数，并使用 addingReportingOverflow 防止 UInt64 汇总溢出。
    func sample() throws -> NetworkCounters {
        var first: UnsafeMutablePointer<ifaddrs>?
        // 获取系统接口链表；函数结束时必须通过 freeifaddrs 成对释放。
        guard getifaddrs(&first) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { freeifaddrs(first) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces = Set<String>()
        var current = first
        while let address = current {
            let item = address.pointee
            defer { current = item.ifa_next }
            guard let socketAddress = item.ifa_addr,
                  Int32(socketAddress.pointee.sa_family) == AF_LINK else { continue }
            let name = String(cString: item.ifa_name)
            guard Self.isEligible(name: name, family: AF_LINK, flags: item.ifa_flags) else { continue }
            guard let data = item.ifa_data else { throw NetworkProviderError.missingInterfaceData(name) }

            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let (newReceived, receivedOverflow) = received.addingReportingOverflow(UInt64(counters.ifi_ibytes))
            let (newSent, sentOverflow) = sent.addingReportingOverflow(UInt64(counters.ifi_obytes))
            guard !receivedOverflow, !sentOverflow else { throw NetworkProviderError.counterOverflow }
            received = newReceived
            sent = newSent
            interfaces.insert(name)
        }
        return NetworkCounters(received: received, sent: sent, interfaces: interfaces)
    }

    /// 判断接口是否属于正在工作的物理/主网络接口；遍历系统接口时调用以排除回环等接口。
    static func isEligible(name: String, family: Int32, flags: UInt32) -> Bool {
        family == AF_LINK
            && flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            && name.hasPrefix("en")
    }
}

enum NetworkProviderError: Error {
    case counterOverflow
    case missingInterfaceData(String)
}

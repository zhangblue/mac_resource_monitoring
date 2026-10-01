import Darwin
import Foundation

struct NetworkCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
    let interfaces: Set<String>
}

struct NetworkRateCalculator {
    private var previous: (counters: NetworkCounters, date: Date)?

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
    func sample() throws -> NetworkCounters {
        var first: UnsafeMutablePointer<ifaddrs>?
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

    static func isEligible(name: String, family: Int32, flags: UInt32) -> Bool {
        family == AF_LINK
            && flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            && !excludedPrefixes.contains(where: name.hasPrefix)
    }

    private static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "vmenet"]
}

enum NetworkProviderError: Error {
    case counterOverflow
    case missingInterfaceData(String)
}

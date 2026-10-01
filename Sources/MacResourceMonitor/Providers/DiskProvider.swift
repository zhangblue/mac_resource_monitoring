import Darwin
import Foundation
import IOKit

struct DiskCounters: Equatable, Sendable {
    let read: UInt64
    let written: UInt64
    let usedBytes: UInt64
    let totalBytes: UInt64
    let bsdName: String
}

struct DiskRates: Equatable, Sendable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

struct DiskCapacity: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    static func from(_ attributes: [FileAttributeKey: Any]) throws -> DiskCapacity {
        guard let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber,
              total.int64Value >= 0, free.int64Value >= 0,
              free.uint64Value <= total.uint64Value else {
            throw DiskProviderError.capacityUnavailable
        }
        return DiskCapacity(
            usedBytes: total.uint64Value - free.uint64Value,
            totalBytes: total.uint64Value
        )
    }
}

struct DiskRateCalculator {
    private var previous: (read: UInt64, written: UInt64, date: Date)?

    mutating func update(read: UInt64, written: UInt64, at date: Date) -> DiskRates? {
        defer { previous = (read, written, date) }
        guard let previous, read >= previous.read, written >= previous.written else { return nil }
        let seconds = date.timeIntervalSince(previous.date)
        guard (0.25...10).contains(seconds) else { return nil }
        let readRate = Double(read - previous.read) / seconds
        let writeRate = Double(written - previous.written) / seconds
        guard readRate < 100_000_000_000, writeRate < 100_000_000_000 else { return nil }
        return DiskRates(readBytesPerSecond: readRate, writeBytesPerSecond: writeRate)
    }
}

struct DiskProvider: Sendable {
    func sample() throws -> DiskCounters {
        var filesystem = statfs()
        guard statfs("/", &filesystem) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let device = withUnsafePointer(to: filesystem.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { throw DiskProviderError.invalidBootDevice(device) }
        let bsdName = String(device.dropFirst(5))

        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw DiskProviderError.deviceNotFound(bsdName)
        }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else { throw DiskProviderError.deviceNotFound(bsdName) }
        defer { IOObjectRelease(current) }

        while IOObjectConformsTo(current, "IOBlockStorageDriver") == 0 {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard result == KERN_SUCCESS, parent != 0 else {
                throw DiskProviderError.storageDriverNotFound(bsdName)
            }
            IOObjectRelease(current)
            current = parent
        }

        guard let property = IORegistryEntryCreateCFProperty(
            current, "Statistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(),
              let statistics = property as? [String: NSNumber],
              let read = statistics["Bytes (Read)"],
              let written = statistics["Bytes (Write)"] else {
            throw DiskProviderError.statisticsUnavailable(bsdName)
        }

        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let capacity = try DiskCapacity.from(attributes)
        return DiskCounters(
            read: read.uint64Value, written: written.uint64Value,
            usedBytes: capacity.usedBytes,
            totalBytes: capacity.totalBytes, bsdName: bsdName
        )
    }
}

enum DiskProviderError: Error {
    case invalidBootDevice(String)
    case deviceNotFound(String)
    case storageDriverNotFound(String)
    case statisticsUnavailable(String)
    case capacityUnavailable
}

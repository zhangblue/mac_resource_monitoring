import Darwin
import Foundation
import IOKit

struct DiskCounters: Equatable, Sendable {
    let read: UInt64
    let written: UInt64
    let usedBytes: UInt64
    let totalBytes: UInt64
    let bsdName: String
    let driverID: UInt64
}

enum DiskDriverSelection {
    static func uniqueID(from identifiers: [UInt64], bsdName: String) throws -> UInt64 {
        let unique = Array(Set(identifiers)).sorted()
        guard let identifier = unique.first else {
            throw DiskProviderError.storageDriverNotFound(bsdName)
        }
        guard unique.count == 1 else {
            throw DiskProviderError.ambiguousStorageDrivers(bsdName, unique)
        }
        return identifier
    }
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
        let bootService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard bootService != 0 else { throw DiskProviderError.deviceNotFound(bsdName) }
        defer { IOObjectRelease(bootService) }

        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        let iteratorResult = IORegistryEntryCreateIterator(bootService, kIOServicePlane, options, &iterator)
        guard iteratorResult == KERN_SUCCESS else {
            if iterator != 0 { IOObjectRelease(iterator) }
            throw SystemProviderError.machCallFailed("IORegistryEntryCreateIterator", iteratorResult)
        }
        guard iterator != 0 else { throw DiskProviderError.registryChanged(bsdName) }
        defer { IOObjectRelease(iterator) }

        var drivers: [UInt64: io_registry_entry_t] = [:]
        defer { drivers.values.forEach { IOObjectRelease($0) } }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            guard IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 else {
                IOObjectRelease(entry)
                continue
            }
            var identifier: UInt64 = 0
            let idResult = IORegistryEntryGetRegistryEntryID(entry, &identifier)
            guard idResult == KERN_SUCCESS else {
                IOObjectRelease(entry)
                throw SystemProviderError.machCallFailed("IORegistryEntryGetRegistryEntryID", idResult)
            }
            if drivers[identifier] == nil {
                drivers[identifier] = entry
            } else {
                IOObjectRelease(entry)
            }
        }
        guard IOIteratorIsValid(iterator) != 0 else {
            throw DiskProviderError.registryChanged(bsdName)
        }
        let driverID = try DiskDriverSelection.uniqueID(from: Array(drivers.keys), bsdName: bsdName)
        guard let driver = drivers[driverID] else {
            throw DiskProviderError.storageDriverNotFound(bsdName)
        }

        guard let property = IORegistryEntryCreateCFProperty(
            driver, "Statistics" as CFString, kCFAllocatorDefault, 0
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
            totalBytes: capacity.totalBytes, bsdName: bsdName, driverID: driverID
        )
    }
}

enum DiskProviderError: Error {
    case invalidBootDevice(String)
    case deviceNotFound(String)
    case storageDriverNotFound(String)
    case ambiguousStorageDrivers(String, [UInt64])
    case registryChanged(String)
    case statisticsUnavailable(String)
    case capacityUnavailable
}

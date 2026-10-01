import Foundation

enum DiskCapacity {
    static func exactUInt64(_ number: NSNumber) -> UInt64? {
        guard number.doubleValue.isFinite,
              let decimal = Decimal(string: number.stringValue,
                                    locale: Locale(identifier: "en_US_POSIX")),
              decimal >= 0 else { return nil }
        return UInt64(NSDecimalNumber(decimal: decimal).stringValue)
    }

    static func from(_ attributes: [FileAttributeKey: Any]) throws -> DiskMetric {
        guard let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber,
              let totalBytes = exactUInt64(total),
              let freeBytes = exactUInt64(free),
              freeBytes <= totalBytes else {
            throw DiskProviderError.capacityUnavailable
        }
        return DiskMetric(usedBytes: totalBytes - freeBytes,
                          totalBytes: totalBytes)
    }
}

struct DiskProvider: Sendable {
    func sample() throws -> DiskMetric {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        return try DiskCapacity.from(attributes)
    }
}

enum DiskProviderError: Error {
    case capacityUnavailable
}

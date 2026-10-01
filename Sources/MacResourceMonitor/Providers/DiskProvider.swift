import Foundation
import CoreFoundation

enum DiskCapacity {
    static func exactUInt64(_ number: NSNumber) -> UInt64? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

        if number is NSDecimalNumber {
            guard number.doubleValue.isFinite,
                  let decimal = Decimal(string: number.stringValue,
                                        locale: Locale(identifier: "en_US_POSIX")),
                  decimal >= 0 else { return nil }
            return UInt64(NSDecimalNumber(decimal: decimal).stringValue)
        }

        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let value = number.int64Value
            return value >= 0 ? UInt64(value) : nil
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        case "f", "d":
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value.rounded(.towardZero) == value,
                  value < 18_446_744_073_709_551_616.0 else { return nil }
            return UInt64(value)
        default:
            return nil
        }
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

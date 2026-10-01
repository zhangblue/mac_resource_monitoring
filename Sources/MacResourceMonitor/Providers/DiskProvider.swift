import Foundation

enum DiskCapacity {
    static func from(_ attributes: [FileAttributeKey: Any]) throws -> DiskMetric {
        guard let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber,
              total.int64Value >= 0, free.int64Value >= 0,
              free.uint64Value <= total.uint64Value else {
            throw DiskProviderError.capacityUnavailable
        }
        return DiskMetric(usedBytes: total.uint64Value - free.uint64Value,
                          totalBytes: total.uint64Value)
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

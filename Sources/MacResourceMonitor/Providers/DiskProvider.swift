import Foundation
import CoreFoundation

enum DiskCapacity {
    /// 将 NSNumber 无损转换为 UInt64；解析文件系统容量属性前调用，拒绝布尔值和非整数浮点数。
    /// 根据 Objective-C 数字类型分别处理有符号、无符号、十进制和浮点表示，避免 doubleValue 丢失 64 位整数精度。
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

    /// 从文件系统属性计算已用和总容量；磁盘提供器读取根卷属性后调用。
    /// 仅接受 free<=total 的精确无符号值，已用容量采用 total-free，数据模型不包含磁盘读写速率。
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
    /// 读取系统启动卷容量；磁盘容量板块启用的每轮采样中调用，不采集读写速率。
    func sample() throws -> DiskMetric {
        // 根路径对应系统启动卷，符合产品仅展示启动卷容量的约束。
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        return try DiskCapacity.from(attributes)
    }
}

enum DiskProviderError: Error {
    case capacityUnavailable
}

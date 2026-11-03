import Foundation

struct SMCValue: Sendable {
    let type: String
    let bytes: [UInt8]

    /// 按 SMC 类型解码原始字节；传感器提供器读取键值后调用。
    func decoded() throws -> Double {
        try SMCDecoder.decode(bytes: bytes, type: type)
    }
}

enum SMCError: Error {
    case unsupportedType(String)
    case insufficientBytes(type: String, expected: Int, actual: Int)
    case invalidKey(String)
    case invalidLayout
    case serviceUnavailable
    case ioFailure(operation: String, code: Int32)
    case deviceFailure(command: UInt8, result: UInt8, status: UInt8)
    case invalidResponseSize(Int)
    case invalidDataSize(UInt32)
    case invalidKeyCount
    case invalidFanCount
    case invalidFanSpeed(String)
}

enum SMCResponseValidation {
    /// 校验设备响应状态；每次底层 SMC 调用返回后调用。
    static func check(command: UInt8, result: UInt8, status: UInt8) throws {
        // AppleSMC 私有状态字段没有可靠公开定义，因此仅在两个字段均为零时接受响应。
        guard result == 0, status == 0 else {
            throw SMCError.deviceFailure(command: command, result: result, status: status)
        }
    }
}

enum SMCDecoder {
    /// 将支持的 SMC 数字类型解码为 Double；SMCValue 对外解码时调用。
    /// sp78/fpe2/ui16/ui32 使用大端拼接，flt 在 Apple Silicon 上按小端 IEEE 754 还原，短载荷明确抛错。
    static func decode(bytes: [UInt8], type: String) throws -> Double {
        let length: Int
        switch type {
        case "sp78", "fpe2", "ui16": length = 2
        case "flt ", "ui32": length = 4
        case "ui8 ": length = 1
        default: throw SMCError.unsupportedType(type)
        }
        guard bytes.count >= length else {
            throw SMCError.insufficientBytes(type: type, expected: length, actual: bytes.count)
        }
        // 整数和定点载荷使用网络字节序。
        let integer = bytes.prefix(length).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch type {
        case "sp78": return Double(Int16(bitPattern: UInt16(integer))) / 256
        case "fpe2": return Double(integer) / 4
        case "flt ":
            // Apple Silicon 上的 AppleSMC 浮点数使用原生小端 IEEE 754。
            let bits = bytes.prefix(4).enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << (8 * $1.offset))
            }
            return Double(Float(bitPattern: bits))
        default: return Double(integer)
        }
    }
}

enum SMCFourCC {
    /// 将四字符 SMC 键编码为 UInt32；发起键读取前调用。
    /// 仅接受四个可打印 ASCII 字节并按大端折叠，保证与 AppleSMC FourCC ABI 一致。
    static func encode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            throw SMCError.invalidKey(string)
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// 将 UInt32 SMC 键解码为四字符字符串；枚举键和解析类型时调用。
    static func decode(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? ""
    }
}

// AppleSMC 用户客户端 C ABI 已与 smcFanControl 的 smc.h 交叉验证；显式填充防止 Swift 复用嵌套结构尾部空间。
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var memory: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var versionPadding: UInt16 = 0
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var commandPadding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// 校验 Swift 结构布局是否符合 AppleSMC C ABI；打开 SMC 连接前调用。
    /// 同时检查 size、stride 和关键字段偏移，防止编译器布局变化造成越界或错误设备命令。
    static var hasValidLayout: Bool {
        MemoryLayout<Self>.size == 80 && MemoryLayout<Self>.stride == 80 &&
        MemoryLayout<Self>.offset(of: \.version) == 4 &&
        MemoryLayout<Self>.offset(of: \.powerLimit) == 12 &&
        MemoryLayout<Self>.offset(of: \.keyInfo) == 28 &&
        MemoryLayout<Self>.offset(of: \.result) == 40 &&
        MemoryLayout<Self>.offset(of: \.status) == 41 &&
        MemoryLayout<Self>.offset(of: \.data8) == 42 &&
        MemoryLayout<Self>.offset(of: \.data32) == 44 &&
        MemoryLayout<Self>.offset(of: \.bytes) == 48
    }
}

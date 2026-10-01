import Foundation

struct SMCValue: Sendable {
    let type: String
    let bytes: [UInt8]

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
    static func check(command: UInt8, result: UInt8, status: UInt8) throws {
        // AppleSMC's private status field has no reliable public definition.
        // Conservatively fail closed unless both fields are zero, retaining
        // both raw values for compatibility diagnostics.
        guard result == 0, status == 0 else {
            throw SMCError.deviceFailure(command: command, result: result, status: status)
        }
    }
}

enum SMCDecoder {
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
        // Integer and fixed-point payloads use network byte order.
        let integer = bytes.prefix(length).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch type {
        case "sp78": return Double(Int16(bitPattern: UInt16(integer))) / 256
        case "fpe2": return Double(integer) / 4
        case "flt ":
            // AppleSMC floats use native little-endian IEEE 754 on Apple Silicon.
            let bits = bytes.prefix(4).enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << (8 * $1.offset))
            }
            return Double(Float(bitPattern: bits))
        default: return Double(integer)
        }
    }
}

enum SMCFourCC {
    static func encode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            throw SMCError.invalidKey(string)
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func decode(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? ""
    }
}

// AppleSMC user-client C ABI, verified against smcFanControl's smc.h:
// https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.h
// Explicit padding is required: Swift can reuse a nested struct's tail padding.
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

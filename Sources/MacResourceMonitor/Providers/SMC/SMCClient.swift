import Foundation
import IOKit

protocol SMCTransport: Sendable {
    func allKeys() throws -> [String]
    func read(_ key: String) throws -> SMCValue
}

// The lock serializes the connection and caches. The connection is never exposed.
final class SMCClient: SMCTransport, @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()
    private var cachedKeys: [String]?
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    // Commands and selector are the AppleSMC read protocol, verified against:
    // https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.c
    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    init() throws {
        guard SMCKeyData.hasValidLayout else { throw SMCError.invalidLayout }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceUnavailable }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == KERN_SUCCESS else {
            if opened != IO_OBJECT_NULL { IOServiceClose(opened) }
            throw SMCError.ioFailure(operation: "IOServiceOpen", code: result)
        }
        guard opened != IO_OBJECT_NULL else { throw SMCError.serviceUnavailable }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    func allKeys() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKeys { return cachedKeys }

        let count = try readLocked("#KEY").decoded()
        guard count.isFinite, count >= 0, count <= 65_536, count.rounded(.towardZero) == count else {
            throw SMCError.invalidKeyCount
        }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var input = SMCKeyData()
            input.data32 = UInt32(index)
            let output = try call(.readIndex, input: input)
            let key = SMCFourCC.decode(output.key)
            _ = try SMCFourCC.encode(key)
            keys.append(key)
        }
        cachedKeys = keys
        return keys
    }

    func read(_ key: String) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        return try readLocked(key)
    }

    private func readLocked(_ key: String) throws -> SMCValue {
        var input = SMCKeyData()
        input.key = try SMCFourCC.encode(key)
        let info: SMCKeyInfo
        if let cached = keyInfoCache[input.key] {
            info = cached
        } else {
            info = try call(.readKeyInfo, input: input).keyInfo
            guard (1...32).contains(info.dataSize) else { throw SMCError.invalidDataSize(info.dataSize) }
            keyInfoCache[input.key] = info
        }
        input.keyInfo.dataSize = info.dataSize
        var output = try call(.readBytes, input: input)
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValue(type: SMCFourCC.decode(info.dataType), bytes: bytes)
    }

    // Only read commands are expressible; no fan-control or write API is present.
    private func call(_ command: Command, input: SMCKeyData) throws -> SMCKeyData {
        var request = input
        request.data8 = command.rawValue
        var response = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, &request, MemoryLayout<SMCKeyData>.stride, &response, &outputSize
        )
        guard result == KERN_SUCCESS else {
            throw SMCError.ioFailure(operation: "AppleSMC command \(command.rawValue)", code: result)
        }
        guard outputSize == MemoryLayout<SMCKeyData>.stride else {
            throw SMCError.invalidResponseSize(outputSize)
        }
        guard response.result == 0 else {
            throw SMCError.deviceFailure(command: command.rawValue, result: response.result)
        }
        return response
    }
}

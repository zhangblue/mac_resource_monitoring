import Foundation
import IOKit

protocol SMCTransport: Sendable {
    /// 枚举 SMC 键；温度提供器首次查找处理器温度键时调用。
    func allKeys() throws -> [String]
    /// 读取指定 SMC 键；温度和风扇采样时调用。
    func read(_ key: String) throws -> SMCValue
}

// 锁串行保护连接及缓存，底层连接不会暴露给调用方。
final class SMCClient: SMCTransport, @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()
    private var cachedKeys: [String]?
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    // 命令值及 selector 来自 AppleSMC 只读协议，并与 smcFanControl 的 smc.c 交叉验证。
    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    /// 校验 ABI 并打开 AppleSMC 用户客户端；真实传感器提供器首次创建时调用。
    /// 先验证 SMCKeyData 的 80 字节内存布局，再用 IOServiceOpen 建立 io_connect_t；deinit 中始终关闭连接。
    init() throws {
        guard SMCKeyData.hasValidLayout else { throw SMCError.invalidLayout }
        // 通过 IOKit 查找 AppleSMC 服务并打开只读用户客户端连接。
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

    /// 枚举并缓存全部 SMC 键；温度采集首次扫描处理器键时调用。
    /// 在 NSLock 内先读 #KEY 数量，再按索引调用 readIndex；结果缓存在进程生命周期内以降低后续温度采样开销。
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

    /// 在线程锁内读取单个 SMC 键；传感器提供器请求温度或风扇值时调用。
    func read(_ key: String) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        return try readLocked(key)
    }

    /// 在已持锁前提下读取键元数据和字节；公开读取及键枚举内部调用。
    /// 键信息按 FourCC 缓存，dataSize 限制在 1...32，最终只复制响应缓冲区中声明长度的字节。
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

    // 此接口仅能表达读取命令，不提供风扇控制或写入能力。
    /// 执行一次 AppleSMC 结构体调用并校验响应；枚举键、读取元数据和读取字节时调用。
    /// IOConnectCallStructMethod 固定 selector 2，输入输出都必须匹配 SMCKeyData ABI；内核码、尺寸和设备状态逐层校验。
    private func call(_ command: Command, input: SMCKeyData) throws -> SMCKeyData {
        var request = input
        request.data8 = command.rawValue
        var response = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        // IOKit 结构体调用是所有 SMC 读取的关键边界，响应尺寸和设备状态必须同时校验。
        let result = IOConnectCallStructMethod(
            connection, 2, &request, MemoryLayout<SMCKeyData>.stride, &response, &outputSize
        )
        guard result == KERN_SUCCESS else {
            throw SMCError.ioFailure(operation: "AppleSMC command \(command.rawValue)", code: result)
        }
        guard outputSize == MemoryLayout<SMCKeyData>.stride else {
            throw SMCError.invalidResponseSize(outputSize)
        }
        try SMCResponseValidation.check(command: command.rawValue, result: response.result, status: response.status)
        return response
    }
}

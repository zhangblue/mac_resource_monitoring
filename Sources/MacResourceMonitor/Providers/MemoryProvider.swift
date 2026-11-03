import Darwin
import Foundation

enum MemoryCalculator {
    /// 将虚拟内存页计数换算为用量；内存提供器采样完成后调用，也供计算测试直接验证。
    /// 使用 active+inactive+wired+compressed 页数乘页大小得到字节，并把比例钳制在 0...1。
    static func metric(
        pageSize: UInt64, active: UInt64, inactive: UInt64,
        wired: UInt64, compressed: UInt64, totalBytes: UInt64
    ) -> MemoryMetric {
        let pageCount = active + inactive + wired + compressed
        let usedBytes = pageCount * pageSize
        let usage = totalBytes == 0 ? 0 : min(Double(usedBytes) / Double(totalBytes), 1)
        return MemoryMetric(usage: usage, usedBytes: usedBytes, totalBytes: totalBytes)
    }
}

struct MemoryProvider: MemoryProviding {
    /// 读取 Mach 虚拟内存统计并计算总内存使用率；内存板块启用的每轮采样中调用。
    /// host_statistics64 要求以 integer_t 指针和元素计数传入 vm_statistics64，物理总量来自 ProcessInfo。
    func sample() throws -> MemoryMetric {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        // 页大小必须与本轮 vm_statistics64 的页计数配套，才能准确换算字节数。
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else {
            throw SystemProviderError.machCallFailed("host_page_size", pageResult)
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.stride
        )
        // 将 Swift 结构体按 Mach 所需的 integer_t 缓冲区传入系统调用。
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemProviderError.machCallFailed("host_statistics64", result)
        }

        return MemoryCalculator.metric(
            pageSize: UInt64(pageSize),
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            wired: UInt64(statistics.wire_count),
            compressed: UInt64(statistics.compressor_page_count),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}

import Darwin
import Foundation

enum MemoryCalculator {
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
    func sample() throws -> MemoryMetric {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else {
            throw SystemProviderError.machCallFailed("host_page_size", pageResult)
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.stride
        )
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

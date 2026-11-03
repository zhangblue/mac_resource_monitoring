import Darwin

struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64
}

enum CPUUsageCalculator {
    /// 根据相邻两次累计时钟计算 0...1 的 CPU 使用率；监控引擎提交 CPU 读数时调用。
    /// 先验证四类 UInt64 计数单调，再用 busy/(busy+idle) 求比例；无增量或计数重置返回 nil 以重建基线。
    static func usage(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.nice >= previous.nice,
              current.idle >= previous.idle else { return nil }

        let busy = Double(current.user - previous.user)
            + Double(current.system - previous.system)
            + Double(current.nice - previous.nice)
        let total = busy + Double(current.idle - previous.idle)
        guard total > 0 else { return nil }
        return min(max(busy / total, 0), 1)
    }
}

struct CPUProvider: CPUProviding {
    /// 汇总所有核心的 Mach CPU 累计时钟；CPU 板块启用的每轮采样中调用。
    /// host_processor_info 返回内核分配的连续 integer_t 数组，按 CPU_STATE_MAX 步长解析后必须调用 vm_deallocate。
    func sample() throws -> CPUTicks {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        // 调用 Mach 接口取得每个逻辑核心的四类累计时钟，随后统一汇总。
        let result = host_processor_info(
            host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else {
            throw SystemProviderError.machCallFailed("host_processor_info", result)
        }
        let stateCount = Int(CPU_STATE_MAX)
        var ticks: CPUTicks?
        if Int(infoCount) >= Int(cpuCount) * stateCount {
            var user: UInt64 = 0
            var system: UInt64 = 0
            var nice: UInt64 = 0
            var idle: UInt64 = 0
            for cpu in 0..<Int(cpuCount) {
                let offset = cpu * stateCount
                user += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]))
                system += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]))
                nice += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
                idle += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
            }
            ticks = CPUTicks(user: user, system: system, nice: nice, idle: idle)
        }

        // host_processor_info 返回由内核分配的缓冲区，解析后必须显式释放。
        let deallocationResult = vm_deallocate(
            mach_task_self_, vm_address_t(UInt(bitPattern: info)),
            vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
        )
        try SystemProviderError.check("vm_deallocate", result: deallocationResult)
        guard let ticks else {
            throw SystemProviderError.machCallFailed("host_processor_info count", KERN_FAILURE)
        }
        return ticks
    }
}

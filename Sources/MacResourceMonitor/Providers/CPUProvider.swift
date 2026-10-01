import Darwin

struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64
}

enum CPUUsageCalculator {
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
    func sample() throws -> CPUTicks {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else {
            throw SystemProviderError.machCallFailed("host_processor_info", result)
        }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var nice: UInt64 = 0
        var idle: UInt64 = 0
        let stateCount = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * stateCount else {
            throw SystemProviderError.machCallFailed("host_processor_info count", KERN_FAILURE)
        }
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * stateCount
            user += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]))
            nice += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
            idle += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
        }
        return CPUTicks(user: user, system: system, nice: nice, idle: idle)
    }
}

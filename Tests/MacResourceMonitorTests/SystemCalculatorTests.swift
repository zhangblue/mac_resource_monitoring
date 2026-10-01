import Darwin
import XCTest
@testable import MacResourceMonitor

final class SystemCalculatorTests: XCTestCase {
    func testFailedDeallocationMapsToMachError() {
        XCTAssertThrowsError(try SystemProviderError.check("vm_deallocate", result: KERN_FAILURE)) { error in
            guard case let SystemProviderError.machCallFailed(operation, code) = error else {
                return XCTFail("Expected a Mach call error")
            }
            XCTAssertEqual(operation, "vm_deallocate")
            XCTAssertEqual(code, KERN_FAILURE)
        }
    }

    func testSuccessfulDeallocationResultDoesNotThrow() {
        XCTAssertNoThrow(try SystemProviderError.check("vm_deallocate", result: KERN_SUCCESS))
    }

    func testCPUUsageUsesDeltaAndExcludesIdle() {
        let old = CPUTicks(user: 100, system: 50, nice: 0, idle: 850)
        let new = CPUTicks(user: 160, system: 70, nice: 0, idle: 870)
        XCTAssertEqual(CPUUsageCalculator.usage(previous: old, current: new) ?? -1, 0.8, accuracy: 0.0001)
    }

    func testCPUUsageReturnsNilWhenNoTicksAdvance() {
        let ticks = CPUTicks(user: 100, system: 50, nice: 0, idle: 850)
        XCTAssertNil(CPUUsageCalculator.usage(previous: ticks, current: ticks))
    }

    func testCPUUsageStaysWithinZeroToOne() {
        let old = CPUTicks(user: 10, system: 10, nice: 10, idle: 10)
        XCTAssertEqual(
            CPUUsageCalculator.usage(
                previous: old, current: CPUTicks(user: 20, system: 10, nice: 10, idle: 10)
            ), 1
        )
        XCTAssertEqual(
            CPUUsageCalculator.usage(
                previous: old, current: CPUTicks(user: 10, system: 10, nice: 10, idle: 20)
            ), 0
        )
    }

    func testCPUUsageReturnsNilWhenCounterResets() {
        let old = CPUTicks(user: 100, system: 50, nice: 0, idle: 850)
        let reset = CPUTicks(user: 1, system: 1, nice: 0, idle: 1)
        XCTAssertNil(CPUUsageCalculator.usage(previous: old, current: reset))
    }

    func testMemoryMetricUsesPageCounts() {
        let metric = MemoryCalculator.metric(
            pageSize: 4096, active: 10, inactive: 5, wired: 3, compressed: 2, totalBytes: 100 * 4096
        )
        XCTAssertEqual(metric.usedBytes, 20 * 4096)
        XCTAssertEqual(metric.usage, 0.20, accuracy: 0.0001)
    }
}

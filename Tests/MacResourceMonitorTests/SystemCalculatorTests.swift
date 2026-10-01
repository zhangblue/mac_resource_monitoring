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

    func testNetworkRateNeedsStableInterfaceSet() {
        var calculator = NetworkRateCalculator()
        XCTAssertNil(calculator.update(.init(received: 100, sent: 50, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 0)))
        XCTAssertEqual(
            calculator.update(.init(received: 1_100, sent: 550, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 1)),
            NetworkMetric(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)
        )
        XCTAssertNil(calculator.update(.init(received: 100, sent: 20, interfaces: ["en1"]), at: .init(timeIntervalSince1970: 2)))
    }

    func testNetworkRateUsesElapsedSecondsAndRebuildsAfterCounterReset() {
        var calculator = NetworkRateCalculator()
        XCTAssertNil(calculator.update(.init(received: 100, sent: 100, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 0)))
        XCTAssertEqual(
            calculator.update(.init(received: 300, sent: 500, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 2)),
            NetworkMetric(downloadBytesPerSecond: 100, uploadBytesPerSecond: 200)
        )
        XCTAssertNil(calculator.update(.init(received: 10, sent: 10, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 3)))
        XCTAssertEqual(
            calculator.update(.init(received: 30, sent: 50, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 4)),
            NetworkMetric(downloadBytesPerSecond: 20, uploadBytesPerSecond: 40)
        )
    }

    func testNetworkRateRejectsInvalidIntervalAndExcessiveRate() {
        var calculator = NetworkRateCalculator()
        XCTAssertNil(calculator.update(.init(received: 0, sent: 0, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 0)))
        XCTAssertNil(calculator.update(.init(received: 100, sent: 100, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 0.1)))
        XCTAssertNil(calculator.update(.init(received: 200, sent: 200, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 11)))
        XCTAssertNil(calculator.update(.init(received: 100_000_000_201, sent: 201, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 12)))
        XCTAssertEqual(
            calculator.update(.init(received: 100_000_000_211, sent: 211, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 13)),
            NetworkMetric(downloadBytesPerSecond: 10, uploadBytesPerSecond: 10)
        )
    }

    func testNetworkOnlyIncludesRunningPhysicalInterfaces() {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        XCTAssertTrue(NetworkProvider.isEligible(name: "en0", family: AF_LINK, flags: active))
        XCTAssertTrue(NetworkProvider.isEligible(name: "en1", family: AF_LINK, flags: active))
        XCTAssertFalse(NetworkProvider.isEligible(name: "en0", family: AF_INET, flags: active))
        XCTAssertFalse(NetworkProvider.isEligible(name: "en0", family: AF_LINK, flags: UInt32(IFF_UP)))
        for prefix in ["lo", "utun", "awdl", "llw", "bridge", "vmenet", "tap", "feth"] {
            XCTAssertFalse(NetworkProvider.isEligible(name: "\(prefix)0", family: AF_LINK, flags: active))
        }
    }

    func testDiskRateDropsCounterReset() {
        var calculator = DiskRateCalculator()
        _ = calculator.update(read: 1_000, written: 2_000, at: .init(timeIntervalSince1970: 0))
        XCTAssertNil(calculator.update(read: 100, written: 200, at: .init(timeIntervalSince1970: 1)))
    }

    func testDiskRateUsesElapsedSecondsAndRebuildsAfterInvalidSample() {
        var calculator = DiskRateCalculator()
        XCTAssertNil(calculator.update(read: 100, written: 100, at: .init(timeIntervalSince1970: 0)))
        XCTAssertEqual(
            calculator.update(read: 300, written: 500, at: .init(timeIntervalSince1970: 2)),
            DiskRates(readBytesPerSecond: 100, writeBytesPerSecond: 200)
        )
        XCTAssertNil(calculator.update(read: 400, written: 600, at: .init(timeIntervalSince1970: 13)))
        XCTAssertNil(calculator.update(read: 100_000_000_401, written: 601, at: .init(timeIntervalSince1970: 14)))
        XCTAssertEqual(
            calculator.update(read: 100_000_000_411, written: 611, at: .init(timeIntervalSince1970: 15)),
            DiskRates(readBytesPerSecond: 10, writeBytesPerSecond: 10)
        )
    }

    func testDiskCapacityRejectsMissingFreeSpace() {
        XCTAssertThrowsError(try DiskCapacity.from([.systemSize: NSNumber(value: 1_000)])) { error in
            guard case DiskProviderError.capacityUnavailable = error else {
                return XCTFail("Expected a capacity error")
            }
        }
    }

    func testDiskCapacityUsesFilesystemSizeAndFreeSpace() throws {
        let capacity = try DiskCapacity.from([
            .systemSize: NSNumber(value: 1_000),
            .systemFreeSize: NSNumber(value: 250)
        ])
        XCTAssertEqual(capacity.usedBytes, 750)
        XCTAssertEqual(capacity.totalBytes, 1_000)
    }

    func testDiskDriverSelectionRequiresOneUniqueIdentity() throws {
        XCTAssertEqual(try DiskDriverSelection.uniqueID(from: [17, 17], bsdName: "disk3s1"), 17)
        XCTAssertThrowsError(try DiskDriverSelection.uniqueID(from: [], bsdName: "disk3s1")) { error in
            guard case let DiskProviderError.storageDriverNotFound(name) = error else {
                return XCTFail("Expected no driver error")
            }
            XCTAssertEqual(name, "disk3s1")
        }
        XCTAssertThrowsError(try DiskDriverSelection.uniqueID(from: [17, 42], bsdName: "disk3s1")) { error in
            guard case let DiskProviderError.ambiguousStorageDrivers(name, identifiers) = error else {
                return XCTFail("Expected ambiguous driver error")
            }
            XCTAssertEqual(name, "disk3s1")
            XCTAssertEqual(identifiers, [17, 42])
        }
    }

    func testDiskCountersExposePhysicalDriverIdentity() {
        let first = DiskCounters(read: 100, written: 200, usedBytes: 10, totalBytes: 20,
                                 bsdName: "disk3s1", driverID: 17)
        let second = DiskCounters(read: 100, written: 200, usedBytes: 10, totalBytes: 20,
                                  bsdName: "disk3s1", driverID: 42)
        XCTAssertNotEqual(first, second)
    }

    func testRateRejectsOneHundredGigabytesPerSecondBoundary() {
        let start = Date(timeIntervalSince1970: 0)
        let next = Date(timeIntervalSince1970: 1)
        var network = NetworkRateCalculator()
        _ = network.update(.init(received: 0, sent: 0, interfaces: ["en0"]), at: start)
        XCTAssertNil(network.update(.init(received: 100_000_000_000, sent: 0, interfaces: ["en0"]), at: next))

        var disk = DiskRateCalculator()
        _ = disk.update(read: 0, written: 0, at: start)
        XCTAssertNil(disk.update(read: 0, written: 100_000_000_000, at: next))
    }
}

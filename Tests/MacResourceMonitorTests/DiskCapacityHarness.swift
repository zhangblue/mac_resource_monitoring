#if DISK_CAPACITY_HARNESS
import Foundation

@main
enum DiskCapacityHarness {
    static func main() throws {
        let metric = try DiskCapacity.from([
            .systemSize: NSNumber(value: 1_000),
            .systemFreeSize: NSNumber(value: 250)
        ])
        try check(metric == DiskMetric(usedBytes: 750, totalBytes: 1_000),
                  "Filesystem capacity uses size minus free space")
        try check(DiskPresentation(reading: .value(.init(usedBytes: 25, totalBytes: 100))).capacityText
                  == "已用 25 B / 100 B", "Capacity text shows used and total bytes")
        try check(DiskPresentation(reading: .value(.init(usedBytes: 25, totalBytes: 100))).usedFraction
                  == 0.25, "Capacity progress uses the used fraction")
        try check(DiskPresentation(reading: .value(.init(usedBytes: 10, totalBytes: 0))).usedFraction
                  == 0, "Zero total capacity has zero progress")
        try check(DiskPresentation(reading: .value(.init(usedBytes: 125, totalBytes: 100))).usedFraction
                  == 1, "Progress clamps capacity above total")
        try check(DiskPresentation(reading: nil).status == "等待下一次采样", "Pending capacity has a status")
        try check(DiskPresentation(reading: .unavailable("failed")).status == "暂不可用",
                  "Failed capacity has an unavailable status")
        do {
            _ = try DiskCapacity.from([.systemSize: NSNumber(value: 1_000)])
            throw HarnessError.failed("Missing free space must fail")
        } catch DiskProviderError.capacityUnavailable {}
        do {
            _ = try DiskCapacity.from([.systemSize: NSNumber(value: 1_000),
                                       .systemFreeSize: NSNumber(value: 1_001)])
            throw HarnessError.failed("Free space above total must fail")
        } catch DiskProviderError.capacityUnavailable {}
        let live = try DiskProvider().sample()
        try check(live.totalBytes >= live.usedBytes, "Root filesystem supplies valid live capacity")
        let menu = MenuBarPresentation(cpu: .value(0.24), memory: .value(0.61),
                                       upload: .value(1_200_000), download: .value(8_400_000))
        try check(menu.text == "C 24%   M 61%   ↑ 1.2M   ↓ 8.4M", "Menu bar retains four metrics")
        print("PASS: disk capacity conversion, live root volume, presentation, progress bounds and menu bar")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessError.failed(message) }
    }
}

private enum HarnessError: Error { case failed(String) }
#endif

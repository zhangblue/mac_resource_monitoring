import AppKit
import Darwin
import Foundation
#if !SAMPLING_BOUNDARY_HARNESS
import XCTest
@testable import MacResourceMonitor

final class SamplingBoundaryTests: XCTestCase {
    func testHostReferencesDoNotGrow() throws { try BoundaryChecks.hostReferences() }
    func testChartsSplitAtSamplingGaps() throws { try BoundaryChecks.chartGaps() }
    func testShortSleepResetsNetworkBaseline() async throws { try await BoundaryChecks.shortSleep() }
    func testSleepRejectsInFlightReadsAndObserverIsReleased() async throws {
        try await BoundaryChecks.inFlightSleepAndLifetime()
    }
}
#else
@main
enum SamplingBoundaryHarness {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "ports": try BoundaryChecks.hostReferences()
            case "charts": try BoundaryChecks.chartGaps()
            case "sleep": try await BoundaryChecks.shortSleep()
            case "inflight": try await BoundaryChecks.inFlightSleepAndLifetime()
            default:
                try BoundaryChecks.hostReferences()
                try BoundaryChecks.chartGaps()
                try await BoundaryChecks.shortSleep()
                try await BoundaryChecks.inFlightSleepAndLifetime()
            }
            print("PASS: sampling boundary checks")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
#endif

private actor BoundaryProcessMetricsProvider: ProcessMetricsProviding {
    private var step: UInt64 = 0
    func sample() async -> ProcessRawSnapshot {
        step += 1
        let identity = ProcessIdentity(pid: 7, startTimeMicroseconds: 100)
        return .init(system: .value([
            .init(identity: identity, name: "Browser", cpuNanoseconds: step * 500_000_000, residentBytes: 1_024)
        ]), network: .value([
            .init(identity: identity, name: "Browser", receivedBytes: step * 1_000, sentBytes: step * 2_000)
        ]))
    }
    func cancel() async {}
}

private enum BoundaryError: Error { case assertion(String) }
private func checkBoundary(_ condition: Bool, _ message: String) throws {
    if !condition { throw BoundaryError.assertion(message) }
}

private enum BoundaryChecks {
    // Removing either provider's deallocation must grow the real send-right count.
    static func hostReferences() throws {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func refs() throws -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            try SystemProviderError.check("mach_port_get_refs", result:
                mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &count))
            return count
        }
        let beforeCPU = try refs()
        for _ in 0..<100 { _ = try CPUProvider().sample() }
        let afterCPU = try refs()
        let beforeMemory = try refs()
        for _ in 0..<100 { _ = try MemoryProvider().sample() }
        let afterMemory = try refs()
        print("Host refs CPU: \(beforeCPU) -> \(afterCPU); memory: \(beforeMemory) -> \(afterMemory)")
        try checkBoundary(afterCPU == beforeCPU,
                          "CPU host references grew from \(beforeCPU) to \(afterCPU)")
        try checkBoundary(afterMemory == beforeMemory,
                          "Memory host references grew from \(beforeMemory) to \(afterMemory)")
    }

    // Bridging a short sleep or treating normal cadence jitter as a gap must fail.
    static func chartGaps() throws {
        func segments(_ seconds: [Double], refreshInterval: RefreshInterval = .oneSecond) -> [Int] {
            SparklinePresentation(points: seconds.map {
                HistoryPoint(timestamp: Date(timeIntervalSince1970: $0), value: 0.5)
            }, historyDuration: .fiveMinutes, refreshInterval: refreshInterval).segments.map(\.count)
        }
        try checkBoundary(segments([0, 1, 121, 122]) == [2, 2], "Chart bridges a 120-second sleep")
        try checkBoundary(segments([0, 1.8, 4.8]) == [3], "Chart must tolerate jitter and a 3-second boundary")
        try checkBoundary(segments([0, 3.001]) == [1, 1], "Chart must split above 3 seconds")
        try checkBoundary(segments([0, 3, 6], refreshInterval: .threeSeconds) == [3], "Normal 3-second sampling must connect")
        try checkBoundary(segments([0, 9], refreshInterval: .threeSeconds) == [2], "3-second sampling tolerates its 9-second threshold")
        try checkBoundary(segments([0, 9.001], refreshInterval: .threeSeconds) == [1, 1], "3-second sampling splits above 9 seconds")
        try checkBoundary(segments([0, 5, 10], refreshInterval: .fiveSeconds) == [3], "Normal 5-second sampling must connect")
        try checkBoundary(segments([0, 15], refreshInterval: .fiveSeconds) == [2], "5-second sampling tolerates its 15-second threshold")
        try checkBoundary(segments([0, 15.001], refreshInterval: .fiveSeconds) == [1, 1], "5-second sampling splits above 15 seconds")
        try checkBoundary(segments([0, 3, 123, 126], refreshInterval: .threeSeconds) == [2, 2], "3-second sampling must split a 120-second sleep")
        try checkBoundary(segments([0, 5, 125, 130], refreshInterval: .fiveSeconds) == [2, 2], "5-second sampling must split a 120-second sleep")
        try checkBoundary(segments([0, 0, 1]) == [1, 2], "Duplicate timestamps must not connect")
        try checkBoundary(segments([1, 0, 1]) == [1, 2], "Backward clock changes must not connect")
        let withMissing = [HistoryPoint(timestamp: Date(timeIntervalSince1970: 0), value: 1),
                           HistoryPoint(timestamp: Date(timeIntervalSince1970: 1), value: nil),
                           HistoryPoint(timestamp: Date(timeIntervalSince1970: 2), value: 1)]
        try checkBoundary(SparklinePresentation(points: withMissing, historyDuration: .fiveMinutes, refreshInterval: .oneSecond).segments.map(\.count) == [1, 1],
                          "Unavailable samples still break the chart")
    }

    // Synthetic workspace notifications exercise the real observer wiring without sleeping this Mac.
    static func shortSleep() async throws {
        let engine = MonitoringEngine(providers: ProviderSet(cpu: BoundaryCPU(), memory: BoundaryMemory(),
            network: BoundaryNetwork(), disk: BoundaryDisk(), sensors: BoundarySensors(),
            processes: BoundaryProcessMetricsProvider()), logger: BoundaryLogger())
        let base = Date(timeIntervalSince1970: 1_000)
        _ = await engine.sample(at: base)
        let active = await engine.sample(at: base.addingTimeInterval(1))
        try checkBoundary(active.network.value?.downloadBytesPerSecond == 100, "Adjacent rate must be 100 B/s")
        try checkBoundary(active.processes.cpu.value?.first?.value == 50, "Adjacent process CPU must use 500 ms delta")
        try checkBoundary(active.processes.download.value?.first?.value == 1_000, "Adjacent process download is 1,000 B/s")
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let waking = await engine.sample(at: base.addingTimeInterval(3))
        try checkBoundary(waking.network.value?.downloadBytesPerSecond == nil,
                          "First sample after a 2-second sleep must rebuild the network baseline")
        try checkBoundary(waking.processes.cpu.isUnavailable && waking.processes.download.isUnavailable
                          && waking.processes.upload.isUnavailable,
                          "A sleep generation change must rebuild all process rate baselines")
        try checkBoundary(waking.processes.memory.value?.first?.value == 1_024,
                          "Process memory remains available immediately after wake")
        let resumed = await engine.sample(at: base.addingTimeInterval(4))
        try checkBoundary(resumed.network.value?.downloadBytesPerSecond == 100,
                          "Second wake sample must restore adjacent network rate")
        try checkBoundary(resumed.network.value?.uploadBytesPerSecond == 20, "Upload baseline also resets")
        try checkBoundary(resumed.processes.cpu.value?.first?.value == 50
                          && resumed.processes.download.value?.first?.value == 1_000
                          && resumed.processes.upload.value?.first?.value == 2_000,
                          "Process rates resume from adjacent post-wake counters")
        await engine.stop()
    }

    static func inFlightSleepAndLifetime() async throws {
        let center = NotificationCenter()
        var monitor: SystemSleepMonitor? = SystemSleepMonitor(center: center)
        weak var weakMonitor = monitor
        let network = BoundaryGatedNetwork()
        var engine: MonitoringEngine? = MonitoringEngine(providers: ProviderSet(cpu: BoundaryCPU(),
            memory: BoundaryMemory(), network: network, disk: BoundaryDisk(), sensors: BoundarySensors(),
            processes: BoundaryProcessMetricsProvider()),
            logger: BoundaryLogger(), sleepMonitor: monitor!)
        monitor = nil
        let base = Date(timeIntervalSince1970: 2_000)
        _ = await engine!.sample(at: base)
        let pending = Task { [engine] in await engine!.sample(at: base.addingTimeInterval(1)) }
        for _ in 0..<2_000 {
            if await network.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try checkBoundary(await network.isWaiting, "In-flight collection reached its gate")
        await Task.detached { center.post(name: NSWorkspace.willSleepNotification, object: nil) }.value
        await network.release()
        let discarded = await pending.value
        try checkBoundary(discarded.network.isUnavailable, "An in-flight pre-sleep read must be discarded")
        try checkBoundary(discarded.processes.memory.isUnavailable, "Discarded process reads cannot publish memory")
        let sleeping = await engine!.sample(at: base.addingTimeInterval(2))
        try checkBoundary(sleeping.network.isUnavailable, "No delta collection while sleeping")
        let historyCount = await engine!.history.download.count
        try checkBoundary(historyCount == 1, "Discarded and sleeping samples must not enter history")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let baseline = await engine!.sample(at: base.addingTimeInterval(3))
        try checkBoundary(baseline.network.value?.downloadBytesPerSecond == nil, "Discarded read cannot seed wake baseline")
        try checkBoundary(baseline.processes.cpu.isUnavailable && baseline.processes.download.isUnavailable,
                          "Discarded process reads cannot seed post-wake baselines")
        let recovered = await engine!.sample(at: base.addingTimeInterval(4))
        try checkBoundary(recovered.network.value?.downloadBytesPerSecond == 100, "Adjacent sampling resumes after in-flight sleep")
        try checkBoundary(recovered.processes.cpu.value?.first?.value == 50
                          && recovered.processes.download.value?.first?.value == 1_000,
                          "Process rates resume after discarding the pre-sleep collection")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let wakeOnly = await engine!.sample(at: base.addingTimeInterval(5))
        try checkBoundary(wakeOnly.network.value?.downloadBytesPerSecond == nil, "Wake alone also invalidates baseline")
        try checkBoundary(wakeOnly.processes.cpu.isUnavailable && wakeOnly.processes.upload.isUnavailable,
                          "A wake-only generation change also resets process baselines")
        await engine!.stop()
        engine = nil
        try checkBoundary(weakMonitor == nil, "Engine and workspace callbacks must release the sleep monitor")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
    }
}

private struct BoundaryCPU: CPUProviding {
    func sample() -> CPUTicks { CPUTicks(user: 10, system: 0, nice: 0, idle: 90) }
}
private struct BoundaryMemory: MemoryProviding {
    func sample() -> MemoryMetric { MemoryMetric(usage: 0.5, usedBytes: 50, totalBytes: 100) }
}
private actor BoundaryNetwork: NetworkProviding {
    var count: UInt64 = 0
    func sample() -> NetworkCounters {
        count += 1
        return NetworkCounters(received: count * 100, sent: count * 20, interfaces: ["en0"])
    }
}
private actor BoundaryGatedNetwork: NetworkProviding {
    private var count: UInt64 = 0
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { gate != nil }
    func sample() async -> NetworkCounters {
        count += 1
        let value = count
        if value == 2 { await withCheckedContinuation { gate = $0 } }
        return NetworkCounters(received: value * 100, sent: value * 20, interfaces: ["en0"])
    }
    func release() { gate?.resume(); gate = nil }
}
private struct BoundaryDisk: DiskProviding {
    func sample() -> DiskMetric { DiskMetric(usedBytes: 50, totalBytes: 100) }
}
private struct BoundarySensors: SensorProviding {
    func sample() -> ThermalMetric { ThermalMetric(chipTemperatureCelsius: nil, fan: .fanless) }
}
private struct BoundaryLogger: DiagnosticLogging {
    func record(component: DiagnosticComponent, failure: String?, at date: Date) {}
}

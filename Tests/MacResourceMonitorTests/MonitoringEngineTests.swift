import Foundation
#if !MONITORING_ENGINE_HARNESS
import XCTest
@testable import MacResourceMonitor

final class MonitoringEngineTests: XCTestCase {
    func testFirstCPUIsUnavailableThenUsesRealDelta() async throws { try await MonitoringChecks.cpuBaseline() }
    func testPendingStopRestartRejectsOldResult() async throws { try await MonitoringChecks.pendingRestart() }
    func testConcurrentExplicitSamplesKeepOwnTimestamps() async throws { try await MonitoringChecks.concurrentSamples() }
    func testDeinitFinishesLiveStream() async throws { try await MonitoringChecks.streamLifetime() }
    func testOneProviderFailureDoesNotDropOtherMetrics() async throws {
        try await MonitoringChecks.failureIsolation()
    }

    func testHistoryKeepsNewest300PointsAndUnavailableGaps() async throws {
        try await MonitoringChecks.historyCapacity()
    }

    func testDiskDriverChangeRebuildsRateBaseline() async throws {
        try await MonitoringChecks.diskDriverChange()
    }

    func testStartIsIdempotentAndStopEndsPublication() async throws {
        try await MonitoringChecks.lifecycle()
    }

    func testStopSuppressesInFlightSample() async throws {
        try await MonitoringChecks.stopDuringSample()
    }

    func testStoreStopsConsumptionAndDeinitializes() async throws {
        try await MonitoringChecks.storeLifetime()
    }

    func testDiagnosticLogDeduplicatesAndRecovers() async throws {
        try await MonitoringChecks.diagnosticLog()
    }

    func testDiagnosticWriteFailureDoesNotLoseSample() async throws {
        try await MonitoringChecks.diagnosticWriteFailure()
    }

    func testSlowLoggerDoesNotDelaySamplesOrReorderEvents() async throws {
        try await MonitoringChecks.slowLoggerDoesNotDelaySamples()
    }

    func testSlowLoggerDoesNotDelayStreamPublication() async throws {
        try await MonitoringChecks.slowLoggerDoesNotDelayPublication()
    }

    func testStaleSampleNeverQueuesDiagnostics() async throws {
        try await MonitoringChecks.staleSampleDoesNotLog()
    }

    func testLoggerTailDoesNotRetainEngine() async throws {
        try await MonitoringChecks.loggerTailDoesNotRetainEngine()
    }
}
#else
@main
enum MonitoringHarness {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() async throws {
        if let check = CommandLine.arguments.dropFirst().first {
            switch check {
            case "cpu": try await MonitoringChecks.cpuBaseline()
            case "restart": try await MonitoringChecks.pendingRestart()
            case "concurrent": try await MonitoringChecks.concurrentSamples()
            case "deinit": try await MonitoringChecks.streamLifetime()
            default: throw MonitoringTestError.failed
            }
            print("PASS: \(check)")
            return
        }
        try await MonitoringChecks.cpuBaseline()
        try await MonitoringChecks.pendingRestart()
        try await MonitoringChecks.concurrentSamples()
        try await MonitoringChecks.streamLifetime()
        try await MonitoringChecks.failureIsolation()
        try await MonitoringChecks.historyCapacity()
        try await MonitoringChecks.diskDriverChange()
        try await MonitoringChecks.lifecycle()
        try await MonitoringChecks.stopDuringSample()
        try await MonitoringChecks.storeLifetime()
        try await MonitoringChecks.diagnosticLog()
        try await MonitoringChecks.diagnosticWriteFailure()
        try await MonitoringChecks.slowLoggerDoesNotDelaySamples()
        try await MonitoringChecks.slowLoggerDoesNotDelayPublication()
        try await MonitoringChecks.staleSampleDoesNotLog()
        try await MonitoringChecks.loggerTailDoesNotRetainEngine()
        print("PASS: monitoring lifecycle and diagnostic logging scenarios")
    }
}
#endif

private enum MonitoringTestError: Error { case failed, assertion(String) }

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw MonitoringTestError.assertion(message) }
}

private struct FakeCPUProvider: CPUProviding {
    var result: Result<CPUTicks, MonitoringTestError> = .success(.init(user: 10, system: 10, nice: 0, idle: 80))
    func sample() throws -> CPUTicks { try result.get() }
}

private actor AdvancingCPUProvider: CPUProviding {
    private var count: UInt64 = 0
    func sample() -> CPUTicks {
        count += 1
        return .init(user: 10 + count * 30, system: 10, nice: 0, idle: 80 + count * 70)
    }
}

private actor CompletionFlag {
    private(set) var completed = false
    func finish() { completed = true }
}

private actor FailingDiagnosticLogger: DiagnosticLogging {
    private(set) var callCount = 0
    private(set) var outcomes: [(DiagnosticComponent, Bool)] = []

    func record(component: DiagnosticComponent, failure: String?, at date: Date) throws {
        callCount += 1
        outcomes.append((component, failure != nil))
        throw MonitoringTestError.failed
    }
}

private actor SilentDiagnosticLogger: DiagnosticLogging {
    func record(component: DiagnosticComponent, failure: String?, at date: Date) {}
}

private actor GatedDiagnosticLogger: DiagnosticLogging {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var events: [(DiagnosticComponent, Date)] = []

    func record(component: DiagnosticComponent, failure: String?, at date: Date) async {
        events.append((component, date))
        if events.count == 1 {
            await withCheckedContinuation { gate = $0 }
        }
    }

    var isBlocked: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private struct FakeMemoryProvider: MemoryProviding {
    var fails = true
    func sample() throws -> MemoryMetric {
        if fails { throw MonitoringTestError.failed }
        return MemoryMetric(usage: 0.5, usedBytes: 500, totalBytes: 1_000)
    }
}

private struct FakeNetworkProvider: NetworkProviding {
    var fails = false
    func sample() throws -> NetworkCounters {
        if fails { throw MonitoringTestError.failed }
        return .init(received: 1_000, sent: 500, interfaces: ["en0"])
    }
}

private struct FailingDiskProvider: DiskProviding {
    func sample() throws -> DiskCounters { throw MonitoringTestError.failed }
}

private actor FakeDiskProvider: DiskProviding {
    private var step: UInt64 = 0
    func sample() -> DiskCounters {
        step += 1
        return DiskCounters(read: step * 100, written: step * 50, usedBytes: 500,
                            totalBytes: 1_000, bsdName: "disk3s1", driverID: step < 3 ? 1 : 2)
    }
}

private struct FakeSensorProvider: SensorProviding {
    var fails = false
    var fan: FanMetric = .fanless
    func sample() throws -> ThermalMetric {
        if fails { throw MonitoringTestError.failed }
        return ThermalMetric(chipTemperatureCelsius: nil, fan: fan)
    }
}

// Suspending hardware fake exposes the real stop-while-collecting race.
private actor GatedMemoryProvider: MemoryProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func sample() async -> MemoryMetric {
        if !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(usage: 0.5, usedBytes: 500, totalBytes: 1_000)
    }
    func isSampling() -> Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
}

private enum MonitoringChecks {
    static func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    static func slowLoggerDoesNotDelaySamples() async throws {
        let logger = GatedDiagnosticLogger()
        let engine = MonitoringEngine(providers: providers(cpu: AdvancingCPUProvider()), logger: logger)
        let firstFinished = CompletionFlag()
        let secondFinished = CompletionFlag()
        let firstDate = Date(timeIntervalSince1970: 1)
        let secondDate = Date(timeIntervalSince1970: 2)
        let first = Task {
            let snapshot = await engine.sample(at: firstDate)
            await firstFinished.finish()
            return snapshot
        }
        let entered = await waitUntil { await logger.isBlocked }
        let firstReturned = await waitUntil { await firstFinished.completed }
        let second = Task {
            let snapshot = await engine.sample(at: secondDate)
            await secondFinished.finish()
            return snapshot
        }
        let secondReturned = await waitUntil { await secondFinished.completed }
        await engine.stop()
        await logger.release()

        try require(entered && firstReturned && secondReturned,
                    "Both samples return while the first log write is blocked")
        let snapshots = await (first.value, second.value)
        try require(snapshots.0.timestamp == firstDate && snapshots.1.timestamp == secondDate,
                    "Nonblocking logging preserves sample results")
        let drained = await waitUntil { await logger.events.count == 10 }
        try require(drained, "Committed log queue drains after release, including after stop")
        let events = await logger.events
        try require(events.map(\.0) == [.cpu, .memory, .network, .disk, .sensors,
                                        .cpu, .memory, .network, .disk, .sensors],
                    "Each sample logs five components in order")
        try require(events.map(\.1) == Array(repeating: firstDate, count: 5)
                    + Array(repeating: secondDate, count: 5),
                    "Log events preserve sample commit order")
    }

    static func slowLoggerDoesNotDelayPublication() async throws {
        let logger = GatedDiagnosticLogger()
        let engine = MonitoringEngine(providers: providers(), logger: logger)
        let stream = await engine.updates()
        let published = CompletionFlag()
        let received = Task {
            var iterator = stream.makeAsyncIterator()
            let update = await iterator.next()
            await published.finish()
            return update
        }
        await engine.start()
        let entered = await waitUntil { await logger.isBlocked }
        let publishedBeforeRelease = await waitUntil { await published.completed }
        await engine.stop()
        await logger.release()
        let update = await received.value
        try require(entered && publishedBeforeRelease && update != nil,
                    "Stream publishes committed sample before logger is released")
        let drained = await waitUntil { await logger.events.count == 5 }
        try require(drained, "Stream sample remains queued for logging after stop")
    }

    static func staleSampleDoesNotLog() async throws {
        let memory = GatedMemoryProvider()
        let logger = FailingDiagnosticLogger()
        let engine = MonitoringEngine(providers: providers(memory: memory), logger: logger)
        let pending = Task { await engine.sample(at: Date(timeIntervalSince1970: 1)) }
        while !(await memory.isSampling()) { await Task.yield() }
        await engine.stop()
        await memory.release()
        let snapshot = await pending.value
        let calls = await logger.callCount
        try require(snapshot.cpuUsage.isUnavailable && calls == 0,
                    "Stopped generation cannot enqueue diagnostics for an uncommitted sample")
    }

    static func loggerTailDoesNotRetainEngine() async throws {
        let logger = GatedDiagnosticLogger()
        var engine: MonitoringEngine? = MonitoringEngine(providers: providers(), logger: logger)
        weak var weakEngine = engine
        _ = await engine!.sample(at: Date(timeIntervalSince1970: 1))
        let entered = await waitUntil { await logger.isBlocked }
        engine = nil
        let released = weakEngine == nil
        await logger.release()
        let drained = await waitUntil { await logger.events.count == 5 }
        try require(entered && released && drained,
                    "Queued diagnostics finish without retaining or blocking engine deinit")
    }

    static func diagnosticLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-resource-monitor-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("diagnostics.log")
        let logger = DiagnosticLogger(logURL: logURL)
        let timestamp = Date(timeIntervalSince1970: 1_767_225_600)

        try require(DiagnosticLogger.displayPath == "~/Library/Logs/MacResourceMonitor/diagnostics.log",
                    "Settings and production logger share the displayed path")
        try require(DiagnosticLogger.logURL.path.hasSuffix("/Library/Logs/MacResourceMonitor/diagnostics.log"),
                    "Production logger uses the displayed file path")
        try await logger.record(component: .cpu, failure: nil, at: timestamp)
        try require(!FileManager.default.fileExists(atPath: logURL.path), "Success does not create log")
        try await logger.record(component: .cpu, failure: "capacityUnavailable(/Users/private/data)", at: timestamp)
        try await logger.record(component: .cpu, failure: "capacityUnavailable(/Users/private/data)", at: timestamp)
        try await logger.record(component: .network, failure: "missingInterfaceData(192.0.2.1)", at: timestamp)
        try await logger.record(component: .cpu, failure: nil, at: timestamp)
        try await logger.record(component: .cpu, failure: "capacityUnavailable(/Users/private/data)", at: timestamp)
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        try require(lines.count == 3, "Repeated failure logs once, recovery allows another, other component logs")
        try require(lines[0].contains("2026-01-01T00:00:00Z") && lines[0].contains("cpu capacityUnavailable"),
                    "Line contains ISO 8601 time, component and safe category")
        try require(lines[1].contains("network missingInterfaceData"), "Components keep separate failure state")
        try require(!lines.joined().contains("/Users/") && !lines.joined().contains("192.0.2.1"),
                    "Private paths and addresses never reach disk")
        try await logger.record(component: .disk, failure: "privateDocumentName.txt", at: timestamp)
        try await logger.record(component: .disk, failure: "privateDocumentName.txt", at: timestamp)
        try await logger.record(component: .disk, failure: "anotherPrivateDocument.txt", at: timestamp)
        let redacted = try String(contentsOf: logURL, encoding: .utf8)
        try require(redacted.split(separator: "\n").count == 5,
                    "Only identical consecutive failures are suppressed")
        try require(redacted.contains("disk 采集失败") && !redacted.contains("privateDocumentName"),
                    "Unknown errors use a generic category")
        try require(!redacted.contains("anotherPrivateDocument"), "Different unknown error remains redacted")
    }

    static func diagnosticWriteFailure() async throws {
        let logger = FailingDiagnosticLogger()
        let engine = MonitoringEngine(providers: providers(memory: FakeMemoryProvider(fails: true)),
                                      logger: logger)
        let snapshot = await engine.sample(at: Date(timeIntervalSince1970: 1))
        let history = await engine.history
        let logged = await waitUntil { await logger.callCount == 5 }
        let calls = await logger.callCount
        let outcomes = await logger.outcomes
        try require(snapshot.memory.isUnavailable && snapshot.disk.value?.usedBytes == 500,
                    "Logging failure does not change readings")
        try require(history.cpu.count == 1, "Logging failure does not discard committed history")
        try require(logged, "Failed logger attempts eventually finish")
        try require(calls == 5, "Every collector outcome reaches logger after commit")
        try require(outcomes.map(\.0) == [.cpu, .memory, .network, .disk, .sensors],
                    "Engine reports each collector under its own component")
        try require(outcomes.map(\.1) == [false, true, false, false, false],
                    "Raw provider failures are logged; derived CPU baseline is not")
    }

    static func providers(memory: any MemoryProviding = FakeMemoryProvider(),
                          sensors: any SensorProviding = FakeSensorProvider(),
                          cpu: any CPUProviding = FakeCPUProvider()) -> ProviderSet {
        ProviderSet(cpu: cpu, memory: memory, network: FakeNetworkProvider(),
                    disk: FakeDiskProvider(), sensors: sensors)
    }

    static func makeEngine(providers: ProviderSet, historyCapacity: Int = 300) -> MonitoringEngine {
        MonitoringEngine(providers: providers, historyCapacity: historyCapacity,
                         logger: SilentDiagnosticLogger())
    }

    // Fails if a thrown memory read cancels other providers, or nil temperature becomes unavailable.
    static func failureIsolation() async throws {
        let engine = makeEngine(providers: providers(cpu: AdvancingCPUProvider()))
        _ = await engine.sample(at: Date(timeIntervalSince1970: 0))
        let snapshot = await engine.sample(at: Date(timeIntervalSince1970: 1))
        try require(snapshot.cpuUsage.value == 0.3, "CPU survives memory failure")
        try require(snapshot.memory.isUnavailable, "Memory error is unavailable")
        try require(snapshot.disk.value?.usedBytes == 500, "Disk capacity survives memory failure")
        try require(snapshot.thermal.value?.fan == .fanless, "Fanless state survives nil temperature")
        try require(snapshot.thermal.value?.chipTemperatureCelsius == nil, "Unknown temperature stays nil")
        let failedSensors = makeEngine(providers: providers(memory: FakeMemoryProvider(fails: false),
                                                                  sensors: FakeSensorProvider(fails: true)))
        let failed = await failedSensors.sample(at: Date())
        try require(failed.thermal.isUnavailable && failed.memory.value?.usage == 0.5, "Sensor failure is isolated")
        let stoppedFan = makeEngine(providers: providers(sensors: FakeSensorProvider(fan: .rpm(0))))
        let stopped = await stoppedFan.sample(at: Date())
        try require(stopped.thermal.value?.fan == .rpm(0), "Zero RPM is distinct from fanless")
        let failedCounters = makeEngine(providers: ProviderSet(
            cpu: FakeCPUProvider(result: .failure(.failed)), memory: FakeMemoryProvider(fails: false),
            network: FakeNetworkProvider(fails: true), disk: FailingDiskProvider(), sensors: FakeSensorProvider()
        ))
        let counters = await failedCounters.sample(at: Date())
        try require(counters.cpuUsage.isUnavailable && counters.network.isUnavailable && counters.disk.isUnavailable,
                    "Each counter provider reports its own failure")
        try require(counters.memory.value?.usage == 0.5 && counters.thermal.value?.fan == .fanless,
                    "Counter failures preserve independent memory and sensors")
    }

    // Fails if unavailable samples become zero or old samples survive the capacity limit.
    static func historyCapacity() async throws {
        let engine = makeEngine(providers: providers(), historyCapacity: 300)
        for second in 1...301 { _ = await engine.sample(at: Date(timeIntervalSince1970: Double(second))) }
        let history = await engine.history
        for points in [history.cpu.elements, history.memory.elements, history.upload.elements, history.download.elements] {
            try require(points.count == 300, "History retains exactly 300 samples")
            try require(points.first?.timestamp == Date(timeIntervalSince1970: 2), "Oldest sample is discarded")
            try require(points.last?.timestamp == Date(timeIntervalSince1970: 301), "Newest sample is retained")
        }
        try require(history.memory.elements.allSatisfy { $0.value == nil }, "Failures create chart gaps")
        try require(history.cpu.elements.allSatisfy { $0.value == nil }, "Zero CPU tick delta is unknown")
        try require(history.upload.elements.last?.value == 0, "Measured idle network is zero")
    }

    // Fails if equal BSD names mask a changed underlying storage driver.
    static func diskDriverChange() async throws {
        let engine = makeEngine(providers: providers())
        var samples: [MetricSnapshot] = []
        for second in 1...4 { samples.append(await engine.sample(at: Date(timeIntervalSince1970: Double(second)))) }
        try require(samples[0].disk.value?.readBytesPerSecond == nil, "First disk sample establishes baseline")
        try require(samples[1].disk.value?.readBytesPerSecond == 100, "Stable driver computes delta")
        try require(samples[2].disk.value?.readBytesPerSecond == nil, "Changed driver rebuilds baseline")
        try require(samples[2].disk.value?.usedBytes == 500, "Baseline reset preserves capacity")
        try require(samples[3].disk.value?.writeBytesPerSecond == 50, "New driver resumes rate calculation")
    }

    // Fails if start creates duplicate loops, stop keeps publishing, or restart cannot subscribe.
    static func lifecycle() async throws {
        let engine = makeEngine(providers: providers())
        let stream = await engine.updates()
        var iterator = stream.makeAsyncIterator()
        await engine.start()
        await engine.start()
        let first = await iterator.next()
        try require(first?.history.cpu.count == 1, "Stream carries snapshot and history")
        try await Task.sleep(for: .milliseconds(100))
        let count = await engine.history.cpu.count
        try require(count == 1, "Repeated start creates one loop")
        let second = await iterator.next()
        try require(second?.history.cpu.count == 2, "Next interval adds one history point")
        try require(second!.snapshot.timestamp.timeIntervalSince(first!.snapshot.timestamp) >= 0.8,
                    "Second update follows the one-second cadence")
        await engine.stop()
        let end = await iterator.next()
        try require(end == nil, "Stop finishes subscribers")
        try await Task.sleep(for: .milliseconds(1_100))
        let stoppedCount = await engine.history.cpu.count
        try require(stoppedCount == 2, "Stopped loop does not sample")
        let restartedStream = await engine.updates()
        var restarted = restartedStream.makeAsyncIterator()
        await engine.start()
        let update = await restarted.next()
        try require(update != nil, "Engine can restart")
        await engine.stop()
    }

    static func stopDuringSample() async throws {
        let memory = GatedMemoryProvider()
        let engine = makeEngine(providers: providers(memory: memory))
        let stream = await engine.updates()
        await engine.start()
        while !(await memory.isSampling()) { await Task.yield() }
        await engine.stop()
        await memory.release()
        var iterator = stream.makeAsyncIterator()
        let update = await iterator.next()
        try require(update == nil, "Cancelled in-flight sample is never published")
    }

    static func cpuBaseline() async throws {
        let engine = makeEngine(providers: providers(cpu: AdvancingCPUProvider()))
        let first = await engine.sample(at: Date(timeIntervalSince1970: 1))
        let second = await engine.sample(at: Date(timeIntervalSince1970: 2))
        let history = await engine.history
        try require(first.cpuUsage.isUnavailable && history.cpu.elements[0].value == nil,
                    "First CPU sample and history must be unavailable")
        try require(second.cpuUsage.value == 0.3 && history.cpu.elements[1].value == 0.3,
                    "Second CPU uses 30 busy ticks out of 100 real delta ticks")
    }

    static func pendingRestart() async throws {
        let memory = GatedMemoryProvider()
        let engine = makeEngine(providers: providers(memory: memory, cpu: AdvancingCPUProvider()))
        await engine.start()
        while !(await memory.isSampling()) { await Task.yield() }
        await engine.stop()
        let restartDate = Date()
        let stream = await engine.updates()
        await engine.start()
        try await Task.sleep(for: .milliseconds(100))
        let historyBeforeRelease = await engine.history
        await memory.release()
        var iterator = stream.makeAsyncIterator()
        let update = await iterator.next()
        try await Task.sleep(for: .milliseconds(100))
        let historyAfterRelease = await engine.history
        await engine.stop()
        try require(historyBeforeRelease.cpu.count == 1, "Restart samples without awaiting the stopped task")
        try require(update != nil && update!.snapshot.timestamp >= restartDate,
                    "Restart must never publish a pre-stop timestamp")
        try require(historyAfterRelease.cpu.count == 1, "Stale sample must not append history")
        try require(update!.snapshot.cpuUsage.isUnavailable, "Stale sample must not seed the new CPU baseline")
    }

    static func concurrentSamples() async throws {
        let memory = GatedMemoryProvider()
        let engine = makeEngine(providers: providers(memory: memory, cpu: AdvancingCPUProvider()))
        let first = Task { await engine.sample(at: Date(timeIntervalSince1970: 1)) }
        while !(await memory.isSampling()) { await Task.yield() }
        let second = Task { await engine.sample(at: Date(timeIntervalSince1970: 2)) }
        try await Task.sleep(for: .milliseconds(100))
        await memory.release()
        let samples = await (first.value, second.value)
        let history = await engine.history
        try require(samples.0.timestamp == Date(timeIntervalSince1970: 1), "First sample retains its timestamp")
        try require(samples.1.timestamp == Date(timeIntervalSince1970: 2), "Second sample retains its own timestamp")
        try require(history.cpu.elements.map(\.timestamp) == [samples.0.timestamp, samples.1.timestamp],
                    "Concurrent requests serialize into two chronological history points")
        try require(samples.1.cpuUsage.value == 0.3, "Second request performs its own physical sample")
    }

    static func streamLifetime() async throws {
        var engine: MonitoringEngine? = makeEngine(providers: providers())
        weak var weakEngine = engine
        let stream = await engine!.updates()
        engine = nil
        try require(weakEngine == nil, "Live continuation must not retain engine")
        let flag = CompletionFlag()
        let waiting = Task {
            var iterator = stream.makeAsyncIterator()
            let update = await iterator.next()
            await flag.finish()
            return update
        }
        try await Task.sleep(for: .milliseconds(100))
        let finishedWithoutCancellation = await flag.completed
        waiting.cancel()
        let result = await waiting.value
        try require(finishedWithoutCancellation && result == nil, "Engine deinit must finish a surviving stream")
    }

    // Fails if the consumption task retains the Store or survives cancellation.
    @MainActor
    static func storeLifetime() async throws {
        let engine = makeEngine(providers: providers())
        var store: MonitoringStore? = MonitoringStore(engine: engine)
        weak var weakStore = store
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store?.snapshot == nil && ContinuousClock.now < deadline { await Task.yield() }
        try require(store?.snapshot != nil && store?.history.cpu.count == 1, "Store publishes engine updates")
        store?.stop()
        let date = store?.snapshot?.timestamp
        try await Task.sleep(for: .milliseconds(1_100))
        try require(store?.snapshot?.timestamp == date, "Store stop cancels consumption")
        store?.start()
        let restartDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store?.snapshot?.timestamp == date && ContinuousClock.now < restartDeadline { await Task.yield() }
        try require(store?.snapshot?.timestamp != date, "Store can restart consumption")
        store = nil
        try require(weakStore == nil, "Consumption does not retain the Store")
        // Allow the stream cancellation handler to reach the engine actor.
        try await Task.sleep(for: .milliseconds(100))
        let count = await engine.history.cpu.count
        try await Task.sleep(for: .milliseconds(1_100))
        let laterCount = await engine.history.cpu.count
        try require(laterCount == count, "Releasing the final subscriber stops engine sampling")
    }
}

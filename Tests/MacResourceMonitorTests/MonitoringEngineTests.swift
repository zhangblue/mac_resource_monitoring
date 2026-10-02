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

    func testConfigurationUpdateTrimsAndPublishesWithoutRebuildingStream() async throws {
        try await MonitoringChecks.configurationTrimsAndPublishes()
    }

    func testConfigurationChangeBetweenCommitAndPublishCannotRestoreOldHistory() async throws {
        try await MonitoringChecks.configurationBetweenCommitAndPublish()
    }

    func testDelayedPublicationKeepsSnapshotAndHistoryPairedAfterNewerCommit() async throws {
        try await MonitoringChecks.configurationBetweenCommitAndPublish(newerCommit: true)
    }

    func testShorterRefreshIntervalCancelsOldWaitAndKeepsHistory() async throws {
        try await MonitoringChecks.shorterIntervalWakesLoop()
    }

    func testConfigurationUpdatePreservesInFlightSampleAndCountsCollectionTime() async throws {
        try await MonitoringChecks.configurationDuringCollection()
    }

    func testDeinitDuringIntervalWaitFinishesLiveStream() async throws {
        try await MonitoringChecks.deinitDuringIntervalWait()
    }

    func testStopRestartDuringIntervalWaitDoesNotReviveOldLoop() async throws {
        try await MonitoringChecks.restartDuringIntervalWait()
    }

    // Fails if trimming excludes the lower boundary or retains points after clock rollback.
    func testHistoryUsesInclusiveTimeWindowAndRemovesFuturePointsAfterRollback() {
        var history = MetricHistory(historyDuration: .oneMinute)
        history.append(.fixture(at: 939))
        history.append(.fixture(at: 940))
        history.append(.fixture(at: 1_000))
        history.append(.fixture(at: 999))
        XCTAssertEqual(history.cpu.elements.map { $0.timestamp.timeIntervalSince1970 }, [940, 999])
        for points in [history.memory.elements, history.upload.elements, history.download.elements] {
            XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [940, 999])
        }
    }

    // Fails if duration changes delay trimming or reconstruct discarded points.
    func testShorteningTrimsImmediatelyAndExtendingDoesNotInventPoints() {
        var history = MetricHistory(historyDuration: .tenMinutes)
        for second in stride(from: 0, through: 600, by: 60) {
            history.append(.fixture(at: TimeInterval(second)))
        }
        history.updateDuration(.oneMinute, endingAt: Date(timeIntervalSince1970: 600))
        XCTAssertEqual(history.cpu.elements.count, 2)
        history.updateDuration(.tenMinutes, endingAt: Date(timeIntervalSince1970: 600))
        XCTAssertEqual(history.cpu.elements.count, 2)
        for points in [history.cpu.elements, history.memory.elements,
                       history.upload.elements, history.download.elements] {
            XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [540, 600])
        }
    }

    // Fails if a full inclusive ten-minute window exceeds the fixed memory ceiling.
    func testHistoryNeverExceedsSixHundredPoints() {
        var history = MetricHistory(historyDuration: .tenMinutes)
        for second in 0...700 { history.append(.fixture(at: TimeInterval(second))) }
        XCTAssertEqual(history.cpu.count, 600)
        XCTAssertEqual(history.cpu.elements.first?.timestamp.timeIntervalSince1970, 101)
        for points in [history.memory.elements, history.upload.elements, history.download.elements] {
            XCTAssertEqual(points.count, 600)
            XCTAssertEqual(points.first?.timestamp.timeIntervalSince1970, 101)
            XCTAssertEqual(points.last?.timestamp.timeIntervalSince1970, 700)
        }
    }

    // Fails if changing duration without a snapshot endpoint loses the next window choice.
    func testDurationUpdateWithoutEndpointAppliesToNextSnapshot() {
        var history = MetricHistory()
        history.updateDuration(.oneMinute, endingAt: nil)
        history.append(.fixture(at: 0))
        history.append(.fixture(at: 61))
        XCTAssertEqual(history.historyDuration, .oneMinute)
        XCTAssertEqual(history.cpu.elements.map { $0.timestamp.timeIntervalSince1970 }, [61])
    }

    func testHistoryPreservesUnavailableGaps() async throws {
        try await MonitoringChecks.historyUnavailableGaps()
    }

    func testDiskCapacityIsAvailableOnEverySample() async throws {
        try await MonitoringChecks.diskCapacityEverySample()
    }

    func testDiskCapacityFailureIsIsolatedAndLogged() async throws {
        try await MonitoringChecks.diskCapacityFailureIsolation()
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
        try await MonitoringChecks.historyUnavailableGaps()
        try await MonitoringChecks.diskCapacityEverySample()
        try await MonitoringChecks.diskCapacityFailureIsolation()
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

private extension MetricSnapshot {
    static func fixture(at second: TimeInterval) -> MetricSnapshot {
        MetricSnapshot(timestamp: Date(timeIntervalSince1970: second), cpuUsage: .value(0.25),
                       memory: .value(MemoryMetric(usage: 0.5, usedBytes: 500, totalBytes: 1_000)),
                       network: .value(NetworkMetric(downloadBytesPerSecond: 100, uploadBytesPerSecond: 50)),
                       thermal: .value(ThermalMetric(chipTemperatureCelsius: 40, fan: .fanless)),
                       disk: .value(DiskMetric(usedBytes: 500, totalBytes: 1_000)))
    }
}

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

private actor UpdateRecorder {
    private(set) var values: [MonitoringUpdate] = []
    private(set) var finished = false
    func append(_ update: MonitoringUpdate) { values.append(update) }
    func finish() { finished = true }
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
    func sample() throws -> DiskMetric { throw MonitoringTestError.failed }
}

private actor FakeDiskProvider: DiskProviding {
    private var step: UInt64 = 0
    func sample() -> DiskMetric {
        step += 1
        return DiskMetric(usedBytes: 500 + step, totalBytes: 1_000)
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
        try require(snapshot.memory.isUnavailable && snapshot.disk.value?.usedBytes == 501,
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

    static func makeEngine(providers: ProviderSet,
                           configuration: MonitoringConfiguration = .init(
                            refreshInterval: .oneSecond, historyDuration: .fiveMinutes)) -> MonitoringEngine {
        MonitoringEngine(providers: providers, logger: SilentDiagnosticLogger(), configuration: configuration)
    }

    static func record(_ stream: AsyncStream<MonitoringUpdate>, in recorder: UpdateRecorder) -> Task<Void, Never> {
        Task {
            for await update in stream { await recorder.append(update) }
            await recorder.finish()
        }
    }

    // Removing immediate history publication must fail within two seconds, without awaiting forever.
    static func configurationTrimsAndPublishes() async throws {
        let engine = makeEngine(providers: providers(), configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .tenMinutes))
        _ = await engine.sample(at: Date(timeIntervalSince1970: 0))
        _ = await engine.sample(at: Date(timeIntervalSince1970: 600))
        let recorder = UpdateRecorder()
        let consumer = record(await engine.updates(), in: recorder)
        await engine.updateConfiguration(.init(refreshInterval: .fiveSeconds, historyDuration: .oneMinute))
        let published = await waitUntil { await recorder.values.count == 1 }
        await engine.stop()
        consumer.cancel()
        await consumer.value
        let update = await recorder.values.first
        try require(published && update?.history.cpu.count == 1,
                    "Existing stream receives immediately trimmed history")
        try require(update?.snapshot.timestamp == Date(timeIntervalSince1970: 600),
                    "History publication reuses the latest committed snapshot")
    }

    // Fails if a delayed publication overwrites the newest buffer with a pre-configuration history copy.
    static func configurationBetweenCommitAndPublish(newerCommit: Bool = false) async throws {
        let engine = makeEngine(providers: providers(cpu: AdvancingCPUProvider()), configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes))
        _ = await engine.sample(at: Date(timeIntervalSince1970: 0))
        let committed = await engine.sample(at: Date(timeIntervalSince1970: 300))
        let delayed = MonitoringUpdate(snapshot: committed, history: await engine.history)
        try require(delayed.history.cpu.count == 2, "Committed update retains both points in the old window")
        if newerCommit { _ = await engine.sample(at: Date(timeIntervalSince1970: 360)) }
        let stream = await engine.updates()

        // Deliberately order commit -> configuration publication -> delayed sample publication.
        // No consumer reads until both yields have completed, exercising bufferingNewest(1).
        await engine.updateConfiguration(.init(refreshInterval: .fiveSeconds, historyDuration: .oneMinute))
        await engine.publish(delayed)
        let recorder = UpdateRecorder()
        let consumer = record(stream, in: recorder)
        let arrived = await waitUntil { await recorder.values.count == 1 }
        await engine.stop()
        consumer.cancel()
        await consumer.value
        let update = await recorder.values.first
        try require(arrived && update?.history.historyDuration == .oneMinute
                    && update?.history.cpu.elements.map(\.timestamp) == [Date(timeIntervalSince1970: 300)],
                    "Buffered delayed publication cannot restore history removed by the new configuration")
        try require(update?.snapshot.timestamp == committed.timestamp
                    && update?.snapshot.cpuUsage.value == committed.cpuUsage.value
                    && update?.snapshot.disk.value?.usedBytes == committed.disk.value?.usedBytes,
                    "History normalization preserves the original committed snapshot")
    }

    // Fails if interval changes cancel the loop, retain its old sleep, or reset history/baselines.
    static func shorterIntervalWakesLoop() async throws {
        let engine = makeEngine(providers: providers(cpu: AdvancingCPUProvider()), configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes))
        let recorder = UpdateRecorder()
        let consumer = record(await engine.updates(), in: recorder)
        await engine.start()
        let firstArrived = await waitUntil { await recorder.values.count == 1 }
        // Reach an existing wait and keep the next sample inside the network calculator's valid interval.
        try await Task.sleep(for: .milliseconds(350))
        let start = ContinuousClock.now
        await engine.updateConfiguration(.init(refreshInterval: .oneSecond, historyDuration: .fiveMinutes))
        let secondArrived = await waitUntil { await recorder.values.count >= 2 }
        let elapsed = start.duration(to: ContinuousClock.now)
        await engine.stop()
        consumer.cancel()
        await consumer.value
        let values = await recorder.values
        try require(firstArrived && secondArrived && elapsed < .seconds(2),
                    "Shorter interval interrupts the five-second wait on the same stream")
        try require(values.count >= 2 && values[1].history.cpu.count == values[0].history.cpu.count + 1,
                    "Interval update preserves existing history")
        try require(values[1].snapshot.cpuUsage.value == 0.3
                    && values[1].snapshot.network.value?.downloadBytesPerSecond == 0,
                    "Configuration changes preserve CPU and network baselines")
    }

    // Fails if reconfiguration cancels in-flight reads or adds a full interval after collection.
    static func configurationDuringCollection() async throws {
        let memory = GatedMemoryProvider()
        let engine = makeEngine(providers: providers(memory: memory, cpu: AdvancingCPUProvider()),
                                configuration: .init(refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes))
        let recorder = UpdateRecorder()
        let consumer = record(await engine.updates(), in: recorder)
        await engine.start()
        let entered = await waitUntil { await memory.isSampling() }
        await engine.updateConfiguration(.init(refreshInterval: .oneSecond, historyDuration: .oneMinute))
        try await Task.sleep(for: .milliseconds(1_100))
        let beforeRelease = await recorder.values.count
        let releasedAt = ContinuousClock.now
        await memory.release()
        let nextArrived = await waitUntil { await recorder.values.count >= 2 }
        let elapsed = releasedAt.duration(to: ContinuousClock.now)
        await engine.stop()
        consumer.cancel()
        await consumer.value
        let values = await recorder.values
        try require(entered && beforeRelease == 0 && nextArrived,
                    "In-flight sample completes before the next cycle publishes")
        try require(elapsed < .milliseconds(700), "Collection time counts toward the new one-second period")
        try require(values[0].snapshot.memory.value?.usage == 0.5
                    && values[1].snapshot.cpuUsage.value == 0.3,
                    "Reconfiguration preserves the in-flight result and its CPU baseline")
        try require(values[1].history.historyDuration == .oneMinute && values[1].history.cpu.count == 2,
                    "The next commit uses the updated history window")
    }

    // Fails if waiting retains the actor and prevents deinit from ending surviving subscriptions.
    static func deinitDuringIntervalWait() async throws {
        var engine: MonitoringEngine? = makeEngine(providers: providers(), configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes))
        weak var weakEngine = engine
        let recorder = UpdateRecorder()
        let consumer = record(await engine!.updates(), in: recorder)
        await engine!.start()
        let firstArrived = await waitUntil { await recorder.values.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        engine = nil
        let ended = await waitUntil { await recorder.finished }
        let released = weakEngine == nil
        await weakEngine?.stop()
        consumer.cancel()
        await consumer.value
        try require(firstArrived && ended && released, "Interval wait does not retain engine or its live stream")
    }

    // Fails if a cancelled old wait resumes its old loop or clears a restarted loop's wait.
    static func restartDuringIntervalWait() async throws {
        let engine = makeEngine(providers: providers(), configuration: .init(
            refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes))
        let oldRecorder = UpdateRecorder()
        let oldConsumer = record(await engine.updates(), in: oldRecorder)
        await engine.start()
        let firstArrived = await waitUntil { await oldRecorder.values.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await engine.stop()
        let recorder = UpdateRecorder()
        let consumer = record(await engine.updates(), in: recorder)
        await engine.start()
        let restarted = await waitUntil { await recorder.values.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await engine.updateConfiguration(.init(refreshInterval: .oneSecond, historyDuration: .fiveMinutes))
        let woke = await waitUntil { await recorder.values.count >= 2 }
        await engine.stop()
        oldConsumer.cancel()
        consumer.cancel()
        await oldConsumer.value
        await consumer.value
        let oldValues = await oldRecorder.values
        let values = await recorder.values
        try require(firstArrived && restarted && woke && oldValues.count == 1,
                    "Stop ends the old subscription and the new loop's wait remains cancellable")
        try require(values.count >= 2 && values[0].history.cpu.count == 2 && values[1].history.cpu.count == 3,
                    "Restart and wake each commit once without reviving an old loop")
    }

    // Fails if a thrown memory read cancels other providers, or nil temperature becomes unavailable.
    static func failureIsolation() async throws {
        let engine = makeEngine(providers: providers(cpu: AdvancingCPUProvider()))
        _ = await engine.sample(at: Date(timeIntervalSince1970: 0))
        let snapshot = await engine.sample(at: Date(timeIntervalSince1970: 1))
        try require(snapshot.cpuUsage.value == 0.3, "CPU survives memory failure")
        try require(snapshot.memory.isUnavailable, "Memory error is unavailable")
        try require(snapshot.disk.value?.usedBytes == 502, "Disk capacity survives memory failure")
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

    // Fails if unavailable samples become zero instead of chart gaps.
    static func historyUnavailableGaps() async throws {
        let engine = makeEngine(providers: providers())
        for second in 1...3 { _ = await engine.sample(at: Date(timeIntervalSince1970: Double(second))) }
        let history = await engine.history
        for points in [history.cpu.elements, history.memory.elements, history.upload.elements, history.download.elements] {
            try require(points.count == 3, "Each collected sample adds a history point")
        }
        try require(history.memory.elements.allSatisfy { $0.value == nil }, "Failures create chart gaps")
        try require(history.cpu.elements.allSatisfy { $0.value == nil }, "Zero CPU tick delta is unknown")
        try require(history.upload.elements.last?.value == 0, "Measured idle network is zero")
    }

    // Fails if disk capacity is delayed for a rate baseline or reused from a previous sample.
    static func diskCapacityEverySample() async throws {
        let engine = makeEngine(providers: providers())
        var samples: [MetricSnapshot] = []
        for second in 1...3 { samples.append(await engine.sample(at: Date(timeIntervalSince1970: Double(second)))) }
        try require(samples.map { $0.disk.value?.usedBytes } == [501, 502, 503],
                    "Every sample publishes current disk capacity")
        try require(samples.allSatisfy { $0.disk.value?.totalBytes == 1_000 },
                    "Disk total capacity remains available from the first sample")
    }

    // Fails if a capacity read error cancels peer readings or is logged as a success.
    static func diskCapacityFailureIsolation() async throws {
        let logger = FailingDiagnosticLogger()
        let engine = MonitoringEngine(providers: ProviderSet(
            cpu: AdvancingCPUProvider(), memory: FakeMemoryProvider(fails: false),
            network: FakeNetworkProvider(), disk: FailingDiskProvider(), sensors: FakeSensorProvider()
        ), logger: logger)
        let snapshot = await engine.sample(at: Date(timeIntervalSince1970: 1))
        let logged = await waitUntil { await logger.callCount == 5 }
        let outcomes = await logger.outcomes
        try require(snapshot.disk.isUnavailable, "Failed disk capacity read becomes unavailable")
        try require(snapshot.memory.value?.usedBytes == 500 && snapshot.thermal.value?.fan == .fanless,
                    "Disk failure leaves independent metrics available")
        try require(logged && outcomes.map(\.1) == [false, false, false, true, false],
                    "Diagnostic log marks only disk collection as failed")
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

import Foundation

struct MetricHistory: Sendable {
    private static let maximumPointCount = 600
    private(set) var historyDuration: HistoryDuration
    var cpu = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var memory = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var upload = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var download = RingBuffer<HistoryPoint>(capacity: maximumPointCount)

    init(historyDuration: HistoryDuration = .fiveMinutes) {
        self.historyDuration = historyDuration
    }

    mutating func append(_ snapshot: MetricSnapshot) {
        let date = snapshot.timestamp
        cpu.append(HistoryPoint(timestamp: date, value: snapshot.cpuUsage.value))
        memory.append(HistoryPoint(timestamp: date, value: snapshot.memory.value?.usage))
        upload.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.uploadBytesPerSecond))
        download.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.downloadBytesPerSecond))
        trim(endingAt: date)
    }

    mutating func updateDuration(_ duration: HistoryDuration, endingAt end: Date?) {
        historyDuration = duration
        if let end { trim(endingAt: end) }
    }

    private mutating func trim(endingAt end: Date) {
        let start = end.addingTimeInterval(-TimeInterval(historyDuration.rawValue))
        let isInWindow: (HistoryPoint) -> Bool = { $0.timestamp >= start && $0.timestamp <= end }
        cpu.replaceContents(with: cpu.elements.filter(isInWindow))
        memory.replaceContents(with: memory.elements.filter(isInWindow))
        upload.replaceContents(with: upload.elements.filter(isInWindow))
        download.replaceContents(with: download.elements.filter(isInWindow))
    }
}

struct MonitoringUpdate: Sendable {
    let snapshot: MetricSnapshot
    let history: MetricHistory
}

actor MonitoringEngine {
    private let providers: ProviderSet
    private let logger: any DiagnosticLogging
    private let sleepMonitor: SystemSleepMonitor
    private var baselineSleepGeneration: UUID?
    private var previousCPU: CPUTicks?
    private var networkCalculator = NetworkRateCalculator()
    private var loop: Task<Void, Never>?
    private var intervalWait: Task<Void, Never>?
    private var intervalWaitID: UUID?
    private var generation = UUID()
    private var sampling: Task<MonitoringUpdate, Never>?
    private var samplingID: UUID?
    private var loggingTail: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<MonitoringUpdate>.Continuation] = [:]
    private(set) var configuration: MonitoringConfiguration
    private var latestSnapshot: MetricSnapshot?
    private(set) var history: MetricHistory

    init(providers: ProviderSet = .live,
         logger: any DiagnosticLogging = DiagnosticLogger.live,
         sleepMonitor: SystemSleepMonitor = SystemSleepMonitor(),
         configuration: MonitoringConfiguration = .init(
            refreshInterval: .oneSecond, historyDuration: .fiveMinutes)) {
        self.providers = providers
        self.logger = logger
        self.sleepMonitor = sleepMonitor
        self.configuration = configuration
        history = MetricHistory(historyDuration: configuration.historyDuration)
    }

    deinit {
        loop?.cancel()
        intervalWait?.cancel()
        intervalWait = nil
        intervalWaitID = nil
        sampling?.cancel()
        for continuation in subscribers.values { continuation.finish() }
    }

    func updates() -> AsyncStream<MonitoringUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func start() {
        guard loop == nil else { return }
        let token = generation
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                // Cadence includes collection time and reads configuration after collection.
                let cycleStart = clock.now
                await self?.sampleAndPublish(generation: token)
                guard !Task.isCancelled,
                      let wait = await self?.makeIntervalWait(startedAt: cycleStart, generation: token) else { break }
                // Await outside the actor so an idle loop does not retain the engine.
                await wait.task.value
                await self?.clearIntervalWait(wait.id, generation: token)
            }
        }
    }

    func stop() {
        generation = UUID()
        loop?.cancel()
        loop = nil
        intervalWait?.cancel()
        intervalWait = nil
        intervalWaitID = nil
        sampling?.cancel()
        sampling = nil
        samplingID = nil
        previousCPU = nil
        networkCalculator = NetworkRateCalculator()
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        continuations.forEach { $0.finish() }
    }

    func updateConfiguration(_ newValue: MonitoringConfiguration) {
        let intervalChanged = configuration.refreshInterval != newValue.refreshInterval
        let historyChanged = configuration.historyDuration != newValue.historyDuration
        configuration = newValue
        if historyChanged {
            history.updateDuration(newValue.historyDuration, endingAt: latestSnapshot?.timestamp)
            if let latestSnapshot {
                let update = MonitoringUpdate(snapshot: latestSnapshot, history: history)
                subscribers.values.forEach { $0.yield(update) }
            }
        }
        if intervalChanged { intervalWait?.cancel() }
    }

    private func makeIntervalWait(startedAt start: ContinuousClock.Instant, generation token: UUID)
        -> (id: UUID, task: Task<Void, Never>)? {
        guard generation == token, !Task.isCancelled else { return nil }
        let deadline = start.advanced(by: .seconds(configuration.refreshInterval.rawValue))
        let id = UUID()
        let clock = ContinuousClock()
        let wait = Task<Void, Never> { try? await clock.sleep(until: deadline) }
        intervalWaitID = id
        intervalWait = wait
        return (id, wait)
    }

    private func clearIntervalWait(_ id: UUID, generation token: UUID) {
        guard generation == token, intervalWaitID == id else { return }
        intervalWait = nil
        intervalWaitID = nil
    }

    func sample(at date: Date = Date()) async -> MetricSnapshot {
        await sampledUpdate(at: date).snapshot
    }

    // Each request owns a task and waits for its predecessor in this generation.
    // Stop detaches the old queue; late reads can finish but cannot commit state.
    private func sampledUpdate(at date: Date) async -> MonitoringUpdate {
        let predecessor = sampling
        let token = generation
        let id = UUID()
        let providers = providers
        let cancelled = MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        let task = Task { [weak self] in
            _ = await predecessor?.value
            guard !Task.isCancelled, await self?.isCurrent(token) == true else { return cancelled }
            guard let sleepState = self?.sleepMonitor.snapshot(), !sleepState.isSleeping else {
                return cancelled
            }
            let readings = await Self.collect(providers)
            return await self?.commit(readings, at: date, generation: token, sleepState: sleepState) ?? cancelled
        }
        sampling = task
        samplingID = id
        let update = await task.value
        if samplingID == id {
            sampling = nil
            samplingID = nil
        }
        return update
    }

    private func sampleAndPublish(generation token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let update = await sampledUpdate(at: Date())
        guard generation == token, !Task.isCancelled else { return }
        publish(update)
    }

    func publish(_ update: MonitoringUpdate) {
        // Configuration may change after commit while the caller resumes from its await.
        // Keep this history paired with its own snapshot, even if another sample has committed.
        var history = update.history
        history.updateDuration(configuration.historyDuration, endingAt: update.snapshot.timestamp)
        let currentUpdate = MonitoringUpdate(snapshot: update.snapshot, history: history)
        for continuation in subscribers.values { continuation.yield(currentUpdate) }
    }

    private func isCurrent(_ token: UUID) -> Bool { generation == token }

    private static func cancelledSnapshot(at date: Date) -> MetricSnapshot {
        MetricSnapshot(timestamp: date, cpuUsage: .unavailable("采样已取消"),
                       memory: .unavailable("采样已取消"), network: .unavailable("采样已取消"),
                       thermal: .unavailable("采样已取消"), disk: .unavailable("采样已取消"))
    }

    private func removeSubscriber(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty { stop() }
    }

    private static func read<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Reading<Value> {
        do { return .value(try await operation()) }
        catch { return .unavailable(String(describing: error)) }
    }

    private typealias ProviderReadings = (Reading<CPUTicks>, Reading<MemoryMetric>, Reading<NetworkCounters>,
                                         Reading<DiskMetric>, Reading<ThermalMetric>)

    private static func collect(_ providers: ProviderSet) async -> ProviderReadings {
        async let cpu = Self.read { try await providers.cpu.sample() }
        async let memory = Self.read { try await providers.memory.sample() }
        async let network = Self.read { try await providers.network.sample() }
        async let disk = Self.read { try await providers.disk.sample() }
        async let thermal = Self.read { try await providers.sensors.sample() }
        return await (cpu, memory, network, disk, thermal)
    }

    private func commit(_ readings: ProviderReadings, at date: Date,
                        generation token: UUID, sleepState: SystemSleepMonitor.State) -> MonitoringUpdate {
        guard generation == token, !Task.isCancelled, sleepState == sleepMonitor.snapshot() else {
            return MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        }

        // Discard in-flight reads crossing a power boundary above, then rebuild
        // both delta baselines from the first complete post-wake collection.
        if baselineSleepGeneration != sleepState.generation {
            previousCPU = nil
            networkCalculator = NetworkRateCalculator()
            baselineSleepGeneration = sleepState.generation
        }

        let snapshot = MetricSnapshot(timestamp: date, cpuUsage: cpuUsage(readings.0),
                                      memory: readings.1, network: networkMetric(readings.2, at: date),
                                      thermal: readings.4, disk: readings.3)
        history.append(snapshot)
        latestSnapshot = snapshot
        enqueueDiagnostics(readings, at: date)
        return MonitoringUpdate(snapshot: snapshot, history: history)
    }

    private func enqueueDiagnostics(_ readings: ProviderReadings, at date: Date) {
        let predecessor = loggingTail
        let logger = logger
        loggingTail = Task.detached {
            _ = await predecessor?.value
            await Self.recordDiagnostics(readings, at: date, logger: logger)
        }
    }

    nonisolated private static func recordDiagnostics(_ readings: ProviderReadings, at date: Date,
                                                      logger: any DiagnosticLogging) async {
        await record(.cpu, reading: readings.0, at: date, logger: logger)
        await record(.memory, reading: readings.1, at: date, logger: logger)
        await record(.network, reading: readings.2, at: date, logger: logger)
        await record(.disk, reading: readings.3, at: date, logger: logger)
        await record(.sensors, reading: readings.4, at: date, logger: logger)
    }

    nonisolated private static func record<Value>(_ component: DiagnosticComponent, reading: Reading<Value>,
                                                  at date: Date, logger: any DiagnosticLogging) async {
        let failure: String?
        switch reading {
        case .value: failure = nil
        case let .unavailable(reason): failure = reason
        }
        try? await logger.record(component: component, failure: failure, at: date)
    }

    private func cpuUsage(_ reading: Reading<CPUTicks>) -> Reading<Double> {
        switch reading {
        case let .unavailable(reason):
            previousCPU = nil
            return .unavailable(reason)
        case let .value(ticks):
            defer { previousCPU = ticks }
            guard let previousCPU,
                  let value = CPUUsageCalculator.usage(previous: previousCPU, current: ticks) else {
                return .unavailable("等待 CPU 采样基线")
            }
            return .value(value)
        }
    }

    private func networkMetric(_ reading: Reading<NetworkCounters>, at date: Date) -> Reading<NetworkMetric> {
        switch reading {
        case let .unavailable(reason):
            networkCalculator = NetworkRateCalculator()
            return .unavailable(reason)
        case let .value(counters):
            return .value(networkCalculator.update(counters, at: date)
                          ?? NetworkMetric(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil))
        }
    }
}

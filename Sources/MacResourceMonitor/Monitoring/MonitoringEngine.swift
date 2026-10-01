import Foundation

struct MetricHistory: Sendable {
    var cpu: RingBuffer<HistoryPoint>
    var memory: RingBuffer<HistoryPoint>
    var upload: RingBuffer<HistoryPoint>
    var download: RingBuffer<HistoryPoint>

    init(capacity: Int = 300) {
        cpu = RingBuffer(capacity: capacity)
        memory = RingBuffer(capacity: capacity)
        upload = RingBuffer(capacity: capacity)
        download = RingBuffer(capacity: capacity)
    }

    mutating func append(_ snapshot: MetricSnapshot) {
        let date = snapshot.timestamp
        cpu.append(HistoryPoint(timestamp: date, value: snapshot.cpuUsage.value))
        memory.append(HistoryPoint(timestamp: date, value: snapshot.memory.value?.usage))
        upload.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.uploadBytesPerSecond))
        download.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.downloadBytesPerSecond))
    }
}

struct MonitoringUpdate: Sendable {
    let snapshot: MetricSnapshot
    let history: MetricHistory
}

actor MonitoringEngine {
    private let providers: ProviderSet
    private let logger: any DiagnosticLogging
    private var previousCPU: CPUTicks?
    private var networkCalculator = NetworkRateCalculator()
    private var diskCalculator = DiskRateCalculator()
    private var diskDriverID: UInt64?
    private var diskBSDName: String?
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var sampling: Task<MonitoringUpdate, Never>?
    private var samplingID: UUID?
    private var subscribers: [UUID: AsyncStream<MonitoringUpdate>.Continuation] = [:]
    private(set) var history: MetricHistory

    init(providers: ProviderSet = .live, historyCapacity: Int = 300,
         logger: any DiagnosticLogging = DiagnosticLogger.live) {
        self.providers = providers
        self.logger = logger
        history = MetricHistory(capacity: historyCapacity)
    }

    deinit {
        loop?.cancel()
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
                // Cadence includes collection time; avoid an extra one-second delay.
                let deadline = clock.now.advanced(by: .seconds(1))
                await self?.sampleAndPublish(generation: token)
                guard !Task.isCancelled else { break }
                do { try await clock.sleep(until: deadline) }
                catch { break }
            }
        }
    }

    func stop() {
        generation = UUID()
        loop?.cancel()
        loop = nil
        sampling?.cancel()
        sampling = nil
        samplingID = nil
        previousCPU = nil
        networkCalculator = NetworkRateCalculator()
        diskCalculator = DiskRateCalculator()
        diskDriverID = nil
        diskBSDName = nil
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        continuations.forEach { $0.finish() }
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
            let readings = await Self.collect(providers)
            return await self?.commit(readings, at: date, generation: token) ?? cancelled
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
        for continuation in subscribers.values { continuation.yield(update) }
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
                                         Reading<DiskCounters>, Reading<ThermalMetric>)

    private static func collect(_ providers: ProviderSet) async -> ProviderReadings {
        async let cpu = Self.read { try await providers.cpu.sample() }
        async let memory = Self.read { try await providers.memory.sample() }
        async let network = Self.read { try await providers.network.sample() }
        async let disk = Self.read { try await providers.disk.sample() }
        async let thermal = Self.read { try await providers.sensors.sample() }
        return await (cpu, memory, network, disk, thermal)
    }

    private func commit(_ readings: ProviderReadings, at date: Date,
                        generation token: UUID) async -> MonitoringUpdate {
        guard generation == token, !Task.isCancelled else {
            return MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        }

        let snapshot = MetricSnapshot(timestamp: date, cpuUsage: cpuUsage(readings.0),
                                      memory: readings.1, network: networkMetric(readings.2, at: date),
                                      thermal: readings.4, disk: diskMetric(readings.3, at: date))
        history.append(snapshot)
        await recordDiagnostics(readings, at: date)
        return MonitoringUpdate(snapshot: snapshot, history: history)
    }

    private func recordDiagnostics(_ readings: ProviderReadings, at date: Date) async {
        await record(.cpu, reading: readings.0, at: date)
        await record(.memory, reading: readings.1, at: date)
        await record(.network, reading: readings.2, at: date)
        await record(.disk, reading: readings.3, at: date)
        await record(.sensors, reading: readings.4, at: date)
    }

    private func record<Value>(_ component: DiagnosticComponent, reading: Reading<Value>,
                               at date: Date) async {
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

    private func diskMetric(_ reading: Reading<DiskCounters>, at date: Date) -> Reading<DiskMetric> {
        switch reading {
        case let .unavailable(reason):
            diskCalculator = DiskRateCalculator()
            diskDriverID = nil
            diskBSDName = nil
            return .unavailable(reason)
        case let .value(counters):
            if counters.driverID != diskDriverID || counters.bsdName != diskBSDName {
                diskCalculator = DiskRateCalculator()
            }
            diskDriverID = counters.driverID
            diskBSDName = counters.bsdName
            let rates = diskCalculator.update(read: counters.read, written: counters.written, at: date)
            return .value(DiskMetric(readBytesPerSecond: rates?.readBytesPerSecond,
                                     writeBytesPerSecond: rates?.writeBytesPerSecond,
                                     usedBytes: counters.usedBytes, totalBytes: counters.totalBytes))
        }
    }
}

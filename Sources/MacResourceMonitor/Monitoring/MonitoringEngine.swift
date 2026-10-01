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
    // The initial CPU reading is the cumulative busy proportion since boot.
    // Subsequent readings use the interval between successful samples.
    private var previousCPU: CPUTicks? = .init(user: 0, system: 0, nice: 0, idle: 0)
    private var networkCalculator = NetworkRateCalculator()
    private var diskCalculator = DiskRateCalculator()
    private var diskDriverID: UInt64?
    private var diskBSDName: String?
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var sampling: Task<MetricSnapshot, Never>?
    private var subscribers: [UUID: AsyncStream<MonitoringUpdate>.Continuation] = [:]
    private(set) var history: MetricHistory

    init(providers: ProviderSet = .live, historyCapacity: Int = 300) {
        self.providers = providers
        history = MetricHistory(capacity: historyCapacity)
    }

    deinit { loop?.cancel() }

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
        let token = UUID()
        generation = token
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
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        continuations.forEach { $0.finish() }
    }

    // Coalesce overlapping requests so actor reentrancy cannot reorder baselines.
    func sample(at date: Date = Date()) async -> MetricSnapshot {
        if let sampling { return await sampling.value }
        let task = Task { await collect(at: date) }
        sampling = task
        let snapshot = await task.value
        sampling = nil
        return snapshot
    }

    private func sampleAndPublish(generation token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let snapshot = await sample()
        guard generation == token, !Task.isCancelled else { return }
        let update = MonitoringUpdate(snapshot: snapshot, history: history)
        for continuation in subscribers.values { continuation.yield(update) }
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

    private func collect(at date: Date) async -> MetricSnapshot {
        let providers = providers
        async let cpu = Self.read { try await providers.cpu.sample() }
        async let memory = Self.read { try await providers.memory.sample() }
        async let network = Self.read { try await providers.network.sample() }
        async let disk = Self.read { try await providers.disk.sample() }
        async let thermal = Self.read { try await providers.sensors.sample() }
        let readings = await (cpu, memory, network, disk, thermal)

        let snapshot = MetricSnapshot(timestamp: date, cpuUsage: cpuUsage(readings.0),
                                      memory: readings.1, network: networkMetric(readings.2, at: date),
                                      thermal: readings.4, disk: diskMetric(readings.3, at: date))
        history.append(snapshot)
        return snapshot
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

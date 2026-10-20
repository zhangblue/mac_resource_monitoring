import Foundation

struct MetricHistory: Sendable {
    private static let maximumPointCount = 600
    private(set) var historyDuration: HistoryDuration
    private(set) var durationRevision = UUID()
    var cpu = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var memory = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var upload = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var download = RingBuffer<HistoryPoint>(capacity: maximumPointCount)

    init(historyDuration: HistoryDuration = .fiveMinutes) {
        self.historyDuration = historyDuration
    }

    mutating func append(_ snapshot: MetricSnapshot, selection: MetricSelection = .all) {
        let date = snapshot.timestamp
        // Mark each active curve from its own previous sample before trimming
        // removes points in the rolled-back future (including when CPU is off).
        func startsNewSegment(_ buffer: RingBuffer<HistoryPoint>) -> Bool {
            buffer.elements.last.map { date <= $0.timestamp } ?? false
        }
        if selection.contains(.cpu) {
            cpu.append(HistoryPoint(timestamp: date, value: snapshot.cpuUsage.value,
                                    startsNewSegment: startsNewSegment(cpu)))
        }
        if selection.contains(.memory) {
            memory.append(HistoryPoint(timestamp: date, value: snapshot.memory.value?.usage,
                                       startsNewSegment: startsNewSegment(memory)))
        }
        if selection.contains(.upload) {
            upload.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.uploadBytesPerSecond,
                                       startsNewSegment: startsNewSegment(upload)))
        }
        if selection.contains(.download) {
            download.append(HistoryPoint(timestamp: date, value: snapshot.network.value?.downloadBytesPerSecond,
                                         startsNewSegment: startsNewSegment(download)))
        }
        trim(endingAt: date)
    }

    mutating func clearDisabled(_ selection: MetricSelection) {
        durationRevision = UUID() // Also invalidates delayed pre-selection publications.
        if !selection.contains(.cpu) { cpu.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.memory) { memory.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.upload) { upload.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.download) { download.replaceContents(with: [HistoryPoint]()) }
    }

    mutating func updateDuration(_ duration: HistoryDuration, endingAt end: Date?) {
        if historyDuration != duration { durationRevision = UUID() }
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

private struct CollectionPlan: Sendable {
    let selection: MetricSelection
    func includes(_ section: MetricSection) -> Bool { selection.contains(section) }
    var network: Bool { includes(.upload) || includes(.download) }
    var sensors: Bool { includes(.chipTemperature) || includes(.fan) }
    var systemProcesses: Bool { includes(.cpu) || includes(.memory) }
}

private final class PlanRevisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UUID
    init(_ revision: UUID) { self.revision = revision }
    func set(_ value: UUID) {
        lock.lock()
        revision = value
        lock.unlock()
    }
    func contains(_ value: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == value
    }
}

actor MonitoringEngine {
    private let providers: ProviderSet
    private let logger: any DiagnosticLogging
    private let sleepMonitor: SystemSleepMonitor
    private var baselineSleepGeneration: UUID?
    private var previousCPU: CPUTicks?
    private var networkCalculator = NetworkRateCalculator()
    private var processCalculator = ProcessRankingCalculator()
    private var loop: Task<Void, Never>?
    private var intervalWait: Task<Void, Never>?
    private var intervalWaitID: UUID?
    private var generation = UUID()
    private var planRevision: UUID
    private let diagnosticGate: PlanRevisionGate
    private var selectionCleanup: Task<Void, Never>?
    private var needsUploadBaseline = false
    private var needsDownloadBaseline = false
    private var needsCPUProcessBaseline = false
    private var needsUploadProcessBaseline = false
    private var needsDownloadProcessBaseline = false
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
        sleepMonitor.setSleepHandler { [processes = providers.processes] in await processes.cancel() }
        self.configuration = configuration
        let revision = UUID()
        planRevision = revision
        diagnosticGate = PlanRevisionGate(revision)
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

    func stop() async {
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
        processCalculator.resetRates()
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        continuations.forEach { $0.finish() }
        await selectionCleanup?.value
        selectionCleanup = nil
        await providers.processes.cancel()
    }

    func updateConfiguration(_ newValue: MonitoringConfiguration) {
        let intervalChanged = configuration.refreshInterval != newValue.refreshInterval
        let historyChanged = configuration.historyDuration != newValue.historyDuration
        let selectionChanged = configuration.selection != newValue.selection
        let oldPlan = CollectionPlan(selection: configuration.selection)
        let plan = CollectionPlan(selection: newValue.selection)
        configuration = newValue
        if selectionChanged {
            planRevision = UUID()
            diagnosticGate.set(planRevision)
            sampling?.cancel()
            // Cancel process work before a new plan can enter the provider.
            let priorCleanup = selectionCleanup
            let processes = providers.processes
            selectionCleanup = Task {
                await priorCleanup?.value
                await processes.cancel()
            }
            if !plan.includes(.cpu) { previousCPU = nil }
            if !plan.network { networkCalculator = NetworkRateCalculator() }
            if !plan.systemProcesses { processCalculator.resetSystemRates() }
            if !plan.network { processCalculator.resetNetworkRates() }
            needsCPUProcessBaseline = plan.includes(.cpu) &&
                (needsCPUProcessBaseline || !oldPlan.includes(.cpu))
            needsUploadBaseline = plan.includes(.upload) &&
                (needsUploadBaseline || !oldPlan.includes(.upload))
            needsDownloadBaseline = plan.includes(.download) &&
                (needsDownloadBaseline || !oldPlan.includes(.download))
            needsUploadProcessBaseline = plan.includes(.upload) &&
                (needsUploadProcessBaseline || !oldPlan.includes(.upload))
            needsDownloadProcessBaseline = plan.includes(.download) &&
                (needsDownloadProcessBaseline || !oldPlan.includes(.download))
            history.clearDisabled(newValue.selection)
            if let latestSnapshot {
                self.latestSnapshot = Self.filtered(latestSnapshot, plan: plan)
            }
            if let latestSnapshot = self.latestSnapshot {
                subscribers.values.forEach { $0.yield(.init(snapshot: latestSnapshot, history: history)) }
            }
            intervalWait?.cancel()
        }
        if historyChanged {
            history.updateDuration(newValue.historyDuration, endingAt: latestSnapshot?.timestamp)
            if let latestSnapshot {
                let update = MonitoringUpdate(snapshot: latestSnapshot, history: history)
                subscribers.values.forEach { $0.yield(update) }
            }
        }
        if intervalChanged {
            processCalculator.resetRates()
            intervalWait?.cancel()
        }
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
        let revision = planRevision
        let plan = CollectionPlan(selection: configuration.selection)
        let cleanup = selectionCleanup
        let id = UUID()
        let providers = providers
        let sleepMonitor = sleepMonitor
        let cancelled = MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        let task = Task { [weak self] in
            await cleanup?.value
            _ = await predecessor?.value
            await sleepMonitor.waitForSleepCleanup()
            guard !Task.isCancelled, await self?.isCurrent(token, revision: revision) == true else { return cancelled }
            guard let sleepState = self?.sleepMonitor.snapshot(), !sleepState.isSleeping else {
                return cancelled
            }
            let readings = await Self.collect(providers, plan: plan)
            await sleepMonitor.waitForSleepCleanup()
            return await self?.commit(readings, at: date, generation: token, revision: revision,
                                      plan: plan, sleepState: sleepState) ?? cancelled
        }
        sampling = task
        samplingID = id
        sleepMonitor.registerSampling(id) { task.cancel() }
        let update = await task.value
        sleepMonitor.unregisterSampling(id)
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
        // Duration changes already publish the latest snapshot with the retained history.
        // Reject older copies even after a shorten/extend round trip; refresh-only changes remain valid.
        guard update.history.durationRevision == history.durationRevision else { return }
        // A valid delayed update still owns its original snapshot/history pair.
        for continuation in subscribers.values { continuation.yield(update) }
    }

    private func isCurrent(_ token: UUID, revision: UUID) -> Bool {
        generation == token && planRevision == revision
    }

    private static func cancelledSnapshot(at date: Date) -> MetricSnapshot {
        MetricSnapshot(timestamp: date, cpuUsage: .unavailable("采样已取消"),
                       memory: .unavailable("采样已取消"), network: .unavailable("采样已取消"),
                       thermal: .unavailable("采样已取消"), disk: .unavailable("采样已取消"))
    }

    private func removeSubscriber(_ id: UUID) async {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty { await stop() }
    }

    private static func read<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Reading<Value> {
        do { return .value(try await operation()) }
        catch { return .unavailable(String(describing: error)) }
    }

    private struct ProviderReadings: Sendable {
        let cpu: Reading<CPUTicks>
        let memory: Reading<MemoryMetric>
        let network: Reading<NetworkCounters>
        let disk: Reading<DiskMetric>
        let sensors: SensorReadings
        let processes: ProcessRawSnapshot
    }

    private static func collect(_ providers: ProviderSet, plan: CollectionPlan) async -> ProviderReadings {
        async let cpu: Reading<CPUTicks> = plan.includes(.cpu)
            ? Self.read { try await providers.cpu.sample() } : .unavailable("notSelected")
        async let memory: Reading<MemoryMetric> = plan.includes(.memory)
            ? Self.read { try await providers.memory.sample() } : .unavailable("notSelected")
        async let network: Reading<NetworkCounters> = plan.network
            ? Self.read { try await providers.network.sample() } : .unavailable("notSelected")
        async let disk: Reading<DiskMetric> = plan.includes(.diskCapacity)
            ? Self.read { try await providers.disk.sample() } : .unavailable("notSelected")
        async let sensors: SensorReadings = plan.sensors
            ? providers.sensors.sample(temperature: plan.includes(.chipTemperature), fan: plan.includes(.fan))
            : .init(temperature: .unavailable("notSelected"), fan: .unavailable("notSelected"))
        async let processes: ProcessRawSnapshot = (plan.systemProcesses || plan.network)
            ? providers.processes.sample(system: plan.systemProcesses, network: plan.network)
            : .init(system: .unavailable("notSelected"), network: .unavailable("notSelected"))
        return await ProviderReadings(cpu: cpu, memory: memory, network: network,
                                      disk: disk, sensors: sensors, processes: processes)
    }

    private func commit(_ readings: ProviderReadings, at date: Date,
                        generation token: UUID, revision: UUID, plan: CollectionPlan,
                        sleepState: SystemSleepMonitor.State) -> MonitoringUpdate {
        guard generation == token, planRevision == revision, !Task.isCancelled,
              sleepState == sleepMonitor.snapshot() else {
            return MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        }

        // Discard in-flight reads crossing a power boundary above, then rebuild
        // both delta baselines from the first complete post-wake collection.
        if baselineSleepGeneration != sleepState.generation {
            previousCPU = nil
            networkCalculator = NetworkRateCalculator()
            processCalculator.resetRates()
            baselineSleepGeneration = sleepState.generation
        }

        var processes = processCalculator.update(system: readings.processes.system,
                                                 network: readings.processes.network, at: date)
        if needsCPUProcessBaseline && readings.processes.system.value != nil {
            processes = .init(cpu: .unavailable("等待进程采样基线"), memory: processes.memory,
                              upload: processes.upload, download: processes.download)
            needsCPUProcessBaseline = false
        }
        if needsUploadProcessBaseline && readings.processes.network.value != nil {
            processes = .init(cpu: processes.cpu, memory: processes.memory,
                              upload: .unavailable("等待进程采样基线"), download: processes.download)
            needsUploadProcessBaseline = false
        }
        if needsDownloadProcessBaseline && readings.processes.network.value != nil {
            processes = .init(cpu: processes.cpu, memory: processes.memory,
                              upload: processes.upload, download: .unavailable("等待进程采样基线"))
            needsDownloadProcessBaseline = false
        }
        let sensors = readings.sensors
        let thermal: Reading<ThermalMetric> = sensors.fan.value.map {
            .value(.init(chipTemperatureCelsius: sensors.temperature.value, fan: $0))
        } ?? .unavailable("notSelected")
        let snapshot = Self.filtered(MetricSnapshot(timestamp: date, cpuUsage: cpuUsage(readings.cpu),
            memory: readings.memory, network: networkMetric(readings.network, at: date),
            thermal: thermal, disk: readings.disk, processes: processes,
            temperature: sensors.temperature, fan: sensors.fan), plan: plan)
        history.append(snapshot, selection: plan.selection)
        latestSnapshot = snapshot
        enqueueDiagnostics(readings, plan: plan, revision: revision, at: date)
        return MonitoringUpdate(snapshot: snapshot, history: history)
    }

    private static func filtered(_ snapshot: MetricSnapshot, plan: CollectionPlan) -> MetricSnapshot {
        let missing = "notSelected"
        let upload = plan.includes(.upload)
        let download = plan.includes(.download)
        let network: Reading<NetworkMetric> = plan.network ? snapshot.network.value.map {
            .value(.init(downloadBytesPerSecond: download ? $0.downloadBytesPerSecond : nil,
                         uploadBytesPerSecond: upload ? $0.uploadBytesPerSecond : nil))
        } ?? snapshot.network : .unavailable(missing)
        let temperature: Reading<Double> = plan.includes(.chipTemperature)
            ? snapshot.temperature : .unavailable(missing)
        let fan: Reading<FanMetric> = plan.includes(.fan) ? snapshot.fan : .unavailable(missing)
        let thermal: Reading<ThermalMetric> = fan.value.map {
            .value(.init(chipTemperatureCelsius: temperature.value, fan: $0))
        } ?? .unavailable(missing)
        let ranks = snapshot.processes
        return .init(timestamp: snapshot.timestamp,
            cpuUsage: plan.includes(.cpu) ? snapshot.cpuUsage : .unavailable(missing),
            memory: plan.includes(.memory) ? snapshot.memory : .unavailable(missing),
            network: network, thermal: thermal,
            disk: plan.includes(.diskCapacity) ? snapshot.disk : .unavailable(missing),
            processes: .init(cpu: plan.includes(.cpu) ? ranks.cpu : .unavailable(missing),
                memory: plan.includes(.memory) ? ranks.memory : .unavailable(missing),
                upload: upload ? ranks.upload : .unavailable(missing),
                download: download ? ranks.download : .unavailable(missing)),
            temperature: temperature, fan: fan)
    }

    private func enqueueDiagnostics(_ readings: ProviderReadings, plan: CollectionPlan,
                                    revision: UUID, at date: Date) {
        let predecessor = loggingTail
        let logger = logger
        let gate = diagnosticGate
        loggingTail = Task.detached {
            _ = await predecessor?.value
            let isCurrent: @Sendable () async -> Bool = { gate.contains(revision) }
            await Self.recordDiagnostics(readings, plan: plan, at: date, logger: logger, isCurrent: isCurrent)
        }
    }

    nonisolated private static func recordDiagnostics(_ readings: ProviderReadings, plan: CollectionPlan,
        at date: Date, logger: any DiagnosticLogging,
        isCurrent: @escaping @Sendable () async -> Bool) async {
        if plan.includes(.cpu), await isCurrent() {
            await record(.cpu, reading: readings.cpu, at: date, logger: logger)
        }
        if plan.includes(.memory), await isCurrent() {
            await record(.memory, reading: readings.memory, at: date, logger: logger)
        }
        if plan.network, await isCurrent() {
            await record(.network, reading: readings.network, at: date, logger: logger)
        }
        if plan.includes(.diskCapacity), await isCurrent() {
            await record(.disk, reading: readings.disk, at: date, logger: logger)
        }
        if plan.sensors, await isCurrent() {
            let sensor: Reading<Bool>
            if plan.includes(.chipTemperature),
               case let .unavailable(reason) = readings.sensors.temperature {
                sensor = .unavailable(reason)
            } else if plan.includes(.fan), case let .unavailable(reason) = readings.sensors.fan {
                sensor = .unavailable(reason)
            } else {
                sensor = .value(true)
            }
            await record(.sensors, reading: sensor, at: date, logger: logger)
        }
        if plan.systemProcesses, await isCurrent() {
            await record(.processSystem, reading: readings.processes.system, at: date, logger: logger)
        }
        if plan.network, await isCurrent() {
            await record(.processNetwork, reading: readings.processes.network, at: date, logger: logger)
        }
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
            let metric = networkCalculator.update(counters, at: date)
                ?? NetworkMetric(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)
            let result = NetworkMetric(
                downloadBytesPerSecond: needsDownloadBaseline ? nil : metric.downloadBytesPerSecond,
                uploadBytesPerSecond: needsUploadBaseline ? nil : metric.uploadBytesPerSecond)
            needsDownloadBaseline = false
            needsUploadBaseline = false
            return .value(result)
        }
    }
}

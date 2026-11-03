import Foundation

struct MetricHistory: Sendable {
    private static let maximumPointCount = 600
    private(set) var historyDuration: HistoryDuration
    private(set) var durationRevision = UUID()
    var cpu = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var memory = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var upload = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var download = RingBuffer<HistoryPoint>(capacity: maximumPointCount)

    /// 创建指定时间窗口的历史缓冲区；监控引擎初始化或测试构造历史时调用。
    init(historyDuration: HistoryDuration = .fiveMinutes) {
        self.historyDuration = historyDuration
    }

    /// 将选中指标追加到历史并裁剪窗口；每次有效采样提交后调用。
    /// 四条曲线使用独立固定容量环形缓冲区，单项最多 600 点；未选中的指标既不追加也不会制造零值。
    mutating func append(_ snapshot: MetricSnapshot, selection: MetricSelection = .all) {
        let date = snapshot.timestamp
        // 裁剪回拨后的“未来”点之前，先以每条曲线自身的末点判断是否需要断开新线段。
        /// 判断当前时间是否回拨；每条启用曲线写入新历史点前调用。
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

    /// 清空已关闭板块的历史并使旧发布失效；板块选择变化时调用。
    /// 更新 UUID 版本令牌，使已经离开 Actor、携带旧历史副本的异步发布在返回时可被拒绝。
    mutating func clearDisabled(_ selection: MetricSelection) {
        durationRevision = UUID() // Also invalidates delayed pre-selection publications.
        if !selection.contains(.cpu) { cpu.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.memory) { memory.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.upload) { upload.replaceContents(with: [HistoryPoint]()) }
        if !selection.contains(.download) { download.replaceContents(with: [HistoryPoint]()) }
    }

    /// 更新保留时长并按最新时间裁剪；用户修改历史窗口时调用。
    mutating func updateDuration(_ duration: HistoryDuration, endingAt end: Date?) {
        if historyDuration != duration { durationRevision = UUID() }
        historyDuration = duration
        if let end { trim(endingAt: end) }
    }

    /// 将四条趋势限制在当前时间窗口内；追加采样或修改窗口后调用。
    /// 使用闭区间同时排除窗口前数据和系统时钟回拨产生的未来点，每条曲线裁剪复杂度 O(n)。
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
    /// 判断单个板块是否启用；构建各采集器依赖时调用。
    func includes(_ section: MetricSection) -> Bool { selection.contains(section) }
    /// 判断是否需要共享网络采集；上传或下载任一板块启用时读取。
    var network: Bool { includes(.upload) || includes(.download) }
    /// 判断是否需要共享 SMC 采集；温度或风扇任一板块启用时读取。
    var sensors: Bool { includes(.chipTemperature) || includes(.fan) }
    /// 判断是否需要扫描进程系统数据；CPU 或内存任一板块启用时读取。
    var systemProcesses: Bool { includes(.cpu) || includes(.memory) }
}

private final class PlanRevisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UUID
    /// 创建线程安全的计划版本门；监控引擎初始化时调用。
    init(_ revision: UUID) { self.revision = revision }
    /// 更新当前计划版本；板块选择发生变化时调用。
    func set(_ value: UUID) {
        lock.lock()
        revision = value
        lock.unlock()
    }
    /// 判断诊断任务是否仍属于当前计划；异步写日志前调用。
    /// 该小型锁对象允许 detached 日志任务做同步版本检查，而不必重新进入 MonitoringEngine Actor。
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

    /// 组装采集器、日志、电源监控与初始设置；应用启动或测试注入依赖时调用。
    /// Actor 隔离所有可变基线、历史和订阅；外部提供器保持 Sendable，并只通过异步边界访问。
    init(providers: ProviderSet = .live,
         logger: any DiagnosticLogging = DiagnosticLogger.live,
         sleepMonitor: SystemSleepMonitor = SystemSleepMonitor(),
         configuration: MonitoringConfiguration = .init(
            refreshInterval: .oneSecond, historyDuration: .fiveMinutes)) {
        self.providers = providers
        self.logger = logger
        self.sleepMonitor = sleepMonitor
        // 睡眠开始时优先终止可能长期运行的 nettop 子进程，避免唤醒后残留。
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

    /// 创建只保留最新值的更新流；界面存储开始观察监控结果时调用。
    /// bufferingNewest(1) 提供背压：UI 消费较慢时丢弃中间帧，但保留最新快照以避免采样循环被阻塞。
    func updates() -> AsyncStream<MonitoringUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    /// 启动周期采样循环；首个界面订阅准备完成后调用，重复调用不会创建第二个循环。
    /// 使用 ContinuousClock 计算单调时钟截止点，刷新周期包含采集耗时，不受系统墙上时钟回拨影响。
    func start() {
        guard loop == nil else { return }
        let token = generation
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                // 周期包含采集耗时，并在采集结束后读取最新刷新间隔。
                let cycleStart = clock.now
                await self?.sampleAndPublish(generation: token)
                guard !Task.isCancelled,
                      let wait = await self?.makeIntervalWait(startedAt: cycleStart, generation: token) else { break }
                // 在 actor 外等待，使空闲循环不会额外持有引擎。
                await wait.task.value
                await self?.clearIntervalWait(wait.id, generation: token)
            }
        }
    }

    /// 完整停止循环、取消采样并清理基线和订阅；最后一个订阅结束或测试收尾时调用。
    /// 更换 generation 令牌后再取消任务，确保无法及时停止的系统读取即使迟到也不能提交状态。
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
        // 等待选择切换的进程清理后再次取消，确保没有遗留外部进程。
        await selectionCleanup?.value
        selectionCleanup = nil
        await providers.processes.cancel()
    }

    /// 应用刷新间隔、历史窗口和板块选择；设置变化时由 MonitoringStore 顺序调用。
    /// 选择变化会更新 planRevision、取消进程子任务并只重置相关差值基线；刷新与历史变化各自保持无关状态。
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
            // 新计划进入提供器前先取消旧进程采集，避免 nettop 调用重叠。
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

    /// 创建本轮剩余刷新间隔的等待任务；周期采样完成后调用。
    /// 独立 Task 在 Actor 外睡眠，ID 与 generation 双重校验防止旧等待任务清除新循环的引用。
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

    /// 清理仍属于当前代次的等待引用；间隔任务结束后调用。
    private func clearIntervalWait(_ id: UUID, generation token: UUID) {
        guard generation == token, intervalWaitID == id else { return }
        intervalWait = nil
        intervalWaitID = nil
    }

    /// 主动执行一次采样并返回快照；测试或单次读取场景调用，不负责发布。
    func sample(at date: Date = Date()) async -> MetricSnapshot {
        await sampledUpdate(at: date).snapshot
    }

    // 每个请求拥有独立任务并等待同代前序任务；停止会切断旧队列，迟到读取不能提交状态。
    /// 串行完成一次采样并生成更新；周期循环和单次采样入口共同调用。
    /// 每个请求等待 predecessor，形成 Actor 外的有序采样链；睡眠状态、generation 和 planRevision 在采集前后均复核。
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
        // 关键采样调用前依次等待选择切换清理、前序采样和睡眠清理，确保状态边界明确。
        let task = Task { [weak self] in
            await cleanup?.value
            _ = await predecessor?.value
            await sleepMonitor.waitForSleepCleanup()
            guard !Task.isCancelled, await self?.isCurrent(token, revision: revision) == true else { return cancelled }
            guard let sleepState = self?.sleepMonitor.snapshot(), !sleepState.isSleeping else {
                return cancelled
            }
            // 所有独立提供器并发采集，单项失败由 Reading 隔离。
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

    /// 执行并发布一轮周期采样；主循环每个刷新周期调用。
    private func sampleAndPublish(generation token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let update = await sampledUpdate(at: Date())
        guard generation == token, !Task.isCancelled else { return }
        publish(update)
    }

    /// 向所有订阅者广播仍有效的更新；采样结束或测试注入更新时调用。
    func publish(_ update: MonitoringUpdate) {
        // 历史时长变化会主动发布保留结果；即使先缩短再恢复，也拒绝旧版本副本。
        guard update.history.durationRevision == history.durationRevision else { return }
        // 合法的延迟更新仍携带其原始快照与历史配对，必须整体发布。
        for continuation in subscribers.values { continuation.yield(update) }
    }

    /// 校验任务代次与采样计划版本；异步任务提交采集结果前调用。
    private func isCurrent(_ token: UUID, revision: UUID) -> Bool {
        generation == token && planRevision == revision
    }

    /// 创建统一的取消快照；睡眠、停止或计划切换导致采样失效时调用。
    private static func cancelledSnapshot(at date: Date) -> MetricSnapshot {
        MetricSnapshot(timestamp: date, cpuUsage: .unavailable("采样已取消"),
                       memory: .unavailable("采样已取消"), network: .unavailable("采样已取消"),
                       thermal: .unavailable("采样已取消"), disk: .unavailable("采样已取消"))
    }

    /// 移除订阅并在无人观察时停止引擎；AsyncStream 终止回调中调用。
    private func removeSubscriber(_ id: UUID) async {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty { await stop() }
    }

    /// 将抛错异步采集转换为 Reading；并发读取各系统提供器时调用以隔离失败。
    /// 泛型闭包要求 Sendable，任何 Error 只转成当前分支的不可用值，不会取消同组 async let 任务。
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

    /// 按采样计划并发读取所需数据；每轮有效采样在提交前调用，未选择模块不会触发提供器。
    /// async let 并发执行六类独立 I/O；网络方向、传感器和进程扫描按共享依赖合并，避免重复系统调用。
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

    /// 校验边界、更新差值基线并提交快照和历史；所有采集器返回后调用。
    /// commit 仅在 Actor 内执行，先验证任务代次与睡眠快照，再原子更新基线、历史和 latestSnapshot。
    private func commit(_ readings: ProviderReadings, at date: Date,
                        generation token: UUID, revision: UUID, plan: CollectionPlan,
                        sleepState: SystemSleepMonitor.State) -> MonitoringUpdate {
        guard generation == token, planRevision == revision, !Task.isCancelled,
              sleepState == sleepMonitor.snapshot() else {
            return MonitoringUpdate(snapshot: Self.cancelledSnapshot(at: date), history: history)
        }

        // 上方已丢弃跨电源边界的读取；唤醒后的首轮完整采集用于重建所有差值基线。
        if baselineSleepGeneration != sleepState.generation {
            previousCPU = nil
            networkCalculator = NetworkRateCalculator()
            processCalculator.resetRates()
            baselineSleepGeneration = sleepState.generation
        }

        // 进程累计计数通过计算器与上一轮比较，生成 CPU 和网络速率榜单。
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
        // 快照提交后依次写入趋势、保存最新值并异步记录诊断。
        history.append(snapshot, selection: plan.selection)
        latestSnapshot = snapshot
        enqueueDiagnostics(readings, plan: plan, revision: revision, at: date)
        return MonitoringUpdate(snapshot: snapshot, history: history)
    }

    /// 按当前选择隐藏未启用读数及榜单；切换设置或提交新快照时调用。
    /// 共享网络读数会按方向置空，进程榜单分别过滤，从数据模型层保证隐藏板块不会被 UI 意外读取。
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

    /// 将诊断任务串联到独立队列；快照提交后调用，避免日志 I/O 阻塞监控 actor。
    /// loggingTail 构成单链保证日志时序，detached Task 不继承 Actor 执行器，版本门阻止旧计划写入。
    private func enqueueDiagnostics(_ readings: ProviderReadings, plan: CollectionPlan,
                                    revision: UUID, at date: Date) {
        let predecessor = loggingTail
        let logger = logger
        let gate = diagnosticGate
        loggingTail = Task.detached {
            // 保持日志顺序，并在写入前再次验证采样计划未被切换。
            _ = await predecessor?.value
            let isCurrent: @Sendable () async -> Bool = { gate.contains(revision) }
            await Self.recordDiagnostics(readings, plan: plan, at: date, logger: logger, isCurrent: isCurrent)
        }
    }

    /// 按采样计划记录各组件成功或失败；诊断队列执行时调用，过期计划会停止后续写入。
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

    /// 将 Reading 转换为诊断失败字段并安全写入日志；记录单个组件时调用。
    nonisolated private static func record<Value>(_ component: DiagnosticComponent, reading: Reading<Value>,
                                                  at date: Date, logger: any DiagnosticLogging) async {
        let failure: String?
        switch reading {
        case .value: failure = nil
        case let .unavailable(reason): failure = reason
        }
        try? await logger.record(component: component, failure: failure, at: date)
    }

    /// 用相邻累计时钟计算 CPU 使用率；提交 CPU 采样时调用，首次只建立基线。
    /// Mach 计数是累计值；defer 在成功读取后保存本轮基线，计数回拨或失败会清空基线并返回不可用。
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

    /// 用相邻累计字节计算网络速率；提交网络采样时调用，首次或重新启用后只建立基线。
    /// NetworkRateCalculator 校验接口集合、时间间隔和计数单调性；方向级标记保证只让重新启用的一侧等待基线。
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

import Combine
import Foundation

@MainActor
final class MonitoringStore: ObservableObject {
    @Published private(set) var snapshot: MetricSnapshot?
    @Published private(set) var history = MetricHistory()
    @Published private(set) var selection: MetricSelection

    let settings: MonitoringSettings

    private let engine: MonitoringEngine
    private let configurationReady: Task<Void, Never>
    private var consumption: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var configurationConsumption: Task<Void, Never>?

    /// 组装设置、引擎和更新流；菜单栏应用创建共享状态时调用，也允许测试注入替身。
    /// Store 固定在 MainActor，将 Combine 设置流桥接为 AsyncStream，再串行调用引擎 Actor，避免 UI 状态与采样配置发生数据竞争。
    init(settings: MonitoringSettings? = nil, engine: MonitoringEngine? = nil) {
        let settings = settings ?? MonitoringSettings()
        self.settings = settings
        selection = settings.selection
        self.engine = engine ?? MonitoringEngine(configuration: settings.configuration)
        let engine = self.engine
        let initialConfiguration = settings.configuration
        // 首次采样前先应用持久化配置；后续 Combine 配置变化按先进先出顺序交给引擎。
        // Task 作为初始化屏障：即使注入的引擎已有不同配置，首轮采样也必须等待持久化设置落地。
        configurationReady = Task { await engine.updateConfiguration(initialConfiguration) }
        let configurations = AsyncStream<MonitoringConfiguration> { continuation in
            settingsSubscription = settings.$refreshInterval
                .combineLatest(settings.$historyDuration, settings.$selection)
                .sink { [weak self] refresh, history, selection in
                    if let self, self.selection != selection {
                        // 在显示新启用卡片前清空旧快照，避免快速开关时闪现切换前数据。
                        self.snapshot = nil
                        self.history.clearDisabled(selection)
                        self.selection = selection
                    }
                    continuation.yield(.init(refreshInterval: refresh, historyDuration: history,
                                             selection: selection))
                }
        }
        let ready = configurationReady
        configurationConsumption = Task {
            await ready.value
            for await configuration in configurations {
                guard !Task.isCancelled else { break }
                // 配置流按顺序调用引擎，防止快速切换设置时新旧配置交错。
                await engine.updateConfiguration(configuration)
            }
        }
        start()
    }

    deinit {
        consumption?.cancel()
        configurationConsumption?.cancel()
    }

    /// 开始消费监控更新；存储初始化后自动调用，停止后也可再次启动。
    /// 使用单一消费 Task 保证更新按流顺序落到 Published 属性；guard 使重复 start 保持幂等。
    func start() {
        guard consumption == nil else { return }
        let engine = engine
        let ready = configurationReady
        consumption = Task { [weak self] in
            // 先等待初始设置生效，再订阅和启动采样，避免首帧采集未选择板块。
            await ready.value
            guard !Task.isCancelled else { return }
            let stream = await engine.updates()
            guard !Task.isCancelled else { return }
            await engine.start()
            for await update in stream {
                guard !Task.isCancelled else { break }
                // 设置切换后旧缓冲更新仍可能到达，必须同时核对选择和历史版本。
                let appliedSelection = await engine.configuration.selection
                let currentRevision = await engine.history.durationRevision
                guard self?.selection == appliedSelection,
                      update.history.durationRevision == currentRevision else { continue }
                self?.snapshot = update.snapshot
                self?.history = update.history
            }
        }
    }

    /// 停止界面侧更新消费；应用或测试不再需要观察数据时调用，不销毁设置。
    /// 取消消费 Task 会触发 AsyncStream termination，最后一个订阅离开后引擎自行停止采样。
    func stop() {
        consumption?.cancel()
        consumption = nil
    }
}

import Combine
import Foundation

@MainActor
final class MonitoringStore: ObservableObject {
    @Published private(set) var snapshot: MetricSnapshot?
    @Published private(set) var history = MetricHistory()

    let settings: MonitoringSettings

    private let engine: MonitoringEngine
    private var consumption: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var configurationConsumption: Task<Void, Never>?

    init(settings: MonitoringSettings? = nil, engine: MonitoringEngine? = nil) {
        let settings = settings ?? MonitoringSettings()
        self.settings = settings
        self.engine = engine ?? MonitoringEngine(configuration: settings.configuration)
        let configurations = AsyncStream<MonitoringConfiguration> { continuation in
            settingsSubscription = settings.$refreshInterval
                .combineLatest(settings.$historyDuration)
                .sink { refresh, history in
                    continuation.yield(.init(refreshInterval: refresh, historyDuration: history))
                }
        }
        let engine = self.engine
        configurationConsumption = Task {
            // Include the initial published configuration and forward every change in order.
            // A single consumer prevents task priority from letting old values arrive last.
            for await configuration in configurations {
                guard !Task.isCancelled else { break }
                await engine.updateConfiguration(configuration)
            }
        }
        start()
    }

    deinit {
        consumption?.cancel()
        configurationConsumption?.cancel()
    }

    func start() {
        guard consumption == nil else { return }
        let engine = engine
        consumption = Task { [weak self] in
            let stream = await engine.updates()
            guard !Task.isCancelled else { return }
            await engine.start()
            for await update in stream {
                guard !Task.isCancelled else { break }
                self?.snapshot = update.snapshot
                self?.history = update.history
            }
        }
    }

    func stop() {
        consumption?.cancel()
        consumption = nil
    }
}

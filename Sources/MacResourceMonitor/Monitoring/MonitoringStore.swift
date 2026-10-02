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

    init(settings: MonitoringSettings? = nil, engine: MonitoringEngine? = nil) {
        let settings = settings ?? MonitoringSettings()
        self.settings = settings
        self.engine = engine ?? MonitoringEngine(configuration: settings.configuration)
        settingsSubscription = settings.$refreshInterval
            .combineLatest(settings.$historyDuration)
            .dropFirst()
            .sink { [weak self] refresh, history in
                guard let self else { return }
                let engine = self.engine
                Task {
                    await engine.updateConfiguration(.init(refreshInterval: refresh, historyDuration: history))
                }
            }
        start()
    }

    deinit { consumption?.cancel() }

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

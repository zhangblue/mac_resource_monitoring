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

    init(settings: MonitoringSettings? = nil, engine: MonitoringEngine? = nil) {
        let settings = settings ?? MonitoringSettings()
        self.settings = settings
        selection = settings.selection
        self.engine = engine ?? MonitoringEngine(configuration: settings.configuration)
        let engine = self.engine
        let initialConfiguration = settings.configuration
        // Even an injected engine must apply the restored selection before its
        // first collection. Subsequent Combine events are consumed in FIFO order.
        configurationReady = Task { await engine.updateConfiguration(initialConfiguration) }
        let configurations = AsyncStream<MonitoringConfiguration> { continuation in
            settingsSubscription = settings.$refreshInterval
                .combineLatest(settings.$historyDuration, settings.$selection)
                .sink { [weak self] refresh, history, selection in
                    if let self, self.selection != selection {
                        // Clear before exposing the newly enabled card, so a
                        // rapid off/on cannot flash the pre-switch reading.
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
        let ready = configurationReady
        consumption = Task { [weak self] in
            await ready.value
            guard !Task.isCancelled else { return }
            let stream = await engine.updates()
            guard !Task.isCancelled else { return }
            await engine.start()
            for await update in stream {
                guard !Task.isCancelled else { break }
                // A previously buffered update can arrive after a settings switch.
                // Match both the applied selection and Engine's history revision.
                let appliedSelection = await engine.configuration.selection
                let currentRevision = await engine.history.durationRevision
                guard self?.selection == appliedSelection,
                      update.history.durationRevision == currentRevision else { continue }
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

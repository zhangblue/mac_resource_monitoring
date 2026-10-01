import Combine
import Foundation

@MainActor
final class MonitoringStore: ObservableObject {
    @Published private(set) var snapshot: MetricSnapshot?
    @Published private(set) var history = MetricHistory()

    private let engine: MonitoringEngine
    private var consumption: Task<Void, Never>?

    init(engine: MonitoringEngine = MonitoringEngine()) {
        self.engine = engine
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

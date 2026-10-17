import AppKit
import Foundation

// Notification callbacks run synchronously on their posting thread. A lock
// makes a sleep/wake boundary visible before any later sampling task can run,
// without an asynchronous hop that could race the first post-wake sample.
final class SystemSleepMonitor: @unchecked Sendable {
    struct State: Equatable, Sendable {
        let generation: UUID
        let isSleeping: Bool
    }

    private let lock = NSLock()
    private var state = State(generation: UUID(), isSleeping: false)
    private var sleepHandler: (@Sendable () async -> Void)?
    private var sleepCleanup: Task<Void, Never>?
    private var samplingCancellations: [UUID: @Sendable () -> Void] = [:]
    private let center: NotificationCenter
    // Tokens change only during initialization/deinitialization; state is locked.
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.transition(isSleeping: true)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.transition(isSleeping: false)
            }
        ]
    }

    deinit { observers.forEach(center.removeObserver) }

    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func setSleepHandler(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sleepHandler = handler
    }

    func waitForSleepCleanup() async {
        await pendingSleepCleanup()?.value
    }

    func registerSampling(_ id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let isSleeping = state.isSleeping
        if !isSleeping { samplingCancellations[id] = cancel }
        lock.unlock()
        if isSleeping { cancel() }
    }

    func unregisterSampling(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        samplingCancellations.removeValue(forKey: id)
    }

    private func pendingSleepCleanup() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return sleepCleanup
    }

    private func transition(isSleeping: Bool) {
        lock.lock()
        state = State(generation: UUID(), isSleeping: isSleeping)
        let cancellations = isSleeping ? Array(samplingCancellations.values) : []
        if isSleeping, let sleepHandler {
            let predecessor = sleepCleanup
            // Publish the cleanup barrier synchronously with the generation.
            // Wake and queued samples cannot overtake cancellation/child reaping.
            sleepCleanup = Task {
                await predecessor?.value
                await sleepHandler()
            }
        }
        lock.unlock()
        // Cancel synchronously so child work that is still starting inherits
        // cancellation too. Never invoke cancellation handlers under the lock.
        cancellations.forEach { $0() }
    }
}

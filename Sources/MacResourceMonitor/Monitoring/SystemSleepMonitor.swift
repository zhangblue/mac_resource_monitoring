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

    private func transition(isSleeping: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state = State(generation: UUID(), isSleeping: isSleeping)
    }
}

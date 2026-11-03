import AppKit
import Foundation

// 睡眠通知会在发送线程同步回调；锁可让后续采样立即看见边界，避免异步切换与唤醒首轮采样竞争。
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
    // 观察令牌只在初始化和销毁时变化，其他共享状态均由锁保护。
    private var observers: [NSObjectProtocol] = []

    /// 注册系统睡眠和唤醒通知；监控引擎创建电源状态观察器时调用。
    /// NotificationCenter 回调可能来自任意线程，因此不用 Actor 跳转，而由 NSLock 同步更新代次和睡眠标记。
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        observers = [
            // 系统通知到达时同步推进代次，使正在运行和排队的采样都能识别边界。
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.transition(isSleeping: true)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.transition(isSleeping: false)
            }
        ]
    }

    deinit { observers.forEach(center.removeObserver) }

    /// 返回锁保护的电源状态快照；采样开始和提交前调用以检测跨睡眠结果。
    /// generation 每次睡眠/唤醒都更换，调用方可用值相等比较拒绝跨边界的迟到结果。
    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// 设置睡眠清理回调；引擎初始化时注册进程采集取消逻辑。
    func setSleepHandler(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sleepHandler = handler
    }

    /// 等待最近一次睡眠清理完成；开始采集和提交结果前调用，防止越过清理屏障。
    func waitForSleepCleanup() async {
        await pendingSleepCleanup()?.value
    }

    /// 注册当前采样的同步取消闭包；每个采样任务启动后调用，若已睡眠则立即取消。
    /// 闭包只在锁内保存、在锁外执行，避免取消逻辑重入本对象造成死锁。
    func registerSampling(_ id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let isSleeping = state.isSleeping
        if !isSleeping { samplingCancellations[id] = cancel }
        lock.unlock()
        if isSleeping { cancel() }
    }

    /// 移除已结束采样的取消闭包；采样任务完成或取消后调用。
    func unregisterSampling(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        samplingCancellations.removeValue(forKey: id)
    }

    /// 读取当前睡眠清理任务；等待清理屏障时内部调用。
    private func pendingSleepCleanup() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return sleepCleanup
    }

    /// 同步处理睡眠状态变化；工作区通知回调时调用，并在睡眠时取消所有活跃采样。
    /// sleepCleanup 形成串行 Task 屏障，确保上一次外部进程回收完成后才允许唤醒采样继续。
    private func transition(isSleeping: Bool) {
        lock.lock()
        state = State(generation: UUID(), isSleeping: isSleeping)
        let cancellations = isSleeping ? Array(samplingCancellations.values) : []
        if isSleeping, let sleepHandler {
            let predecessor = sleepCleanup
            // 清理屏障与新代次同步发布，唤醒和排队采样不能越过取消及子进程回收。
            sleepCleanup = Task {
                await predecessor?.value
                await sleepHandler()
            }
        }
        lock.unlock()
        // 在锁外同步触发取消，让仍在启动的子任务继承取消状态，同时避免回调重入锁。
        cancellations.forEach { $0() }
    }
}

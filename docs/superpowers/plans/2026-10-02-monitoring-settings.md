# 监控刷新与历史保留设置实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为菜单栏监控应用增加可持久化的刷新时间（1/3/5 秒）和历史保留时间（1/5/10 分钟）设置，并让采样、历史裁剪、折线图和文案在修改后立即同步。

**架构：** 新增一个由 `UserDefaults` 支撑的 `MonitoringSettings`，由 `MonitoringStore` 统一持有并把强类型配置传给 `MonitoringEngine`。引擎保留同一个采样循环和订阅流，通过取消独立等待任务即时采用新刷新间隔；`MetricHistory` 使用时间戳窗口和 600 点硬上限裁剪。SwiftUI 设置页、详情卡片和折线图读取同一设置实例，确保运行行为与显示一致。

**技术栈：** Swift 5.9、SwiftUI、Combine、Swift Charts、Foundation `UserDefaults`、Swift Concurrency、XCTest、Swift Package Manager。

---

## 文件结构

- 新建 `Sources/MacResourceMonitor/Settings/MonitoringSettings.swift`：强类型选项、显示文字、持久化和默认回退。
- 新建 `Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift`：默认值、所有选项、持久化和损坏值测试。
- 修改 `Sources/MacResourceMonitor/Domain/RingBuffer.swift`：增加保序替换能力，供时间窗裁剪复用。
- 修改 `Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`：动态历史、动态采样等待和配置热更新。
- 修改 `Sources/MacResourceMonitor/Monitoring/MonitoringStore.swift`：持有设置、观察变化并传给引擎。
- 修改 `Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift`：把 Store 内的同一设置实例传入详情页。
- 修改 `Sources/MacResourceMonitor/UI/SettingsView.swift`：增加两个分段选择器和动态摘要。
- 修改 `Sources/MacResourceMonitor/UI/DashboardView.swift`：向卡片传递当前时间窗并使用动态状态文案。
- 修改 `Sources/MacResourceMonitor/UI/MetricCardView.swift`：向折线图传递历史时长和预期采样间隔。
- 修改 `Sources/MacResourceMonitor/UI/SparklineView.swift`：动态 X 轴和辅助功能标签。
- 修改 `Sources/MacResourceMonitor/UI/MenuBarPresentation.swift`：动态可见窗口、动态断线阈值和时间文案。
- 修改 `Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`：时间窗裁剪、600 点上限和热更新测试。
- 修改 `Tests/MacResourceMonitorTests/UITests.swift`、`Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift`：动态图表窗口、文案和 1/3/5 秒采样断线语义。
- 修改 `README.md`、`docs/superpowers/specs/2026-10-01-mac-resource-monitor-design.md`、`docs/verification/2026-10-01-release-checklist.md`：同步可配置行为与验收步骤。

## 任务 1：建立强类型设置和持久化

**文件：**

- 新建：`Sources/MacResourceMonitor/Settings/MonitoringSettings.swift`
- 新建：`Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift`

- [ ] **步骤 1：先写默认值、允许值和持久化失败测试**

在新测试文件中使用独立 suite，避免污染真实应用设置：

```swift
import Foundation
import XCTest
@testable import MacResourceMonitor

@MainActor
final class MonitoringSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MonitoringSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsAreOneSecondAndFiveMinutes() {
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
        XCTAssertEqual(settings.summary, "每 1 秒刷新 · 保留最近 5 分钟")
    }

    func testEverySupportedValueRoundTrips() {
        for refresh in RefreshInterval.allCases {
            for history in HistoryDuration.allCases {
                let settings = MonitoringSettings(defaults: defaults)
                settings.refreshInterval = refresh
                settings.historyDuration = history
                let restored = MonitoringSettings(defaults: defaults)
                XCTAssertEqual(restored.refreshInterval, refresh)
                XCTAssertEqual(restored.historyDuration, history)
            }
        }
    }

    func testUnsupportedStoredValuesFallBackToDefaults() {
        defaults.set(2, forKey: MonitoringSettings.refreshIntervalKey)
        defaults.set(-60, forKey: MonitoringSettings.historyDurationKey)
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .oneSecond)
        XCTAssertEqual(settings.historyDuration, .fiveMinutes)
    }
}
```

- [ ] **步骤 2：运行单项测试，确认因类型缺失而失败**

运行：`swift test --filter MonitoringSettingsTests`

预期：编译失败，提示找不到 `MonitoringSettings`、`RefreshInterval` 和 `HistoryDuration`。

- [ ] **步骤 3：实现设置类型和 `UserDefaults` 持久化**

新文件应包含以下公开到模块内部的核心接口：

```swift
import Combine
import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5

    var id: Int { rawValue }
    var label: String { "\(rawValue) 秒" }
}

enum HistoryDuration: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var label: String { "\(rawValue / 60) 分钟" }
    var recentLabel: String { "最近 \(rawValue / 60) 分钟" }
}

struct MonitoringConfiguration: Equatable, Sendable {
    var refreshInterval: RefreshInterval
    var historyDuration: HistoryDuration
}

@MainActor
final class MonitoringSettings: ObservableObject {
    static let refreshIntervalKey = "monitoring.refreshIntervalSeconds"
    static let historyDurationKey = "monitoring.historyDurationSeconds"

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Self.refreshIntervalKey) }
    }
    @Published var historyDuration: HistoryDuration {
        didSet { defaults.set(historyDuration.rawValue, forKey: Self.historyDurationKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Self.refreshIntervalKey)) ?? .oneSecond
        historyDuration = HistoryDuration(rawValue: defaults.integer(forKey: Self.historyDurationKey)) ?? .fiveMinutes
    }

    var configuration: MonitoringConfiguration {
        MonitoringConfiguration(refreshInterval: refreshInterval, historyDuration: historyDuration)
    }

    var summary: String { "每 \(refreshInterval.label)刷新 · 保留\(historyDuration.recentLabel)" }
}
```

`UserDefaults.integer(forKey:)` 在键不存在时返回 0，因此同一套枚举初始化同时覆盖“未保存”和“不受支持的整数”两种默认回退。

- [ ] **步骤 4：运行测试并提交**

运行：`swift test --filter MonitoringSettingsTests`

预期：3 个测试全部通过。

```bash
git add Sources/MacResourceMonitor/Settings/MonitoringSettings.swift Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift
git commit -m "feat: 添加监控设置持久化"
```

## 任务 2：把历史改为时间窗口裁剪

**文件：**

- 修改：`Sources/MacResourceMonitor/Domain/RingBuffer.swift`
- 修改：`Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`
- 修改：`Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`

- [ ] **步骤 1：用 `MetricHistory` 直接测试窗口边界、缩短、延长和硬上限**

把旧的“固定 300 点”测试替换为不依赖真实采集器的测试：

```swift
func testHistoryUsesInclusiveTimeWindowAndRemovesFuturePointsAfterRollback() {
    var history = MetricHistory(historyDuration: .oneMinute)
    history.append(.fixture(at: 939))
    history.append(.fixture(at: 940))
    history.append(.fixture(at: 1_000))
    history.append(.fixture(at: 999))
    XCTAssertEqual(history.cpu.elements.map { $0.timestamp.timeIntervalSince1970 }, [940, 999])
}

func testShorteningTrimsImmediatelyAndExtendingDoesNotInventPoints() {
    var history = MetricHistory(historyDuration: .tenMinutes)
    for second in stride(from: 0, through: 600, by: 60) {
        history.append(.fixture(at: TimeInterval(second)))
    }
    history.updateDuration(.oneMinute, endingAt: Date(timeIntervalSince1970: 600))
    XCTAssertEqual(history.cpu.elements.count, 2)
    history.updateDuration(.tenMinutes, endingAt: Date(timeIntervalSince1970: 600))
    XCTAssertEqual(history.cpu.elements.count, 2)
}

func testHistoryNeverExceedsSixHundredPoints() {
    var history = MetricHistory(historyDuration: .tenMinutes)
    for second in 0...700 { history.append(.fixture(at: TimeInterval(second))) }
    XCTAssertEqual(history.cpu.count, 600)
    XCTAssertEqual(history.cpu.elements.first?.timestamp.timeIntervalSince1970, 101)
}
```

在测试文件内增加 `MetricSnapshot.fixture(at:)`，给五个读数填入固定合法值，避免测试重复拼装快照。

- [ ] **步骤 2：运行测试，确认固定容量实现失败**

运行：`swift test --filter MonitoringEngineTests`

预期：编译或断言失败，因为 `MetricHistory` 尚不支持动态时间窗。

- [ ] **步骤 3：为环形缓冲区增加保序替换**

在 `RingBuffer` 中加入：

```swift
mutating func replaceContents<S: Sequence>(with elements: S) where S.Element == Element {
    storage = Array(repeating: nil, count: capacity)
    writeIndex = 0
    count = 0
    for element in elements { append(element) }
}
```

- [ ] **步骤 4：实现 `MetricHistory` 的动态裁剪**

将固定 300 容量改为固定内存上限 600，并让四条序列共享同一个窗口终点：

```swift
struct MetricHistory: Sendable {
    private static let maximumPointCount = 600
    private(set) var historyDuration: HistoryDuration
    var cpu = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var memory = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var upload = RingBuffer<HistoryPoint>(capacity: maximumPointCount)
    var download = RingBuffer<HistoryPoint>(capacity: maximumPointCount)

    init(historyDuration: HistoryDuration = .fiveMinutes) {
        self.historyDuration = historyDuration
    }

    mutating func append(_ snapshot: MetricSnapshot) {
        let date = snapshot.timestamp
        cpu.append(.init(timestamp: date, value: snapshot.cpuUsage.value))
        memory.append(.init(timestamp: date, value: snapshot.memory.value?.usage))
        upload.append(.init(timestamp: date, value: snapshot.network.value?.uploadBytesPerSecond))
        download.append(.init(timestamp: date, value: snapshot.network.value?.downloadBytesPerSecond))
        trim(endingAt: date)
    }

    mutating func updateDuration(_ duration: HistoryDuration, endingAt end: Date?) {
        historyDuration = duration
        if let end { trim(endingAt: end) }
    }
}
```

`trim(endingAt:)` 对每个缓冲区只保留 `timestamp >= end - duration` 且 `timestamp <= end` 的点，再调用 `replaceContents`；下界必须包含，未来点必须排除。

- [ ] **步骤 5：运行历史测试并提交**

运行：`swift test --filter MonitoringEngineTests`

预期：新历史测试和原有采集失败隔离、睡眠边界测试全部通过；删除旧的 `historyCapacity` 初始化参数和相关固定 300 断言。

```bash
git add Sources/MacResourceMonitor/Domain/RingBuffer.swift Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift Tests/MacResourceMonitorTests/MonitoringEngineTests.swift
git commit -m "feat: 按时间窗口保留监控历史"
```

## 任务 3：让采样引擎即时采用新配置

**文件：**

- 修改：`Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`
- 修改：`Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`

- [ ] **步骤 1：先写热更新行为测试**

新增两个异步测试：

```swift
func testConfigurationUpdateTrimsAndPublishesWithoutRebuildingStream() async throws {
    let engine = makeEngine(providers: providers(), configuration: .init(
        refreshInterval: .fiveSeconds, historyDuration: .tenMinutes
    ))
    _ = await engine.sample(at: Date(timeIntervalSince1970: 0))
    _ = await engine.sample(at: Date(timeIntervalSince1970: 600))
    let stream = await engine.updates()
    var iterator = stream.makeAsyncIterator()
    await engine.updateConfiguration(.init(refreshInterval: .fiveSeconds, historyDuration: .oneMinute))
    let update = await iterator.next()
    XCTAssertEqual(update?.history.cpu.count, 1)
    XCTAssertEqual(update?.snapshot.timestamp, Date(timeIntervalSince1970: 600))
    await engine.stop()
}

func testShorterRefreshIntervalCancelsOldWaitAndKeepsHistory() async throws {
    let engine = makeEngine(providers: providers(), configuration: .init(
        refreshInterval: .fiveSeconds, historyDuration: .fiveMinutes
    ))
    let stream = await engine.updates()
    var iterator = stream.makeAsyncIterator()
    await engine.start()
    let firstValue = await iterator.next()
    let first = try XCTUnwrap(firstValue)
    let start = ContinuousClock.now
    await engine.updateConfiguration(.init(refreshInterval: .oneSecond, historyDuration: .fiveMinutes))
    let secondValue = await iterator.next()
    let second = try XCTUnwrap(secondValue)
    XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    XCTAssertEqual(second.history.cpu.count, first.history.cpu.count + 1)
    await engine.stop()
}
```

为避免永久挂起，实际测试用现有 `waitUntil` 或带 2 秒截止的任务组包装 `iterator.next()`。

- [ ] **步骤 2：运行测试并确认缺少热更新 API**

运行：`swift test --filter MonitoringEngineTests`

预期：编译失败，提示缺少配置初始化参数或 `updateConfiguration`。

- [ ] **步骤 3：给引擎增加配置、最新快照和独立等待任务**

在 actor 中增加：

```swift
private(set) var configuration: MonitoringConfiguration
private var latestSnapshot: MetricSnapshot?
private var intervalWait: Task<Void, Never>?
private var intervalWaitID: UUID?
```

初始化 `history = MetricHistory(historyDuration: configuration.historyDuration)`。每次成功 `commit` 后设置 `latestSnapshot = snapshot`。

采样循环每轮先记录 `cycleStart`，采样完成后再读取最新刷新间隔，并创建独立的可取消等待任务。等待任务取消只唤醒循环，不能取消主循环：

```swift
private func waitForNextCycle(startedAt start: ContinuousClock.Instant) async {
    let deadline = start.advanced(by: .seconds(configuration.refreshInterval.rawValue))
    let id = UUID()
    let clock = ContinuousClock()
    let wait = Task { try? await clock.sleep(until: deadline) }
    intervalWaitID = id
    intervalWait = wait
    await wait.value
    if intervalWaitID == id {
        intervalWait = nil
        intervalWaitID = nil
    }
}
```

`start()` 的循环保持“采集耗时计入周期”语义：记录开始时间、调用 `sampleAndPublish`、检查取消、调用 `waitForNextCycle`。

- [ ] **步骤 4：实现配置热更新和停止清理**

```swift
func updateConfiguration(_ newValue: MonitoringConfiguration) {
    let intervalChanged = configuration.refreshInterval != newValue.refreshInterval
    let historyChanged = configuration.historyDuration != newValue.historyDuration
    configuration = newValue

    if historyChanged {
        history.updateDuration(newValue.historyDuration, endingAt: latestSnapshot?.timestamp)
        if let latestSnapshot {
            let update = MonitoringUpdate(snapshot: latestSnapshot, history: history)
            subscribers.values.forEach { $0.yield(update) }
        }
    }
    if intervalChanged { intervalWait?.cancel() }
}
```

`stop()` 和 `deinit` 同时取消并清空 `intervalWait`；配置更新不能更换 generation、结束订阅或重置 CPU/网络基线。

- [ ] **步骤 5：运行引擎和睡眠测试并提交**

运行：

```bash
swift test --filter MonitoringEngineTests
swift test --filter SamplingBoundaryTests
```

预期：配置变更、生命周期、睡眠唤醒和并发采样测试全部通过。

```bash
git add Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift Tests/MacResourceMonitorTests/MonitoringEngineTests.swift
git commit -m "feat: 支持实时调整采样配置"
```

## 任务 4：连接 Store、设置页和共享状态

**文件：**

- 修改：`Sources/MacResourceMonitor/Monitoring/MonitoringStore.swift`
- 修改：`Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift`
- 修改：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 修改：`Sources/MacResourceMonitor/UI/SettingsView.swift`
- 修改：`Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift`

- [ ] **步骤 1：写 Store 转发设置变化测试**

在 `MonitoringSettingsTests` 新增：创建独立 defaults、`MonitoringSettings` 和以该初始配置创建的引擎，再构造 Store；修改两个设置后轮询 `await engine.configuration`，断言最终为 3 秒和 10 分钟。测试结束调用 `store.stop()` 和 `await engine.stop()`。

- [ ] **步骤 2：运行测试并确认 Store 尚未观察设置**

运行：`swift test --filter MonitoringSettingsTests`

预期：编译或断言失败。

- [ ] **步骤 3：让 Store 拥有设置并转发组合变化**

`MonitoringStore` 新增：

```swift
let settings: MonitoringSettings
private var settingsSubscription: AnyCancellable?

init(settings: MonitoringSettings = MonitoringSettings(), engine: MonitoringEngine? = nil) {
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
```

由于 `MonitoringStore` 已是 `@MainActor`，设置修改和发布保持在主执行上下文；引擎配置通过 actor 调用串行处理。

- [ ] **步骤 4：在设置页增加分段选择器**

让 `SettingsView` 接收 `@ObservedObject var settings: MonitoringSettings`，在登录启动区域下方增加：

```swift
VStack(alignment: .leading, spacing: 12) {
    Text("监控").font(.subheadline.weight(.semibold))
    Picker("刷新时间", selection: $settings.refreshInterval) {
        ForEach(RefreshInterval.allCases) { option in
            Text(option.label).tag(option)
        }
    }
    .pickerStyle(.segmented)

    Picker("保留最近时间", selection: $settings.historyDuration) {
        ForEach(HistoryDuration.allCases) { option in
            Text(option.label).tag(option)
        }
    }
    .pickerStyle(.segmented)
}
```

把固定摘要替换为 `Text(settings.summary)`。`DashboardView` 使用 `store.settings` 创建 `SettingsView`；`MacResourceMonitorApp` 继续只持有一个 `MonitoringStore`，因此设置页、Store 和引擎不会创建不同设置实例。

- [ ] **步骤 5：运行设置测试、构建并提交**

运行：

```bash
swift test --filter MonitoringSettingsTests
swift build
```

预期：测试通过，设置页在 macOS 13 API 下编译成功。

```bash
git add Sources/MacResourceMonitor/Monitoring/MonitoringStore.swift Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift Sources/MacResourceMonitor/UI/DashboardView.swift Sources/MacResourceMonitor/UI/SettingsView.swift Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift
git commit -m "feat: 添加监控设置界面"
```

## 任务 5：让折线图窗口、断线和文案动态化

**文件：**

- 修改：`Sources/MacResourceMonitor/UI/MenuBarPresentation.swift`
- 修改：`Sources/MacResourceMonitor/UI/SparklineView.swift`
- 修改：`Sources/MacResourceMonitor/UI/MetricCardView.swift`
- 修改：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 修改：`Tests/MacResourceMonitorTests/UITests.swift`
- 修改：`Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift`

- [ ] **步骤 1：先写动态窗口和文案测试**

把固定五分钟测试改为显式传参，并新增：

```swift
func testSparklineUsesSelectedOneMinuteWindow() {
    let start = Date(timeIntervalSince1970: 0)
    let presentation = SparklinePresentation(points: [
        .init(timestamp: start, value: 0.9),
        .init(timestamp: start.addingTimeInterval(60), value: 0.2),
        .init(timestamp: start.addingTimeInterval(61), value: 0.3)
    ], historyDuration: .oneMinute, refreshInterval: .oneSecond)
    XCTAssertEqual(presentation.visibleValues, [0.2, 0.3])
}

func testPresentationUsesSelectedDurationLabel() {
    XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2), historyDuration: .oneMinute), "最近 1 分钟")
    XCTAssertEqual(MetricPresentation.status(for: Reading<Double>.value(0.2), historyDuration: .tenMinutes), "最近 10 分钟")
}
```

在边界测试中分别验证正常的 `[0, 3, 6]`（3 秒设置）和 `[0, 5, 10]`（5 秒设置）各形成一段，而 120 秒睡眠仍断开。

- [ ] **步骤 2：运行 UI 和边界测试，确认固定 300 秒/3 秒规则失败**

运行：

```bash
swift test --filter UITests
swift test --filter SamplingBoundaryTests
```

预期：编译失败或动态窗口断言失败。

- [ ] **步骤 3：参数化展示模型**

`SparklinePresentation` 初始化改为：

```swift
init(points: [HistoryPoint], historyDuration: HistoryDuration, refreshInterval: RefreshInterval) {
    let end = points.last?.timestamp ?? .distantPast
    let cutoff = end.addingTimeInterval(-TimeInterval(historyDuration.rawValue))
    let discontinuityThreshold = TimeInterval(refreshInterval.rawValue * 3)
    // 仅遍历 cutoff...end；缺失/非有限值断线；间隔 <= 0 或 > threshold 断线。
}
```

三倍预期间隔延续现有 1 秒采样容许最多 3 秒抖动的语义，同时避免 3 秒、5 秒正常采样被误判为断线；120 秒睡眠仍会断开。

`MetricPresentation.status` 增加 `historyDuration` 参数，成功读数返回 `historyDuration.recentLabel`，等待与失败分支保持不变。

- [ ] **步骤 4：把两个设置传到图表和辅助功能**

`MetricCardView` 的趋势初始化器增加 `historyDuration` 和 `refreshInterval`；`SparklineView` 用它们创建展示模型，并使用：

```swift
.chartXScale(domain: end.addingTimeInterval(-TimeInterval(historyDuration.rawValue))...end)
.accessibilityLabel("\(style.name)\(historyDuration.recentLabel)趋势，纵轴范围 \(axis.labels[0]) 至 \(axis.labels[2])")
```

`DashboardView` 从 `store.settings` 读取两项设置，传给四张趋势卡；CPU、内存、网络成功状态全部使用动态 `recentLabel`。温度、风扇、磁盘容量和菜单栏四项摘要保持不变。

- [ ] **步骤 5：运行 UI、边界和纵轴测试并提交**

运行：

```bash
swift test --filter UITests
swift test --filter SamplingBoundaryTests
swift test --filter SparklineAxisPresentationTests
```

预期：动态 1/5/10 分钟窗口、1/3/5 秒断线、时间回拨、缺失点和动态纵轴测试全部通过。

```bash
git add Sources/MacResourceMonitor/UI/MenuBarPresentation.swift Sources/MacResourceMonitor/UI/SparklineView.swift Sources/MacResourceMonitor/UI/MetricCardView.swift Sources/MacResourceMonitor/UI/DashboardView.swift Tests/MacResourceMonitorTests/UITests.swift Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift
git commit -m "feat: 同步动态趋势窗口与文案"
```

## 任务 6：同步文档并完成发布级验证

**文件：**

- 修改：`README.md`
- 修改：`docs/superpowers/specs/2026-10-01-mac-resource-monitor-design.md`
- 修改：`docs/verification/2026-10-01-release-checklist.md`

- [ ] **步骤 1：更新用户和设计文档**

README 的“当前功能”写明：默认每 1 秒刷新、默认保留最近 5 分钟，可在设置中选择 1/3/5 秒和 1/5/10 分钟。原设计说明把固定 300 点改成“按所选时间窗口裁剪，单项最多 600 点”。发布清单增加修改设置即时生效、重启保留、缩短立即裁剪、延长不补造历史的真机检查。

保持以下声明不变：Apple Silicon、macOS 13+、纯菜单栏、磁盘 capacity-only、ad-hoc 签名且未经公证。

- [ ] **步骤 2：检查过时文字和磁盘速率禁区**

运行：

```bash
rg -n "每秒采样|固定.*300|最近五分钟|磁盘读写|disk.*rate" README.md INSTALL.md Sources Tests docs/verification docs/superpowers/specs
```

预期：产品现状文档和运行代码中不再有固定刷新/固定五分钟文案；历史计划文档可保留当时记录；不存在新增磁盘读写速率实现。

- [ ] **步骤 3：执行全部代码验证**

运行：

```bash
swift test
swift build -c release --arch arm64
```

预期：全部测试通过，arm64 Release 构建成功。

- [ ] **步骤 4：重建并验证应用包和 DMG**

运行：

```bash
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
```

预期：`dist/MacResourceMonitor.app` 和 `dist/MacResourceMonitor.dmg` 生成成功；验证脚本确认 arm64、macOS 13、`LSUIElement`、应用图标和 ad-hoc 签名均符合要求。

- [ ] **步骤 5：检查差异并提交文档**

运行：

```bash
git diff --check
git status --short
```

预期：无空白错误，`build/` 和 `dist/` 不在待提交列表。

```bash
git add README.md docs/superpowers/specs/2026-10-01-mac-resource-monitor-design.md docs/verification/2026-10-01-release-checklist.md
git commit -m "docs: 更新监控设置与发布验证说明"
```

## 任务 7：最终验收

- [ ] **步骤 1：按六种单项选择逐一检查界面**

运行 `swift run MacResourceMonitor`，在设置页依次选择 1/3/5 秒与 1/5/10 分钟，确认分段选择器没有裁切，摘要、详情卡文案与折线图窗口立即变化。

- [ ] **步骤 2：验证持久化与历史变化语义**

选择 3 秒和 10 分钟后退出再启动，确认选择保留；从 10 分钟改为 1 分钟时旧点立即消失，从 1 分钟改回 10 分钟时已有点保留并逐步累积，不出现伪造历史。

- [ ] **步骤 3：验证产品边界**

确认菜单栏仍只显示 CPU、内存、上传和下载；Dock 不出现常驻图标；温度、风扇和系统启动卷容量仍可用；没有磁盘读写速率。

- [ ] **步骤 4：执行最终状态检查**

运行：

```bash
git log --oneline -7
git status -sb
```

预期：功能提交齐全，工作区干净，分支基于已确认的设计提交。

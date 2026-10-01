# macOS 本机资源监控工具实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 构建一款适用于 Apple Silicon、常驻 macOS 菜单栏、展示实时资源指标和 5 分钟趋势，并可通过 DMG 安装的原生应用。

**架构：** 以 Swift Package 作为源码和测试入口（Xcode 可直接打开 `Package.swift`），使用 SwiftUI `MenuBarExtra` 和 Swift Charts 构建界面。采集器通过小型协议隔离，`MonitoringEngine` 每秒并发采样并产生统一快照；SMC 访问再通过传输协议隔离，以便在无真实硬件的测试中验证解析和降级逻辑。

**技术栈：** Swift 6.1 工具链（Swift 5.9 语言模式）、SwiftUI、Charts、Darwin/Mach、IOKit、ServiceManagement、XCTest、shell、`codesign`、`hdiutil`

---

## 环境事实与约束

- 当前主机是 `arm64`，Swift 版本为 6.1.2，Command Line Tools 提供 macOS SDK。
- 当前活动开发目录不是完整 Xcode，因此计划中的日常验证使用 `swift test` 和 `swift build`；可视化调试时可在安装完整 Xcode 后直接打开 `Package.swift`。
- 最低系统版本固定为 macOS 13，因此可以使用 `MenuBarExtra`、Swift Charts 和 `SMAppService.mainApp`。
- 应用不依赖第三方运行库，不执行网络请求。
- DMG 使用 ad-hoc 签名；未取得 Developer ID 前无法进行 Apple 公证。

## 文件结构

```text
Package.swift                                      SwiftPM 工程、框架链接和测试目标
Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift
                                                    菜单栏场景与应用生命周期
Sources/MacResourceMonitor/Domain/MetricSnapshot.swift
                                                    当前值、状态和历史点模型
Sources/MacResourceMonitor/Domain/RingBuffer.swift  固定容量历史缓冲
Sources/MacResourceMonitor/Formatting/MetricFormatter.swift
                                                    百分比、字节、速率和温度格式
Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift
                                                    所有可替换采集器协议
Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift
                                                    定时采样、合并、基线重置
Sources/MacResourceMonitor/Monitoring/MonitoringStore.swift
                                                    MainActor 可观察状态
Sources/MacResourceMonitor/Providers/CPUProvider.swift
Sources/MacResourceMonitor/Providers/MemoryProvider.swift
Sources/MacResourceMonitor/Providers/NetworkProvider.swift
Sources/MacResourceMonitor/Providers/DiskProvider.swift
                                                    原生系统指标采集器
Sources/MacResourceMonitor/Providers/SMC/SMCTypes.swift
Sources/MacResourceMonitor/Providers/SMC/SMCClient.swift
Sources/MacResourceMonitor/Providers/AppleSiliconSensorProvider.swift
                                                    AppleSMC 通信、数据解码和传感器选择
Sources/MacResourceMonitor/Login/LoginItemManager.swift
                                                    登录启动状态和切换
Sources/MacResourceMonitor/UI/MenuBarLabelView.swift
Sources/MacResourceMonitor/UI/DashboardView.swift
Sources/MacResourceMonitor/UI/MetricCardView.swift
Sources/MacResourceMonitor/UI/SparklineView.swift
Sources/MacResourceMonitor/UI/SettingsView.swift
                                                    菜单栏标签、总览、折线和设置
Resources/Info.plist                              LSUIElement、版本和 bundle 标识
Tests/MacResourceMonitorTests/DomainTests.swift
Tests/MacResourceMonitorTests/SystemCalculatorTests.swift
Tests/MacResourceMonitorTests/SMCDecoderTests.swift
Tests/MacResourceMonitorTests/MonitoringEngineTests.swift
Tests/MacResourceMonitorTests/UITests.swift         纯状态与格式层 UI 测试
scripts/build-app.sh                                生成 arm64 `.app` 并 ad-hoc 签名
scripts/build-dmg.sh                                生成带 Applications 链接的 DMG
scripts/verify-release.sh                           验证 bundle、签名、架构和 DMG
INSTALL.md                                          未公证应用安装说明
```

### 任务 1：建立可编译、可测试、可打包的应用骨架

**文件：**
- 创建：`Package.swift`
- 创建：`Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift`
- 创建：`Resources/Info.plist`
- 创建：`Tests/MacResourceMonitorTests/UITests.swift`

- [ ] **步骤 1：编写失败的应用元数据测试**

```swift
import XCTest
@testable import MacResourceMonitor

final class UITests: XCTestCase {
    func testApplicationMetadataIsStable() {
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.local.MacResourceMonitor")
        XCTAssertEqual(AppMetadata.minimumSystemVersion, "13.0")
    }
}
```

- [ ] **步骤 2：运行测试并确认目标尚不存在**

运行：`swift test --filter UITests`

预期：FAIL，提示找不到 `Package.swift` 或 `MacResourceMonitor` 模块。

- [ ] **步骤 3：创建 Swift Package 和最小菜单栏应用**

`Package.swift` 使用 `.macOS(.v13)`、一个 executable target 和一个 test target，并链接 `IOKit`、`ServiceManagement`：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacResourceMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacResourceMonitor", targets: ["MacResourceMonitor"])],
    targets: [
        .executableTarget(
            name: "MacResourceMonitor",
            path: "Sources/MacResourceMonitor",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "MacResourceMonitorTests", dependencies: ["MacResourceMonitor"])
    ]
)
```

入口先提供可点击、可退出的窗口式菜单栏场景：

```swift
import AppKit
import SwiftUI

enum AppMetadata {
    static let bundleIdentifier = "com.local.MacResourceMonitor"
    static let minimumSystemVersion = "13.0"
}

@main
struct MacResourceMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Mac 状态", systemImage: "gauge.with.dots.needle.67percent") {
            Text("Mac 状态")
            Button("退出应用") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}
```

`Info.plist` 明确配置 `LSUIElement=true`、`LSMinimumSystemVersion=13.0` 和 bundle 版本。

- [ ] **步骤 4：验证骨架**

运行：`swift test --filter UITests && swift build`

预期：测试通过，debug 可执行文件构建成功。

- [ ] **步骤 5：提交骨架**

```bash
git add Package.swift Sources/MacResourceMonitor/App Resources/Info.plist Tests/MacResourceMonitorTests/UITests.swift
git commit -m "feat: 建立 macOS 菜单栏应用骨架"
```

### 任务 2：实现领域模型、环形历史和格式化

**文件：**
- 创建：`Sources/MacResourceMonitor/Domain/MetricSnapshot.swift`
- 创建：`Sources/MacResourceMonitor/Domain/RingBuffer.swift`
- 创建：`Sources/MacResourceMonitor/Formatting/MetricFormatter.swift`
- 创建：`Tests/MacResourceMonitorTests/DomainTests.swift`

- [ ] **步骤 1：为固定容量与格式化编写失败测试**

```swift
func testRingBufferKeepsNewestValuesInOrder() {
    var buffer = RingBuffer<Int>(capacity: 3)
    [1, 2, 3, 4].forEach { buffer.append($0) }
    XCTAssertEqual(buffer.elements, [2, 3, 4])
}

func testRateFormatterUsesCompactUnits() {
    XCTAssertEqual(MetricFormatter.rate(1_250_000), "1.3 MB/s")
    XCTAssertEqual(MetricFormatter.menuRate(8_400_000), "8.4M")
}
```

- [ ] **步骤 2：确认测试因类型缺失而失败**

运行：`swift test --filter DomainTests`

预期：FAIL，提示 `RingBuffer`、`MetricFormatter` 未定义。

- [ ] **步骤 3：实现明确的数据契约**

```swift
enum Reading<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable(String)
}

extension Reading {
    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

struct MemoryMetric: Equatable, Sendable {
    let usage: Double
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct NetworkMetric: Equatable, Sendable {
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
}

enum FanMetric: Equatable, Sendable {
    case rpm(Double)
    case fanless
}

struct ThermalMetric: Equatable, Sendable {
    let chipTemperatureCelsius: Double?
    let fan: FanMetric
}

struct DiskMetric: Equatable, Sendable {
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct MetricSnapshot: Sendable {
    let timestamp: Date
    let cpuUsage: Reading<Double>
    let memory: Reading<MemoryMetric>
    let network: Reading<NetworkMetric>
    let thermal: Reading<ThermalMetric>
    let disk: Reading<DiskMetric>
}

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let value: Double?
}
```

`RingBuffer` 使用预分配数组和写入索引，容量为零时触发 `precondition`。格式化器使用十进制网络/磁盘速率单位、二进制内存容量单位、整数百分比和整数 RPM。

- [ ] **步骤 4：运行领域测试**

运行：`swift test --filter DomainTests`

预期：PASS，覆盖容量 1、覆盖顺序、不可用点、KB/MB/GB、KiB/MiB/GiB 和负数钳制。

- [ ] **步骤 5：提交领域层**

```bash
git add Sources/MacResourceMonitor/Domain Sources/MacResourceMonitor/Formatting Tests/MacResourceMonitorTests/DomainTests.swift
git commit -m "feat: 添加指标模型和五分钟历史缓冲"
```

### 任务 3：实现 CPU 与内存采集器

**文件：**
- 创建：`Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift`
- 创建：`Sources/MacResourceMonitor/Providers/CPUProvider.swift`
- 创建：`Sources/MacResourceMonitor/Providers/MemoryProvider.swift`
- 创建：`Tests/MacResourceMonitorTests/SystemCalculatorTests.swift`

- [ ] **步骤 1：编写 tick 差值和内存换算失败测试**

```swift
func testCPUUsageUsesDeltaAndExcludesIdle() {
    let old = CPUTicks(user: 100, system: 50, nice: 0, idle: 850)
    let new = CPUTicks(user: 160, system: 70, nice: 0, idle: 870)
    XCTAssertEqual(CPUUsageCalculator.usage(previous: old, current: new), 0.8, accuracy: 0.0001)
}

func testMemoryMetricUsesPageCounts() {
    let metric = MemoryCalculator.metric(
        pageSize: 4096, active: 10, inactive: 5, wired: 3, compressed: 2, totalBytes: 100 * 4096
    )
    XCTAssertEqual(metric.usedBytes, 20 * 4096)
    XCTAssertEqual(metric.usage, 0.20, accuracy: 0.0001)
}
```

- [ ] **步骤 2：确认测试失败**

运行：`swift test --filter SystemCalculatorTests`

预期：FAIL，提示计算器类型未定义。

- [ ] **步骤 3：实现纯计算器和原生提供器**

定义：

```swift
protocol CPUProviding: Sendable { func sample() throws -> CPUTicks }
protocol MemoryProviding: Sendable { func sample() throws -> MemoryMetric }
```

`CPUProvider` 调用 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，汇总所有核心的 user/system/nice/idle tick，并用 `vm_deallocate` 释放返回缓冲。`MemoryProvider` 调用 `host_statistics64(HOST_VM_INFO64)`，读取 active、inactive、wired、compressed 页与 `ProcessInfo.processInfo.physicalMemory`。

- [ ] **步骤 4：运行系统计算测试和完整测试**

运行：`swift test --filter SystemCalculatorTests && swift test`

预期：全部通过；CPU 总差为零时返回 `nil`，比例始终限制在 0...1。

- [ ] **步骤 5：提交 CPU 与内存采集**

```bash
git add Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift Sources/MacResourceMonitor/Providers/CPUProvider.swift Sources/MacResourceMonitor/Providers/MemoryProvider.swift Tests/MacResourceMonitorTests/SystemCalculatorTests.swift
git commit -m "feat: 采集 CPU 和内存指标"
```

### 任务 4：实现网络与磁盘速率采集

**文件：**
- 创建：`Sources/MacResourceMonitor/Providers/NetworkProvider.swift`
- 创建：`Sources/MacResourceMonitor/Providers/DiskProvider.swift`
- 修改：`Tests/MacResourceMonitorTests/SystemCalculatorTests.swift`

- [ ] **步骤 1：编写累计计数、接口切换和容量失败测试**

```swift
func testNetworkRateNeedsStableInterfaceSet() {
    var calculator = NetworkRateCalculator()
    XCTAssertNil(calculator.update(.init(received: 100, sent: 50, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 0)))
    XCTAssertEqual(
        calculator.update(.init(received: 1_100, sent: 550, interfaces: ["en0"]), at: .init(timeIntervalSince1970: 1)),
        NetworkMetric(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)
    )
    XCTAssertNil(calculator.update(.init(received: 100, sent: 20, interfaces: ["en1"]), at: .init(timeIntervalSince1970: 2)))
}

func testDiskRateDropsCounterReset() {
    var calculator = DiskRateCalculator()
    _ = calculator.update(read: 1_000, written: 2_000, at: .init(timeIntervalSince1970: 0))
    XCTAssertNil(calculator.update(read: 100, written: 200, at: .init(timeIntervalSince1970: 1)))
}
```

- [ ] **步骤 2：确认新增测试失败**

运行：`swift test --filter SystemCalculatorTests`

预期：FAIL，提示速率计算器未定义。

- [ ] **步骤 3：实现网络采集与稳定接口基线**

`NetworkProvider` 使用 `getifaddrs` 读取 `AF_LINK` 的 `if_data`；仅聚合处于 UP/RUNNING 状态的接口，排除 `lo`、`utun`、`awdl`、`llw`、`bridge`、`vmenet` 前缀。活动接口集合变化、计数下降或间隔不在 0.25...10 秒时，返回无速率样本并重建基线。

- [ ] **步骤 4：实现启动磁盘 I/O 与容量**

`DiskProvider` 用 `statfs("/")` 获取启动卷 BSD 设备名，沿 IOKit `IOMedia` 父链定位物理存储驱动，从 `Statistics` 字典读取 `Bytes (Read)` 与 `Bytes (Write)`。容量通过 `FileManager.default.attributesOfFileSystem(forPath: "/")` 读取 `.systemSize` 和 `.systemFreeSize`。速率计算沿用稳定时间间隔、计数下降和异常值过滤规则；单次速率上限设为每秒 100 GB，超过即重建基线。

- [ ] **步骤 5：验证并提交 I/O 采集**

运行：`swift test --filter SystemCalculatorTests && swift test`

预期：全部通过，包括首次无速率、1 秒换算、2 秒换算、接口变化、计数下降和异常增量。

```bash
git add Sources/MacResourceMonitor/Providers/NetworkProvider.swift Sources/MacResourceMonitor/Providers/DiskProvider.swift Tests/MacResourceMonitorTests/SystemCalculatorTests.swift
git commit -m "feat: 采集网络和启动磁盘指标"
```

### 任务 5：实现 Apple Silicon 温度和风扇读取

**文件：**
- 创建：`Sources/MacResourceMonitor/Providers/SMC/SMCTypes.swift`
- 创建：`Sources/MacResourceMonitor/Providers/SMC/SMCClient.swift`
- 创建：`Sources/MacResourceMonitor/Providers/AppleSiliconSensorProvider.swift`
- 创建：`Tests/MacResourceMonitorTests/SMCDecoderTests.swift`

- [ ] **步骤 1：为 SMC 数据类型解码编写失败测试**

```swift
func testDecodesSP78Temperature() throws {
    XCTAssertEqual(try SMCDecoder.decode(bytes: [0x36, 0x80], type: "sp78"), 54.5, accuracy: 0.001)
}

func testDecodesFPE2FanSpeed() throws {
    XCTAssertEqual(try SMCDecoder.decode(bytes: [0x1C, 0x70], type: "fpe2"), 1820, accuracy: 0.001)
}

func testSensorSelectionUsesHottestPlausibleProcessorReading() {
    let values = ["TB0T": 32.0, "Tp01": 51.0, "Tp09": 54.0, "Tp99": 180.0]
    XCTAssertEqual(SensorSelection.chipTemperature(values), 54.0)
}
```

- [ ] **步骤 2：确认测试失败**

运行：`swift test --filter SMCDecoderTests`

预期：FAIL，提示 `SMCDecoder` 和 `SensorSelection` 未定义。

- [ ] **步骤 3：实现 AppleSMC 传输与可测试解码器**

`SMCClient` 打开 `IOServiceMatching("AppleSMC")`，用 `IOServiceOpen` 建立只读连接，并通过 selector 2 执行 SMC read-key-info、read-bytes 和 read-index 命令。`SMCTypes.swift` 定义与内核 ABI 字段顺序一致的结构体。解码器明确支持 `sp78`、`flt `、`fpe2`、`ui8 `、`ui16` 和 `ui32`，所有多字节整数按大端解析。

```swift
protocol SMCTransport: Sendable {
    func allKeys() throws -> [String]
    func read(_ key: String) throws -> SMCValue
}
```

- [ ] **步骤 4：实现传感器筛选和无风扇语义**

温度候选必须以 `Tp` 开头、数值位于 10...125°C，取最高值作为“芯片温度”。读取 `FNum` 得到风扇数量；数量为 0 返回 `.fanless`，否则读取 `F0Ac` 到 `F(n-1)Ac` 并显示最高当前 RPM。AppleSMC 不存在、没有可信温度或风扇键读取失败时返回对应的 unavailable 状态。

- [ ] **步骤 5：验证并提交传感器层**

运行：`swift test --filter SMCDecoderTests && swift test`

预期：全部通过，包括错误字节长度、未知类型、越界温度、零风扇和多个风扇。

```bash
git add Sources/MacResourceMonitor/Providers/SMC Sources/MacResourceMonitor/Providers/AppleSiliconSensorProvider.swift Tests/MacResourceMonitorTests/SMCDecoderTests.swift
git commit -m "feat: 读取 Apple Silicon 温度和风扇"
```

### 任务 6：实现监控引擎、历史数据和失败隔离

**文件：**
- 创建：`Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`
- 创建：`Sources/MacResourceMonitor/Monitoring/MonitoringStore.swift`
- 创建：`Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`

- [ ] **步骤 1：使用假采集器编写失败隔离测试**

```swift
func testOneProviderFailureDoesNotDropOtherMetrics() async throws {
    let providers = ProviderSet(
        cpu: FakeCPUProvider(result: .success(.init(user: 10, system: 10, nice: 0, idle: 80))),
        memory: FakeMemoryProvider(result: .failure(TestError.failed)),
        network: FakeNetworkProvider(), disk: FakeDiskProvider(), sensors: FakeSensorProvider()
    )
    let engine = MonitoringEngine(providers: providers, historyCapacity: 300)
    let snapshot = await engine.sample(at: Date(timeIntervalSince1970: 1))
    XCTAssertNotNil(snapshot.cpuUsage.value)
    XCTAssertTrue(snapshot.memory.isUnavailable)
}
```

- [ ] **步骤 2：确认测试失败**

运行：`swift test --filter MonitoringEngineTests`

预期：FAIL，提示引擎和假采集器契约未定义。

- [ ] **步骤 3：实现 actor 引擎和每秒采样循环**

`MonitoringEngine` 是 actor。`sample(at:)` 对彼此独立的采集器使用 `async let`，分别捕获错误后合并快照；CPU 使用率、网络和磁盘速率依赖 actor 内保存的前次基线。`start()` 创建单一 Task，使用 `ContinuousClock.sleep(for: .seconds(1))`，`stop()` 取消该 Task。

```swift
struct MetricHistory: Sendable {
    var cpu = RingBuffer<HistoryPoint>(capacity: 300)
    var memory = RingBuffer<HistoryPoint>(capacity: 300)
    var upload = RingBuffer<HistoryPoint>(capacity: 300)
    var download = RingBuffer<HistoryPoint>(capacity: 300)
}
```

- [ ] **步骤 4：实现主线程 Store**

`MonitoringStore` 标记 `@MainActor` 并遵循 `ObservableObject`，用 `@Published private(set)` 暴露 snapshot/history。Store 消费引擎的 `AsyncStream<MonitoringUpdate>`；释放时取消消费任务。不可用样本作为 `value=nil` 的历史点保留，使图表产生断线而不是零值。

- [ ] **步骤 5：验证容量、取消和错误隔离并提交**

运行：`swift test --filter MonitoringEngineTests && swift test`

预期：全部通过，连续 301 次采样只保留 300 点；取消后不再发布；单项失败不影响其余值。

```bash
git add Sources/MacResourceMonitor/Monitoring Tests/MacResourceMonitorTests/MonitoringEngineTests.swift
git commit -m "feat: 添加每秒监控引擎和趋势历史"
```

### 任务 7：实现菜单栏总览、折线与降级状态

**文件：**
- 修改：`Sources/MacResourceMonitor/App/MacResourceMonitorApp.swift`
- 创建：`Sources/MacResourceMonitor/UI/MenuBarLabelView.swift`
- 创建：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 创建：`Sources/MacResourceMonitor/UI/MetricCardView.swift`
- 创建：`Sources/MacResourceMonitor/UI/SparklineView.swift`
- 修改：`Tests/MacResourceMonitorTests/UITests.swift`

- [ ] **步骤 1：为菜单栏文本和状态映射编写失败测试**

```swift
func testMenuBarTextContainsFourCompactMetrics() {
    let model = MenuBarPresentation(cpu: .value(0.24), memory: .value(0.61), upload: .value(1_200_000), download: .value(8_400_000))
    XCTAssertEqual(model.text, "C 24%   M 61%   ↑ 1.2M   ↓ 8.4M")
}

func testUnavailableReadingUsesDash() {
    XCTAssertEqual(MenuBarPresentation.compactPercent(.unavailable("read failed")), "—")
}
```

- [ ] **步骤 2：确认测试失败**

运行：`swift test --filter UITests`

预期：FAIL，提示 `MenuBarPresentation` 未定义。

- [ ] **步骤 3：实现菜单栏标签和总览布局**

菜单栏使用等宽数字，始终按 CPU、内存、上传、下载顺序输出。`DashboardView` 使用 360–400 pt 固定宽度、两列网格：CPU/内存、上传/下载、温度/风扇，磁盘卡片跨两列。卡片数值宽度稳定，不因单位变化改变布局。

- [ ] **步骤 4：实现 5 分钟迷你折线**

`SparklineView` 使用 Swift Charts：

```swift
Chart(points) { point in
    if let value = point.value {
        LineMark(x: .value("时间", point.timestamp), y: .value("数值", value))
            .interpolationMethod(.linear)
    }
}
.chartXAxis(.hidden)
.chartYAxis(.hidden)
.accessibilityLabel("最近五分钟趋势")
```

为 CPU/内存固定 0...1 纵轴；网络根据可用样本自动缩放。无数据时显示短横线和“等待下一次采样”，失败时显示“暂不可用”，无风扇显示“无风扇”。

- [ ] **步骤 5：连接 Store、运行测试并提交**

运行：`swift test --filter UITests && swift test && swift build`

预期：所有测试和构建通过；入口将同一个 `MonitoringStore` 注入菜单栏标签与总览面板。

```bash
git add Sources/MacResourceMonitor/App Sources/MacResourceMonitor/UI Tests/MacResourceMonitorTests/UITests.swift
git commit -m "feat: 完成菜单栏总览和五分钟折线"
```

### 任务 8：实现登录启动和设置页

**文件：**
- 创建：`Sources/MacResourceMonitor/Login/LoginItemManager.swift`
- 创建：`Sources/MacResourceMonitor/UI/SettingsView.swift`
- 修改：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 修改：`Tests/MacResourceMonitorTests/UITests.swift`

- [ ] **步骤 1：为登录启动状态机编写失败测试**

```swift
func testLoginToggleRegistersWhenDisabled() throws {
    let service = FakeLoginService(status: .notRegistered)
    let manager = LoginItemManager(service: service)
    try manager.setEnabled(true)
    XCTAssertEqual(service.registerCount, 1)
}
```

- [ ] **步骤 2：确认测试失败**

运行：`swift test --filter UITests`

预期：FAIL，提示 `LoginItemManager` 未定义。

- [ ] **步骤 3：实现 ServiceManagement 适配器**

```swift
protocol LoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
```

生产适配器包装 `SMAppService.mainApp`。开关打开时仅在状态不是 `.enabled` 时调用 `register()`；关闭时仅在已注册或需要批准状态下调用 `unregister()`。错误显示在设置页内，不弹系统外的重复通知。

- [ ] **步骤 4：实现设置页并验证**

设置页显示登录启动开关、“每 1 秒刷新 · 保留最近 5 分钟”、版本号、诊断日志位置和退出按钮。切换失败后恢复开关到服务真实状态。

运行：`swift test --filter UITests && swift test && swift build`

预期：全部通过，注册、取消、重复操作和错误回滚均有测试。

- [ ] **步骤 5：提交设置功能**

```bash
git add Sources/MacResourceMonitor/Login Sources/MacResourceMonitor/UI/SettingsView.swift Sources/MacResourceMonitor/UI/DashboardView.swift Tests/MacResourceMonitorTests/UITests.swift
git commit -m "feat: 添加登录启动和设置页"
```

### 任务 9：生成 `.app`、DMG 与发布验证

**文件：**
- 创建：`scripts/build-app.sh`
- 创建：`scripts/build-dmg.sh`
- 创建：`scripts/verify-release.sh`
- 创建：`INSTALL.md`
- 修改：`.gitignore`

- [ ] **步骤 1：先写发布验证脚本并确认当前失败**

`scripts/verify-release.sh` 必须检查：

```bash
test -d dist/MacResourceMonitor.app
test -f dist/MacResourceMonitor.dmg
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' dist/MacResourceMonitor.app/Contents/Info.plist)" = true
file dist/MacResourceMonitor.app/Contents/MacOS/MacResourceMonitor | grep -q arm64
codesign --verify --deep --strict dist/MacResourceMonitor.app
hdiutil verify dist/MacResourceMonitor.dmg
```

运行：`bash scripts/verify-release.sh`

预期：FAIL，因为 `dist` 中尚无应用与 DMG。

- [ ] **步骤 2：实现 `.app` 构建脚本**

`build-app.sh` 执行 `swift build -c release --arch arm64`，建立 `dist/MacResourceMonitor.app/Contents/{MacOS,Resources}`，复制 release 二进制和 `Resources/Info.plist`，设置可执行权限，再运行：

```bash
codesign --force --deep --sign - dist/MacResourceMonitor.app
```

脚本开头使用 `set -euo pipefail`，所有路径从脚本所在仓库根目录解析，不依赖调用者当前目录。

- [ ] **步骤 3：实现 DMG 构建脚本**

`build-dmg.sh` 清理并重建 `build/dmg-root`，复制 `.app`、创建指向 `/Applications` 的符号链接、复制 `INSTALL.md`，然后执行：

```bash
hdiutil create -volname "Mac Resource Monitor" -srcfolder build/dmg-root -ov -format UDZO dist/MacResourceMonitor.dmg
```

`.gitignore` 加入 `/build/` 和 `/dist/`。

- [ ] **步骤 4：编写安装说明**

`INSTALL.md` 明确说明：挂载 DMG、拖入 Applications、首次右键选择“打开”、在确认框中继续；卸载时先退出应用并关闭登录启动，再删除 `/Applications/MacResourceMonitor.app`。说明未公证是因为当前没有 Developer ID，不要求用户关闭 Gatekeeper。

- [ ] **步骤 5：生成并验证交付物**

运行：

```bash
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
```

预期：三个命令均为 0；`dist/MacResourceMonitor.dmg` 可由 `hdiutil verify` 验证，应用为 arm64，ad-hoc 签名有效，`LSUIElement=true`。

- [ ] **步骤 6：手工安装验收**

挂载 DMG，将应用拖入 `/Applications`，右键选择“打开”，确认：无 Dock 图标；菜单栏出现四项指标；一秒后网络/磁盘速度不再为 `—`；点击后所有卡片和折线可见；登录启动开关可切换；退出后进程结束。

- [ ] **步骤 7：提交发布链路**

```bash
git add scripts INSTALL.md .gitignore
git commit -m "build: 添加应用和 DMG 发布流程"
```

### 任务 10：最终回归、文档核对与交付

**文件：**
- 修改：`INSTALL.md`
- 创建：`docs/verification/2026-10-01-release-checklist.md`

- [ ] **步骤 1：运行完整自动化验证**

运行：

```bash
swift test
swift build -c release --arch arm64
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
git diff --check
```

预期：测试、release 构建、签名验证、DMG 验证和空白检查全部通过。

- [ ] **步骤 2：完成真机指标核验**

同时打开系统“活动监视器”，依次执行空闲、高 CPU、网络下载和大文件复制场景。记录菜单栏与面板是否响应、趋势方向是否一致、睡眠唤醒后是否在第二次采样恢复速率；在 `docs/verification/2026-10-01-release-checklist.md` 逐项记录通过结果和测试机型。

- [ ] **步骤 3：完成 DMG 安装生命周期核验**

从 DMG 安装到 `/Applications`，完成首次右键打开、启用/关闭登录启动、退出、重新启动和卸载。确认 INSTALL 文档与实际界面一致。

- [ ] **步骤 4：检查版本状态并提交验收记录**

运行：`git status --short && git log --oneline -10`

预期：除计划交付的 DMG（由 `.gitignore` 忽略）外无未跟踪或未提交文件；任务 1–9 的提交均存在。

```bash
git add INSTALL.md docs/verification/2026-10-01-release-checklist.md
git commit -m "docs: 记录首版发布验收结果"
```

## 规格覆盖检查

- 菜单栏四项指标：任务 7。
- CPU、内存、网络：任务 3、4。
- 温度、风扇和无风扇降级：任务 5。
- 系统启动卷已用/总容量：任务 8A（取代任务 4 的磁盘读写速率范围）。
- 每秒采样、300 点历史和断线语义：任务 2、6。
- Swift Charts 折线与 A 方案布局：任务 7。
- 登录启动与退出：任务 1、8。
- 无 Dock 图标：任务 1、9。
- Apple Silicon arm64：任务 5、9。
- 单项失败隔离、睡眠/接口变化：任务 4、6、10。
- ad-hoc 签名、安装说明和 DMG：任务 9、10。

## 范围变更：任务 8A（2026-10-01）

用户将磁盘指标收窄为系统启动卷容量。此变更取代任务 4 的磁盘 I/O 采集与速率计算、任务 6 的磁盘速率基线与设备切换处理，以及任务 7 的磁盘读写速度展示；上文任务记录保留原状，作为已发生工作的历史说明。

当前实现应仅从根目录 `/` 所在文件系统读取 `.systemSize` 和 `.systemFreeSize`，得到已用和总字节数。`DiskMetric`、`DiskProviding`、`ProviderSet`、监控引擎及磁盘卡片只承载容量；不保留磁盘读写计数器、速率计算器、设备身份或速率 UI。磁盘容量采集失败仍独立标记为不可用，并写入诊断日志；菜单栏继续只显示 CPU、内存、上传和下载。容量进度条在总量为零时显示 0，已用量超过总量时限制为 1。

验收以更新后的设计规格为准。先让容量-only 测试针对旧实现失败，再验证容量换算、进度边界、独立失败处理与展示；运行严格并发 harness、`swift build` 和 `git diff --check`。当前环境缺少 XCTest 时，以同源独立 harness 验证并记录标准测试不可运行的原因。

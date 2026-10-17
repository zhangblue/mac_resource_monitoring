# 进程资源 Top 5 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 CPU、内存、上传和下载四张指标卡的折线图下方增加当前进程资源 Top 5 纯数字排行。

**架构：** 使用 `libproc` 的 `PROC_PIDTASKALLINFO` 获取进程身份、累计 CPU 时间和常驻内存，使用 `/usr/bin/nettop` 获取每进程累计网络字节。无状态采集器产生原始计数器，`MonitoringEngine` 内的差值计算器按 PID 与启动时间建立 CPU/网络基线，并将四类独立读数写入同一个 `MetricSnapshot`。

**技术栈：** Swift 5.9、Swift Concurrency、SwiftUI、Foundation `Process`、Darwin `libproc`、XCTest、macOS 13+

---

## 文件结构

- 创建 `Sources/MacResourceMonitor/Domain/ProcessMetrics.swift`：进程身份、原始计数器、排行条目、四类排行快照和差值计算器。
- 创建 `Sources/MacResourceMonitor/Providers/ProcessSystemProvider.swift`：封装 `proc_listallpids` 与 `PROC_PIDTASKALLINFO`。
- 创建 `Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift`：安全运行 `nettop`、限制超时/输出、解析 CSV 并解析进程身份。
- 创建 `Sources/MacResourceMonitor/Providers/ProcessMetricsProvider.swift`：并发协调系统进程和网络进程采集，分别返回可用或失败读数。
- 修改 `Sources/MacResourceMonitor/Domain/MetricSnapshot.swift`：快照增加进程排行，提供兼容现有测试的默认等待值。
- 修改 `Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift`：增加进程采集协议和 `ProviderSet.processes`。
- 修改 `Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`：并发采集、基线重置、失败隔离、生命周期和诊断提交。
- 修改 `Sources/MacResourceMonitor/Logging/DiagnosticLogger.swift`：增加进程系统与进程网络诊断分类及安全错误类别。
- 创建 `Sources/MacResourceMonitor/UI/ProcessRankingView.swift`：Top 5 数字列表与展示模型。
- 修改 `Sources/MacResourceMonitor/UI/MetricCardView.swift`：折线图下方接入可选排行区域。
- 修改 `Sources/MacResourceMonitor/UI/DashboardView.swift`：四张卡分别绑定 CPU、内存、上传和下载排行。
- 创建 `Tests/MacResourceMonitorTests/ProcessRankingCalculatorTests.swift`：差值、排序、Top 5、等待和重置测试。
- 创建 `Tests/MacResourceMonitorTests/ProcessSystemProviderTests.swift`：枚举缓冲、单进程失败和字段映射测试。
- 创建 `Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift`：CSV、命令失败、超时和输出上限测试。
- 创建 `Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift`：数值格式、同名 PID 和状态文案测试。
- 修改 `Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`：进程排行集成、失败隔离、配置变化、睡眠和停止测试。
- 修改 `Tests/MacResourceMonitorTests/UITests.swift`：快照默认值及四卡排行展示回归测试。
- 修改 `README.md` 和 `docs/verification/2026-10-01-release-checklist.md`：记录进程 Top 5 行为与真机验证步骤。

## 全局约束

- 进程排行只保留当前快照，不写入 `MetricHistory`。
- 每类排行最多 5 条，按当前数值降序排列；相同数值用进程名、PID 稳定排序。
- CPU 可超过 100%；内存使用常驻字节；网络只显示正速率。
- CPU、内存、进程网络及现有系统指标的失败互相隔离。
- `nettop` 必须使用固定路径和参数直接启动，不得经过 Shell。
- `libproc` 在 SDK 头文件中标记为私有接口；每次发布必须验证目标 SDK 编译和真机采集，运行时失败只能使 CPU/内存进程排行降级。
- 睡眠唤醒、刷新间隔变化和引擎停止必须重置 CPU/网络进程基线。
- 现有折线图、菜单栏文字、磁盘 capacity-only 行为和 LSUIElement 属性保持不变。

### 任务 1：进程排行领域模型与差值计算器

**文件：**
- 创建：`Sources/MacResourceMonitor/Domain/ProcessMetrics.swift`
- 创建：`Tests/MacResourceMonitorTests/ProcessRankingCalculatorTests.swift`

- [ ] **步骤 1：编写失败的计算器测试**

建立以下固定夹具并覆盖 CPU 多核值、Top 5、稳定排序、网络零值过滤、计数器回退、PID 复用和 reset：

```swift
private let appA = ProcessIdentity(pid: 101, startTimeMicroseconds: 1_000_000)
private let appB = ProcessIdentity(pid: 102, startTimeMicroseconds: 2_000_000)

func testCPUUsesElapsedTimeAllowsMoreThanOneHundredPercentAndKeepsTopFive() {
    var calculator = ProcessRankingCalculator()
    let first = (0..<7).map {
        ProcessSystemCounter(identity: .init(pid: Int32(100 + $0), startTimeMicroseconds: UInt64($0)),
                             name: "app\($0)", cpuNanoseconds: 0, residentBytes: UInt64(100 + $0))
    }
    _ = calculator.update(system: .value(first), network: .value([]), at: Date(timeIntervalSince1970: 10))
    let second = first.enumerated().map { index, item in
        ProcessSystemCounter(identity: item.identity, name: item.name,
                             cpuNanoseconds: UInt64(index + 1) * 1_000_000_000,
                             residentBytes: item.residentBytes)
    }

    let result = calculator.update(system: .value(second), network: .value([]),
                                   at: Date(timeIntervalSince1970: 11))

    XCTAssertEqual(result.cpu.value?.map(\.name), ["app6", "app5", "app4", "app3", "app2"])
    XCTAssertEqual(result.cpu.value?.first?.value ?? -1, 700, accuracy: 0.001)
}

func testNetworkFiltersZeroSeparatesDirectionsAndRejectsReusedPID() {
    var calculator = ProcessRankingCalculator()
    _ = calculator.update(system: .value([]), network: .value([
        .init(identity: appA, name: "A", receivedBytes: 100, sentBytes: 200),
        .init(identity: appB, name: "B", receivedBytes: 300, sentBytes: 400)
    ]), at: Date(timeIntervalSince1970: 20))

    let reused = ProcessIdentity(pid: appA.pid, startTimeMicroseconds: 9_000_000)
    let result = calculator.update(system: .value([]), network: .value([
        .init(identity: reused, name: "A2", receivedBytes: 9_000, sentBytes: 9_000),
        .init(identity: appB, name: "B", receivedBytes: 1_300, sentBytes: 400)
    ]), at: Date(timeIntervalSince1970: 21))

    XCTAssertEqual(result.download.value?.map(\.name), ["B"])
    XCTAssertEqual(result.download.value?.first?.value ?? -1, 1_000)
    XCTAssertEqual(result.upload.value, [])
}
```

另加断言：内存首轮立即可用；CPU/网络首轮为等待；相同数值按名称再按 PID；非正时间间隔不产生差值；累计值回退只丢弃对应进程；`.unavailable` 原样传播到对应排行；`resetRates()` 后 CPU/网络重新等待但内存仍可用。

- [ ] **步骤 2：运行新测试并确认失败**

运行：

```bash
swift test --filter ProcessRankingCalculatorTests
```

预期：编译失败，报告 `ProcessIdentity`、`ProcessRankingCalculator` 等类型不存在。

- [ ] **步骤 3：实现领域类型与计算器**

在 `ProcessMetrics.swift` 中定义：

```swift
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
}

struct ProcessSystemCounter: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
}

struct ProcessNetworkCounter: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct ProcessRankingEntry: Identifiable, Equatable, Sendable {
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let name: String
    let value: Double
}

struct ProcessRankings: Sendable {
    let cpu: Reading<[ProcessRankingEntry]>
    let memory: Reading<[ProcessRankingEntry]>
    let upload: Reading<[ProcessRankingEntry]>
    let download: Reading<[ProcessRankingEntry]>

    static func waiting(_ reason: String = "等待进程采样基线") -> Self
}

struct ProcessRawSnapshot: Sendable {
    let system: Reading<[ProcessSystemCounter]>
    let network: Reading<[ProcessNetworkCounter]>
}
```

`ProcessRankingCalculator` 保存上一轮系统和网络计数器及时间。CPU 公式为 `Double(deltaNanoseconds) / elapsedSeconds / 10_000_000`，得到百分数；网络公式为 `Double(deltaBytes) / elapsedSeconds`。差值相减前先比较大小，避免无符号整数下溢。排序函数固定为数值降序、名称本地化无关的字典序升序、PID 升序，并使用 `prefix(5)`。

- [ ] **步骤 4：运行计算器测试确认通过**

运行：

```bash
swift test --filter ProcessRankingCalculatorTests
```

预期：全部通过，CPU 首轮、网络首轮和 reset 后的读数处于等待状态，内存首轮已有排行。

- [ ] **步骤 5：提交领域模型**

```bash
git add Sources/MacResourceMonitor/Domain/ProcessMetrics.swift Tests/MacResourceMonitorTests/ProcessRankingCalculatorTests.swift
git commit -m "feat: add process ranking calculations"
```

### 任务 2：实现 libproc 与 nettop 原始采集

**文件：**
- 创建：`Sources/MacResourceMonitor/Providers/ProcessSystemProvider.swift`
- 创建：`Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift`
- 创建：`Sources/MacResourceMonitor/Providers/ProcessMetricsProvider.swift`
- 修改：`Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift`
- 创建：`Tests/MacResourceMonitorTests/ProcessSystemProviderTests.swift`
- 创建：`Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift`

- [ ] **步骤 1：编写失败的 libproc 映射和容错测试**

通过可注入的 `ProcessInfoAccessing` 假实现验证：第一次列表调用只返回容量、第二次填充 PID；PID 为 0 时忽略；`PROC_PIDTASKALLINFO` 返回尺寸不完整时只跳过该 PID；合法字段按以下方式映射：

```swift
let identity = ProcessIdentity(
    pid: pid,
    startTimeMicroseconds: info.pbsd.pbi_start_tvsec * 1_000_000
        + info.pbsd.pbi_start_tvusec
)
let cpu = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
let memory = info.ptinfo.pti_resident_size
```

测试断言至少一个 PID 成功时返回成功数组；所有 PID 在列表后退出时返回空数组而非整体失败；列表 API 返回负数时抛出 `ProcessSystemProviderError.processListFailed`。

- [ ] **步骤 2：编写失败的 nettop 解析和执行边界测试**

使用以下固定 CSV 覆盖空首列表头、名称中的空格、引号和逗号、最后一个点后的 PID、无效数字及缺列：

```swift
let csv = """
,bytes_in,bytes_out,
Code Helper.42,1200,300,
"Comma, App.43",600,900,
invalid-row,1,2,
"""
let rows = try NetTopCSVParser.parse(Data(csv.utf8))
XCTAssertEqual(rows.map(\.pid), [42, 43])
XCTAssertEqual(rows[1].name, "Comma, App")
```

用假的 `NetTopCommandRunning` 验证：固定 executable 为 `/usr/bin/nettop`；参数精确为 `[-P, -L, 1, -x, -J, bytes_in,bytes_out]`；非零退出、超过 1 MiB、超过 800 ms 和任务取消分别返回明确错误；同一时刻最多一个命令运行。

- [ ] **步骤 3：运行采集测试确认失败**

运行：

```bash
swift test --filter ProcessSystemProviderTests
swift test --filter NetTopProcessProviderTests
```

预期：编译失败，报告采集协议、provider 和 parser 类型不存在。

- [ ] **步骤 4：实现 libproc 采集器**

`ProcessInfoAccessing` 暴露两个最小方法：

```swift
protocol ProcessInfoAccessing: Sendable {
    func allPIDs() throws -> [Int32]
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo?
}
```

生产实现先用空缓冲调用 `proc_listallpids(nil, 0)` 获得 PID 数量，再按 `数量 + 32` 分配 `Int32` 数组，以数组字节数作为第二次调用的 `buffersize`；第二次返回值按实际 PID 数量解释并截取数组。读取 `PROC_PIDTASKALLINFO` 时只有返回值等于 `MemoryLayout<proc_taskallinfo>.size` 才接受。名称优先使用非空 `pbi_name`，否则使用 `pbi_comm`，两者都为空时使用 `PID <n>`。

- [ ] **步骤 5：实现 CSV parser、受限命令运行器与 nettop provider**

实现能处理 RFC 4180 双引号和双引号转义的单行 CSV parser。表头按名称定位 `bytes_in`、`bytes_out`，不依赖固定列下标。数据行从第一列最后一个 `.` 后解析 PID，解析失败的行跳过；表头缺失或没有任何可解析数据行时抛错。

`FoundationNetTopCommandRunner` 用 `Process` 直接启动固定路径，stdout/stderr 使用独立 `Pipe`。运行器在读取期间累计字节，超过 1 MiB 立即终止进程并返回 `outputTooLarge`；用任务组与 `ContinuousClock` 实现 800 ms 超时，超时或调用任务取消时执行 `terminate()`，等待退出后关闭文件句柄。

`NetTopProcessProvider` 将解析出的 PID 交给 `ProcessIdentityResolving`，再次用 `PROC_PIDTASKALLINFO` 获取启动时间；无法解析身份的进程跳过。输出 `ProcessNetworkCounter`，同一身份重复出现时按累计字节求和并保留首个非空名称。

- [ ] **步骤 6：实现组合 provider 与协议注入**

在 `ProviderProtocols.swift` 增加：

```swift
protocol ProcessMetricsProviding: Sendable {
    func sample() async -> ProcessRawSnapshot
    func cancel() async
}
```

`ProcessMetricsProvider` actor 并发执行系统采集和 nettop 采集，并分别转换为 `.value` 或 `.unavailable(errorCategory)`。`cancel()` 终止正在执行的 nettop 命令。`ProviderSet` 增加 `processes`，`.live` 使用 `ProcessMetricsProvider()`。

- [ ] **步骤 7：运行采集器测试和全套测试**

运行：

```bash
swift test --filter ProcessSystemProviderTests
swift test --filter NetTopProcessProviderTests
swift test
```

预期：新测试通过；旧测试只允许因 `ProviderSet` 初始化器新增参数而出现编译失败，随后给所有测试夹具注入返回空值的 `FakeProcessMetricsProvider` 并再次运行至全绿。

- [ ] **步骤 8：提交原始采集器**

```bash
git add Sources/MacResourceMonitor/Providers/ProcessSystemProvider.swift Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift Sources/MacResourceMonitor/Providers/ProcessMetricsProvider.swift Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift Tests/MacResourceMonitorTests/ProcessSystemProviderTests.swift Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift Tests/MacResourceMonitorTests/MonitoringEngineTests.swift Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift
git commit -m "feat: collect per-process resource counters"
```

### 任务 3：把进程排行接入监控引擎和诊断生命周期

**文件：**
- 修改：`Sources/MacResourceMonitor/Domain/MetricSnapshot.swift`
- 修改：`Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift`
- 修改：`Sources/MacResourceMonitor/Logging/DiagnosticLogger.swift`
- 修改：`Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`
- 修改：`Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift`
- 修改：`Tests/MacResourceMonitorTests/UITests.swift`

- [ ] **步骤 1：编写失败的引擎集成测试**

新增假的进程 provider，使第一轮系统计数为 0、第二轮 CPU 累计增加 500 ms，网络累计收发分别增加 1,000/2,000 字节。用相隔 1 秒的显式采样断言：

```swift
let first = await engine.sample(at: Date(timeIntervalSince1970: 1))
let second = await engine.sample(at: Date(timeIntervalSince1970: 2))

XCTAssertTrue(first.processes.cpu.isUnavailable)
    XCTAssertEqual(first.processes.memory.value?.first?.value ?? -1, 512 * 1_024 * 1_024)
    XCTAssertEqual(second.processes.cpu.value?.first?.value ?? -1, 50, accuracy: 0.001)
    XCTAssertEqual(second.processes.download.value?.first?.value ?? -1, 1_000)
    XCTAssertEqual(second.processes.upload.value?.first?.value ?? -1, 2_000)
```

再覆盖：进程 provider 的 system 失败但 network 成功；network 失败但 CPU/内存成功；刷新间隔改变后 CPU/网络重新等待；模拟睡眠 generation 改变后重新等待；`stop()` 调用 provider cancel 且重启不继承旧基线；迟到的旧 generation 进程结果不能提交或写诊断。

- [ ] **步骤 2：运行引擎测试确认失败**

运行：

```bash
swift test --filter MonitoringEngineTests
```

预期：编译失败，`MetricSnapshot` 尚无 `processes`，引擎尚未采集进程 provider。

- [ ] **步骤 3：扩展快照并保持旧调用兼容**

为 `MetricSnapshot` 增加 `let processes: ProcessRankings`，并显式提供初始化器，使 `processes` 默认值为 `.waiting()`。现有 fixture 无需批量添加无意义排行数据；真实引擎提交时必须显式传入计算结果。

- [ ] **步骤 4：扩展引擎采集、提交和基线重置**

将 `ProviderReadings` 从元组改成命名结构，避免新增第六项后继续使用位置索引：

```swift
private struct ProviderReadings: Sendable {
    let cpu: Reading<CPUTicks>
    let memory: Reading<MemoryMetric>
    let network: Reading<NetworkCounters>
    let disk: Reading<DiskMetric>
    let thermal: Reading<ThermalMetric>
    let processes: ProcessRawSnapshot
}
```

`collect` 用第六个 `async let` 调用 `providers.processes.sample()`。引擎保存 `ProcessRankingCalculator`，在 `commit` 中用当前日期生成 `ProcessRankings` 并写入快照。刷新间隔变化、睡眠 generation 变化和 `stop()` 时调用 `resetRates()`。把 `stop()` 和 `removeSubscriber(_:)` 调整为异步方法，使 `stop()` 能直接等待 `providers.processes.cancel()` 完成，保证返回前正在运行的 `nettop` 已终止；现有调用方已经位于异步上下文并继续使用 `await engine.stop()`。

- [ ] **步骤 5：增加独立诊断分类**

`DiagnosticComponent` 增加 `processSystem` 和 `processNetwork`。`recordDiagnostics` 分别记录 `readings.processes.system` 与 `.network`，安全错误类别加入：

```swift
"processListFailed", "nettopLaunchFailed", "nettopTimedOut",
"nettopOutputTooLarge", "nettopExitFailed", "nettopInvalidCSV"
```

成功读数清除该分类的旧失败；同一失败继续由现有 logger 去重。

- [ ] **步骤 6：运行引擎、边界和全套测试**

运行：

```bash
swift test --filter MonitoringEngineTests
swift test --filter SamplingBoundaryTests
swift test
```

预期：全部通过；现有总量历史仍只有 CPU、内存、上传、下载四个环形缓冲，进程排行不进入历史。

- [ ] **步骤 7：提交引擎集成**

```bash
git add Sources/MacResourceMonitor/Domain/MetricSnapshot.swift Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift Sources/MacResourceMonitor/Logging/DiagnosticLogger.swift Tests/MacResourceMonitorTests/MonitoringEngineTests.swift Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift Tests/MacResourceMonitorTests/UITests.swift
git commit -m "feat: publish process rankings with monitor snapshots"
```

### 任务 4：在四张指标卡内显示纯数字 Top 5

**文件：**
- 创建：`Sources/MacResourceMonitor/UI/ProcessRankingView.swift`
- 修改：`Sources/MacResourceMonitor/UI/MetricCardView.swift`
- 修改：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 修改：`Sources/MacResourceMonitor/Formatting/MetricFormatter.swift`
- 创建：`Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift`
- 修改：`Tests/MacResourceMonitorTests/UITests.swift`

- [ ] **步骤 1：编写失败的展示模型与格式测试**

定义四种展示样式并断言具体输出：

```swift
XCTAssertEqual(ProcessRankingStyle.cpu.format(142.35), "142.4%")
XCTAssertEqual(ProcessRankingStyle.memory.format(2_147_483_648), "2 GiB")
XCTAssertEqual(ProcessRankingStyle.upload.format(43_200), "43.2 KB/s")
XCTAssertEqual(ProcessRankingStyle.download.format(650_000), "650 KB/s")
```

给两个同名 `Chrome` 条目断言两行都追加 PID；名称唯一时不追加。断言 `nil` 快照和“等待进程采样基线”显示“等待下一次采样”，其他 unavailable 原因显示“暂不可用”，空成功数组显示“暂无活动进程”。

- [ ] **步骤 2：运行 UI 新测试确认失败**

运行：

```bash
swift test --filter ProcessRankingViewTests
```

预期：编译失败，`ProcessRankingStyle` 和展示模型不存在。

- [ ] **步骤 3：实现格式和展示模型**

在 `MetricFormatter` 增加保留一位且不强制整数化的 `processPercent(_:)`；内存继续复用 `memory(_:)`，网络继续复用 `rate(_:)`。`ProcessRankingPresentation` 将 `Reading<[ProcessRankingEntry]>?` 转为：

```swift
enum ProcessRankingContent: Equatable {
    case rows([ProcessRankingRow])
    case message(String)
}

struct ProcessRankingRow: Identifiable, Equatable {
    let id: ProcessIdentity
    let rank: Int
    let displayName: String
    let formattedValue: String
}
```

同名判断只针对当前 Top 5，重复名称的每一行追加 ` (PID)`。

- [ ] **步骤 4：实现排行视图与卡片布局**

`ProcessRankingView` 使用固定的三列 Grid：排名宽 14 pt、名称自适应、数值尾部对齐并启用 `.monospacedDigit()`。名称使用 `.lineLimit(1)` 和 `.truncationMode(.tail)`，数值不换行。标题为“进程 Top 5”，行间不使用进度条、Chart mark 或悬停 overlay。

`MetricCardView` 的趋势初始化器增加 `processes` 和 `processStyle` 参数，在 `SparklineView` 与详情文案之间插入 `Divider()` 和 `ProcessRankingView`。温度和风扇使用的无趋势初始化器保持不变。

`DashboardView` 分别绑定：

```swift
CPU     -> store.snapshot?.processes.cpu      / .cpu
内存    -> store.snapshot?.processes.memory   / .memory
上传    -> store.snapshot?.processes.upload   / .upload
下载    -> store.snapshot?.processes.download / .download
```

保持 `.frame(width: 380)`、两列 `LazyVGrid`、原有折线图高度、坐标和 hover 逻辑不变。

- [ ] **步骤 5：运行 UI 与全套测试**

运行：

```bash
swift test --filter ProcessRankingViewTests
swift test --filter UITests
swift test
```

预期：全部通过，现有菜单栏文字仍精确为四个总量指标，Top 5 不进入菜单栏。

- [ ] **步骤 6：提交 UI**

```bash
git add Sources/MacResourceMonitor/UI/ProcessRankingView.swift Sources/MacResourceMonitor/UI/MetricCardView.swift Sources/MacResourceMonitor/UI/DashboardView.swift Sources/MacResourceMonitor/Formatting/MetricFormatter.swift Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift Tests/MacResourceMonitorTests/UITests.swift
git commit -m "feat: show process top five in metric cards"
```

### 任务 5：文档、真实采集冒烟检查和最终验证

**文件：**
- 修改：`README.md`
- 修改：`docs/verification/2026-10-01-release-checklist.md`

- [ ] **步骤 1：更新用户文档**

README 的当前功能增加：CPU、内存、上传和下载卡片显示实时进程 Top 5；网络排行由系统 `nettop` 提供；单项不可用不影响总量指标。不要声称需要管理员权限、Network Extension、公证或关闭 Gatekeeper。

发布检查清单增加真机步骤：

```text
1. 打开 CPU 密集任务，确认 CPU Top 5 在下一轮差值采样后更新且允许超过 100%。
2. 打开多个同名辅助进程，确认重复名称附带 PID，长名称被尾部截断。
3. 产生上传和下载流量，确认两张网络卡使用同一轮采样但分别排序。
4. 切换 1/3/5 秒刷新，确认 CPU/网络先等待一轮后恢复，内存排行立即可用。
5. 睡眠再唤醒，确认没有跨睡眠区间的 CPU 或网络尖峰。
6. 临时模拟 nettop 失败，确认上传/下载排行暂不可用而折线图及其他指标继续刷新。
```

- [ ] **步骤 2：运行本机 nettop 冒烟检查**

运行：

```bash
/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out
```

预期：退出码为 0，CSV 表头包含 `bytes_in` 和 `bytes_out`，至少一个可解析的 `名称.PID` 数据行。若当前执行环境限制 NStat，记录环境限制并使用应用内错误隔离测试作为自动验证证据，不改变产品实现为需要管理员权限。

- [ ] **步骤 3：运行完整测试和 arm64 release 构建**

运行：

```bash
swift test
swift build -c release --arch arm64
git diff --check
```

预期：所有测试通过，release 构建成功，diff 无空白错误。

- [ ] **步骤 4：运行应用进行界面检查**

运行：

```bash
swift run MacResourceMonitor
```

检查 380 pt 面板内四张卡仍为两列；每张卡的折线图、纵轴、网格和悬停仍正常；Top 5 只显示数字；设置页仍可打开；菜单栏仍只显示 CPU、内存、上传和下载总量。检查完成后正常退出应用，不安装到 `/Applications`，不修改真实登录项。

- [ ] **步骤 5：提交文档与验证记录**

```bash
git add README.md docs/verification/2026-10-01-release-checklist.md
git commit -m "docs: document process top five monitoring"
```

- [ ] **步骤 6：进行最终分支审查**

对设计规格 `docs/superpowers/specs/2026-10-17-process-top-five-design.md` 逐项核对实现，检查进程身份、失败隔离、子进程生命周期、Top 5 UI 和不在范围内项目。只有 Critical/Important 发现全部解决且验证命令仍为绿色后，才进入分支收尾流程。

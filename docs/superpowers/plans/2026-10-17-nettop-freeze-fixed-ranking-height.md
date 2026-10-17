# nettop 卡死修复与进程排行固定高度实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 消除进程网络采集在子进程已经退出后仍阻塞 `waitUntilExit()` 的问题，并让四张进程排行卡始终保留五行高度。

**架构：** `FoundationNetTopCommandRunner` 继续负责固定 `nettop` 命令、超时与资源清理，但用启动前注册的 `terminationHandler` 和一次性 async 闩锁等待退出，不再调用 RunLoop 驱动的 `waitUntilExit()`。`ProcessRankingView` 把现有语义内容映射为固定五个行槽位，真实行、状态行和空白行共用同一 Grid 行高。

**技术栈：** Swift 6、Foundation `Process`/`Pipe`、Darwin 信号、Swift Concurrency、SwiftUI Grid/ImageRenderer、XCTest

---

## 文件结构

- `Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift`：固定命令执行、退出通知闩锁、超时/取消/强制终止和双管道统一收尾。
- `Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift`：退出通知竞态、禁止回归到 `waitUntilExit()`、超时清理和立即重启测试。
- `Sources/MacResourceMonitor/UI/ProcessRankingView.swift`：把排行语义转换为固定五个视觉槽位并渲染。
- `Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift`：槽位数量、占位行为、固定高度和同名 PID 可见性测试。
- `docs/verification/2026-10-01-release-checklist.md`：记录卡死根因、自动化验证与本机持续运行结果。

### 任务 1：用终止通知替换 `waitUntilExit()`

**文件：**
- 修改：`Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift`
- 修改：`Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift`

- [ ] **步骤 1：编写阻塞回归测试**

扩展测试用的 `ControlledChildProcess`，让它可以单独触发 `terminationHandler`，同时把 `waitUntilExit()` 保持在门后。测试必须验证生产 runner 在终止 handler 已触发、stdout/stderr 已关闭后完成，而不等待该门：

```swift
func testFoundationCompletionDoesNotDependOnWaitUntilExitRunLoop() async throws {
    let process = ControlledChildProcess()
    let runner = FoundationNetTopCommandRunner(processFactory: { process })
    let running = Task {
        try await runner.run(executable: NetTopProcessProvider.executable,
                             arguments: NetTopProcessProvider.arguments)
    }

    await waitFor { process.hasStarted }
    process.signalExit(status: 0)
    process.closeStdout()
    process.closeStderr()

    let result = try await value(of: running, within: .milliseconds(200))
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertFalse(process.didWaitForExit)
}
```

再增加“`run()` 内立即触发 termination handler”的测试，确保退出发生在 async waiter 正式等待之前也不会丢失：

```swift
func testTerminationBeforeAsyncWaitRegistrationStillCompletes() async throws {
    let process = ImmediatelyExitingControlledProcess(status: 0)
    let runner = FoundationNetTopCommandRunner(processFactory: { process })
    let result = try await value(of: Task {
        try await runner.run(executable: NetTopProcessProvider.executable,
                             arguments: NetTopProcessProvider.arguments)
    }, within: .milliseconds(200))
    XCTAssertEqual(result.exitStatus, 0)
}
```

测试超时 helper 必须在失败时释放受控进程的 wait 门和管道，不能留下永久挂起的测试任务。

- [ ] **步骤 2：运行聚焦测试并确认 RED**

运行：

```bash
swift test --filter 'NetTopProcessProviderTests.testFoundationCompletionDoesNotDependOnWaitUntilExitRunLoop|NetTopProcessProviderTests.testTerminationBeforeAsyncWaitRegistrationStillCompletes'
```

预期：旧实现调用 `waitUntilExit()`，第一个测试无法在 200 ms 内完成或 `didWaitForExit == true`；第二个测试暴露终止发生在等待注册前的竞态。清理 helper 后测试进程必须正常结束。

- [ ] **步骤 3：实现一次性终止闩锁**

在生产文件内新增私有、线程安全的闩锁。完成事件先于等待发生时保存结果；等待先发生时保存 continuation；两种顺序都只恢复一次：

```swift
private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else { lock.unlock(); return }
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}
```

`NetTopExecution` 初始化时创建 latch，并在 `process.run()` 前设置：

```swift
process.terminationHandler = { [termination] process in
    termination.finish(process.terminationStatus)
}
```

`collect()` 启动两个 reader 后使用 `let status = await termination.wait()`，再等待 reader，最后把捕获的 status 交给 `result(exitStatus:)`。删除所有生产代码中的 `waitUntilExit()`。

- [ ] **步骤 4：统一 timeout 与有界强制结束**

删除 `NetTopProcessProvider.sample()` 外层重复的 800 ms task-group timeout，让 runner 成为唯一 timeout 所有者。runner 为每次运行创建 watchdog：

```swift
let watchdog = Task {
    try? await Task.sleep(for: .milliseconds(800))
    guard !Task.isCancelled else { return }
    command.stop(.timedOut)
}
defer { watchdog.cancel() }
```

`stop(_:)` 锁内只记录第一条错误并发送一次 `terminate()`，随后启动一个短宽限任务；宽限期后若同一个 Process 仍 `isRunning`，通过可注入的 force-kill 闭包发送 `SIGKILL`。生产闭包为：

```swift
{ process in
    guard process.isRunning else { return }
    Darwin.kill(process.processIdentifier, SIGKILL)
}
```

测试注入记录器，不向真实测试宿主 PID 发送信号。正常退出取消 watchdog；取消、超时和输出超限仍由 `collect()` 唯一收尾并保留第一条错误类别。

- [ ] **步骤 5：更新生命周期测试并确认 GREEN**

把旧 `ControlledChildProcess.releaseExit()` 改为触发 termination handler；删除“必须调用 waitUntilExit”的断言，改为断言 handler 完成、双 reader EOF、句柄关闭和立即重启。增加不响应 `terminate()` 时 force-kill 闭包只调用一次、且 `.timedOut` 不被覆盖的断言。

运行：

```bash
swift test --filter NetTopProcessProviderTests
```

预期：全部通过；测试总耗时有限，没有遗留子任务。

- [ ] **步骤 6：提交进程生命周期修复**

```bash
git add Sources/MacResourceMonitor/Providers/NetTopProcessProvider.swift Tests/MacResourceMonitorTests/NetTopProcessProviderTests.swift
git commit -m "fix: prevent nettop termination waits from stalling"
```

### 任务 2：固定进程排行的五行高度

**文件：**
- 修改：`Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift`
- 修改：`Sources/MacResourceMonitor/UI/ProcessRankingView.swift`

- [ ] **步骤 1：编写五行槽位失败测试**

为 presentation 增加可测试的固定槽位契约。测试 0、1、3、5 个排行和状态消息全部得到五个槽位：

```swift
func testRankingAlwaysBuildsFiveVisualSlots() {
    for count in [0, 1, 3, 5] {
        let entries = (0..<count).map { entry(index: $0) }
        let presentation = ProcessRankingPresentation(reading: .value(entries), style: .cpu)
        XCTAssertEqual(presentation.slots.count, 5)
        XCTAssertEqual(presentation.slots.filter(\.isProcess).count, count)
    }

    for reading in [nil, Reading<[ProcessRankingEntry]>.unavailable("nettopTimedOut")] {
        let presentation = ProcessRankingPresentation(reading: reading, style: .download)
        XCTAssertEqual(presentation.slots.count, 5)
        XCTAssertEqual(presentation.slots.filter(\.isMessage).count, 1)
    }
}
```

另用 `ImageRenderer` 渲染相同宽度的空结果、1 项、3 项、5 项和不可用状态，断言像素高度全部相等。

- [ ] **步骤 2：运行 UI 聚焦测试并确认 RED**

运行：

```bash
swift test --filter ProcessRankingViewTests
```

预期：编译失败，因为 `slots` 和固定槽位类型尚不存在；或高度断言显示旧视图随行数变化。

- [ ] **步骤 3：实现固定槽位模型**

增加：

```swift
struct ProcessRankingSlot: Identifiable, Equatable {
    enum Content: Equatable {
        case process(ProcessRankingRow)
        case message(String)
        case empty
    }
    let id: Int
    let content: Content
}
```

`ProcessRankingPresentation` 保留现有 `content` 语义，并生成恰好五个 `slots`：真实排行按顺序填充，消息只占第一格，其余补 `.empty`。

- [ ] **步骤 4：让所有状态共享同一个五行 Grid**

`ProcessRankingView` 不再在 Grid 外单独渲染 message。统一遍历 `presentation.slots`：

```swift
Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 4) {
    ForEach(presentation.slots) { slot in
        switch slot.content {
        case let .process(row): processRow(row)
        case let .message(message): messageRow(message)
        case .empty: emptyRow()
        }
    }
}
```

`emptyRow()` 用隐藏的 caption2 文本提供与真实行一致的行高，并设置 `.accessibilityHidden(true)`；它不应提供可见文字或撑宽数值列。`messageRow` 使用 `.gridCellColumns(3)`，其余四格仍为空行。保留名称截断与 PID 固定后缀。

- [ ] **步骤 5：运行 UI 测试并确认 GREEN**

运行：

```bash
swift test --filter ProcessRankingViewTests
swift test --filter UITests
```

预期：五行槽位、高度一致、同名 PID、格式和菜单栏四项总量测试全部通过。

- [ ] **步骤 6：提交固定高度修复**

```bash
git add Sources/MacResourceMonitor/UI/ProcessRankingView.swift Tests/MacResourceMonitorTests/ProcessRankingViewTests.swift
git commit -m "fix: keep process ranking cards at five rows"
```

### 任务 3：整体验证与回归记录

**文件：**
- 修改：`docs/verification/2026-10-01-release-checklist.md`

- [ ] **步骤 1：运行完整自动验证**

依次运行：

```bash
swift test
swift build -c release --arch arm64
git diff --check
```

预期：全部测试通过，arm64 Release 构建成功，无空白错误。既有未修改测试的 `weak var` 警告单独记录，不声称输出无警告。

- [ ] **步骤 2：运行真实 nettop 持续采集检查**

用本工作树构建的生产 runner 连续执行真实固定命令，覆盖至少五分钟或至少 300 次采样（以先达到者为准）。每次采样必须在 2 秒内完成；记录成功/失败次数、最长耗时和结束后的遗留子进程数，不记录原始进程名称。

若测试执行环境限制 NStat，记录该限制并在获准的本机环境重跑；不得改变产品为需要管理员权限。

- [ ] **步骤 3：运行应用与布局检查**

构建并运行本工作树应用，不安装到 `/Applications`，不修改登录项。检查：

- CPU、内存、上传和下载持续刷新至少五分钟。
- 0～5 个进程变化时四张卡片高度不变，空位显示为空行。
- 折线图、纵轴、水平刻度、hover、设置页、菜单栏四项总量和磁盘容量不变。
- 退出本轮自己启动的应用后没有遗留 `nettop` 子进程。

若界面工具不能访问菜单栏弹窗，记录自动测试和进程级证据，并把视觉项明确保留为人工验收，不能伪称通过。

- [ ] **步骤 4：更新发布检查记录**

在 `docs/verification/2026-10-01-release-checklist.md` 新增本轮条目，写明：

- 现场线程采样显示旧版本卡在 `Process.waitUntilExit()`，同时已无子进程。
- 新实现使用启动前注册的 termination handler 闩锁并带有强制结束兜底。
- 固定五行槽位的自动化测试结果。
- 完整测试、arm64 构建、持续运行和视觉验收的实际结果与限制。

- [ ] **步骤 5：提交验证记录**

```bash
git add docs/verification/2026-10-01-release-checklist.md
git commit -m "docs: record nettop stall regression verification"
```

- [ ] **步骤 6：完成前审查**

对 `docs/superpowers/specs/2026-10-17-nettop-freeze-fixed-ranking-height-design.md` 逐项核对实现，重点检查 termination handler 注册顺序、一次性 continuation、force-kill PID 边界、双管道 EOF、取消后重启、五行占位和既有 UI 行为。所有 Critical/Important 发现修复后，再进入分支收尾。

# 应用图标与动态折线图纵轴实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为 Mac Resource Monitor 增加可打包的正式应用图标，并让四张五分钟趋势图使用带三档刻度的动态纵轴，以清晰显示低负载波动。

**架构：** 将动态范围与刻度计算放入独立、纯 Swift 的展示模型，Swift Charts 仅消费已计算的坐标域、刻度和标签。应用图标保留 1024×1024 PNG 源图，通过可复现脚本生成 ICNS，并由现有应用包构建与发布验证脚本负责复制和校验。

**技术栈：** Swift 5.9、SwiftUI、Swift Charts（macOS 13+）、XCTest、`sips`、`iconutil`、现有 Bash 打包脚本。

---

## 文件结构

- 创建 `Sources/MacResourceMonitor/UI/SparklineAxisPresentation.swift`：计算动态纵轴范围、三档刻度和标签。
- 创建 `Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift`：覆盖低负载、恒定值、边界、网络速率和异常值。
- 修改 `Sources/MacResourceMonitor/UI/SparklineView.swift`：渲染显式纵轴、参考线、动态坐标域和指标颜色。
- 修改 `Sources/MacResourceMonitor/UI/MetricCardView.swift`：接收折线图指标样式。
- 修改 `Sources/MacResourceMonitor/UI/DashboardView.swift`：为 CPU、内存、上传、下载传入各自样式。
- 创建 `Resources/AppIcon-1024.png`：应用图标源图。
- 创建 `Resources/AppIcon.icns`：应用包使用的图标资源。
- 创建 `scripts/build-icon.sh`：从 1024×1024 PNG 可复现地生成标准 ICNS。
- 修改 `Resources/Info.plist`：声明 `CFBundleIconFile`。
- 修改 `scripts/build-app.sh`：复制 ICNS 到应用包。
- 修改 `scripts/verify-release.sh`：验证应用包和 DMG 内的图标声明与文件。

### 任务 1：动态纵轴展示模型

**文件：**
- 创建：`Sources/MacResourceMonitor/UI/SparklineAxisPresentation.swift`
- 创建：`Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift`

- [ ] **步骤 1：编写低负载与边界失败测试**

```swift
import XCTest
@testable import MacResourceMonitor

final class SparklineAxisPresentationTests: XCTestCase {
    func testLowCPUUsageUsesNarrowDynamicRange() throws {
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: [0.02, 0.03, 0.05], kind: .percentage))
        XCTAssertLessThanOrEqual(axis.domain.lowerBound, 0.02)
        XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 0.05)
        XCTAssertEqual(axis.domain.upperBound - axis.domain.lowerBound, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(axis.ticks.count, 3)
        XCTAssertLessThan(axis.domain.upperBound, 0.20)
    }

    func testPercentageRangeStaysWithinZeroAndOne() throws {
        let low = try XCTUnwrap(SparklineAxisPresentation(values: [0, 0.01], kind: .percentage))
        let high = try XCTUnwrap(SparklineAxisPresentation(values: [0.98, 1], kind: .percentage))
        XCTAssertEqual(low.domain.lowerBound, 0)
        XCTAssertEqual(high.domain.upperBound, 1)
        XCTAssertEqual(low.labels.first, "0%")
        XCTAssertEqual(high.labels.last, "100%")
    }

    func testConstantPercentageStillHasNonZeroRange() throws {
        let axis = try XCTUnwrap(SparklineAxisPresentation(values: [0.24, 0.24], kind: .percentage))
        XCTAssertEqual(axis.domain.upperBound - axis.domain.lowerBound, 0.10, accuracy: 0.000_001)
    }
}
```

- [ ] **步骤 2：运行测试并确认因为类型尚不存在而失败**

运行：`swift test --filter SparklineAxisPresentationTests`

预期：FAIL，编译器报告找不到 `SparklineAxisPresentation`。

- [ ] **步骤 3：补充网络速率、空数据和异常值失败测试**

```swift
func testRateRangeDoesNotForceZeroWhenTrafficHasBaseline() throws {
    let axis = try XCTUnwrap(SparklineAxisPresentation(values: [8_000_000, 8_200_000, 8_400_000], kind: .rate))
    XCTAssertGreaterThan(axis.domain.lowerBound, 0)
    XCTAssertLessThanOrEqual(axis.domain.lowerBound, 8_000_000)
    XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 8_400_000)
    XCTAssertEqual(axis.ticks.count, 3)
    XCTAssertTrue(axis.labels.allSatisfy { $0.contains("MB/s") })
}

func testConstantAndNearZeroRatesHaveSafeRanges() throws {
    let constant = try XCTUnwrap(SparklineAxisPresentation(values: [2048, 2048], kind: .rate))
    let zero = try XCTUnwrap(SparklineAxisPresentation(values: [0, 0], kind: .rate))
    XCTAssertGreaterThan(constant.domain.upperBound, constant.domain.lowerBound)
    XCTAssertGreaterThan(zero.domain.upperBound, zero.domain.lowerBound)
    XCTAssertEqual(zero.domain.lowerBound, 0)
}

func testEmptyAndNonFiniteValuesAreIgnored() {
    XCTAssertNil(SparklineAxisPresentation(values: [], kind: .percentage))
    XCTAssertNil(SparklineAxisPresentation(values: [.nan, .infinity], kind: .rate))
    XCTAssertNotNil(SparklineAxisPresentation(values: [.nan, 1024], kind: .rate))
}
```

- [ ] **步骤 4：实现最小动态坐标模型**

创建以下公共接口，并用私有辅助方法实现 `1、2、5 × 10ⁿ` 的向上取整步长：

```swift
enum SparklineAxisKind: Equatable {
    case percentage
    case rate
}

struct SparklineAxisPresentation: Equatable {
    let domain: ClosedRange<Double>
    let ticks: [Double]
    let labels: [String]

    init?(values: [Double], kind: SparklineAxisKind) {
        let finite = values.filter(\.isFinite)
        guard let minimum = finite.min(), let maximum = finite.max() else { return nil }

        switch kind {
        case .percentage:
            let bounds = Self.percentageBounds(minimum: minimum, maximum: maximum)
            domain = bounds.lower...bounds.upper
            ticks = [bounds.lower, (bounds.lower + bounds.upper) / 2, bounds.upper]
            labels = ticks.map { MetricFormatter.percent($0 * 100) }
        case .rate:
            let bounds = Self.rateBounds(minimum: max(0, minimum), maximum: max(0, maximum))
            domain = bounds.lower...bounds.upper
            ticks = [bounds.lower, (bounds.lower + bounds.upper) / 2, bounds.upper]
            labels = Self.rateLabels(for: ticks, upperBound: bounds.upper)
        }
    }
}
```

`percentageBounds` 必须以数据中心扩展到至少 `0.10` 跨度、加入 10% 留白，并在触及 `0...1` 边界后从另一侧补足跨度。`rateBounds` 必须以 `max((maximum - minimum) * 1.2, abs((minimum + maximum) / 2) * 0.2, 1024)` 为目标跨度，最低值限制为零，并使用 nice step 生成能容纳数据的两个刻度区间。`rateLabels` 根据上界统一选择单位，不逐个刻度选择单位。

- [ ] **步骤 5：运行模型测试并确认通过**

运行：`swift test --filter SparklineAxisPresentationTests`

预期：所有新增测试 PASS。

- [ ] **步骤 6：提交动态坐标模型**

```bash
git add Sources/MacResourceMonitor/UI/SparklineAxisPresentation.swift Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift
git commit -m "feat: 添加折线图动态纵轴模型"
```

### 任务 2：在四张趋势图中渲染纵坐标

**文件：**
- 修改：`Sources/MacResourceMonitor/UI/SparklineView.swift`
- 修改：`Sources/MacResourceMonitor/UI/MetricCardView.swift`
- 修改：`Sources/MacResourceMonitor/UI/DashboardView.swift`
- 修改：`Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift`

- [ ] **步骤 1：编写指标样式映射失败测试**

```swift
func testMetricStylesUseExpectedAxisKinds() {
    XCTAssertEqual(SparklineStyle.cpu.axisKind, .percentage)
    XCTAssertEqual(SparklineStyle.memory.axisKind, .percentage)
    XCTAssertEqual(SparklineStyle.upload.axisKind, .rate)
    XCTAssertEqual(SparklineStyle.download.axisKind, .rate)
}
```

- [ ] **步骤 2：运行测试并确认因为样式类型尚不存在而失败**

运行：`swift test --filter SparklineAxisPresentationTests/testMetricStylesUseExpectedAxisKinds`

预期：FAIL，编译器报告找不到 `SparklineStyle`。

- [ ] **步骤 3：为折线图增加样式与显式纵轴**

在 `SparklineView.swift` 中定义样式，并让视图接收样式而非固定范围：

```swift
enum SparklineStyle {
    case cpu, memory, upload, download

    var axisKind: SparklineAxisKind {
        switch self {
        case .cpu, .memory: return .percentage
        case .upload, .download: return .rate
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .purple
        case .upload: return .orange
        case .download: return .green
        }
    }
}
```

从 `points.compactMap(\.value)` 创建 `SparklineAxisPresentation`。在有数据时使用已由 Context7 核对的 Swift Charts 组合：

```swift
.chartYScale(domain: axis.domain)
.chartYAxis {
    AxisMarks(position: .leading, values: axis.ticks) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(.secondary.opacity(0.18))
        AxisValueLabel {
            if let tick = value.as(Double.self),
               let index = axis.ticks.firstIndex(where: { abs($0 - tick) < 0.000_001 }) {
                Text(axis.labels[index])
            }
        }
    }
}
```

将线和单点的 `.foregroundStyle` 改为 `style.tint`，图表高度由 40 pt 增加到 64 pt。继续隐藏 X 轴、保留五分钟 X 轴范围与断线分段逻辑，并给辅助功能标签加入指标名称和纵轴范围。

- [ ] **步骤 4：把样式从详情面板传到折线图**

将 `MetricCardView` 的 `fixedRange` 替换为必需的 `sparklineStyle`（只有存在 `points` 时使用）。在 `DashboardView` 中传入：

```swift
MetricCardView(..., points: store.history.cpu.elements, sparklineStyle: .cpu)
MetricCardView(..., points: store.history.memory.elements, sparklineStyle: .memory)
MetricCardView(..., points: store.history.upload.elements, sparklineStyle: .upload)
MetricCardView(..., points: store.history.download.elements, sparklineStyle: .download)
```

- [ ] **步骤 5：运行测试与 Debug 构建**

运行：`swift test && swift build`

预期：全部测试 PASS，应用编译成功；不再存在 `fixedRange` 或 `.chartYAxis(.hidden)`。

- [ ] **步骤 6：运行应用进行视觉检查**

运行：`swift run MacResourceMonitor`

检查：四张图均显示三档纵轴；CPU 低负载时曲线起伏明显；文字不被裁切；浅色与深色模式下网格、坐标和曲线清晰；关闭应用后终止本次调试进程。

- [ ] **步骤 7：提交折线图界面**

```bash
git add Sources/MacResourceMonitor/UI/SparklineView.swift Sources/MacResourceMonitor/UI/MetricCardView.swift Sources/MacResourceMonitor/UI/DashboardView.swift Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift
git commit -m "feat: 显示动态折线图纵坐标"
```

### 任务 3：生成并打包应用图标

**文件：**
- 创建：`Resources/AppIcon-1024.png`
- 创建：`Resources/AppIcon.icns`
- 创建：`scripts/build-icon.sh`
- 修改：`Resources/Info.plist`
- 修改：`scripts/build-app.sh`
- 修改：`scripts/verify-release.sh`

- [ ] **步骤 1：先让发布验证要求图标并确认当前产物失败**

在 `check_app` 中加入：

```bash
local icon_name
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" || fail "missing CFBundleIconFile: $bundle"
[[ "$icon_name" == *.icns ]] || icon_name="$icon_name.icns"
test -f "$bundle/Contents/Resources/$icon_name" || fail "missing application icon: $bundle"
```

运行：`bash scripts/verify-release.sh`

预期：FAIL，报告缺少 `CFBundleIconFile`。

- [ ] **步骤 2：使用 ImageGen 生成已确认的 1024×1024 图标源图**

使用以下提示生成一张不透明背景的正方形位图，并将最终文件保存为 `Resources/AppIcon-1024.png`：

```text
Create a polished macOS utility app icon, 1024 by 1024 pixels. A deep navy rounded-square icon body with subtle dimensional lighting, a restrained low-contrast monitoring grid, and one crisp performance line rising and falling across the center. The line transitions from vivid system blue to fresh green and has a subtle glow. Modern native macOS aesthetic, balanced margins, legible at 16 px, no text, no letters, no numbers, no watermark, no extra objects, no mockup background.
```

检查图标没有文字、水印或画布外背景，缩小到 16×16 后仍能辨认蓝绿折线。

- [ ] **步骤 3：创建可复现的 ICNS 构建脚本**

脚本使用 `mktemp -d` 创建临时 `.iconset`，用 `sips -z` 从源图生成 `16、32、128、256、512` 及对应 `@2x` PNG，再运行：

```bash
iconutil -c icns "$iconset" -o "$repo_root/Resources/AppIcon.icns"
```

脚本开始时验证源图尺寸为 1024×1024，结束时验证 ICNS 非空，并用 `trap` 清理临时目录。

- [ ] **步骤 4：生成 ICNS 并声明应用图标**

运行：`bash scripts/build-icon.sh`

在 `Resources/Info.plist` 中加入：

```xml
<key>CFBundleIconFile</key>
<string>AppIcon.icns</string>
```

在 `scripts/build-app.sh` 的 Info.plist 复制操作后加入：

```bash
cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
```

- [ ] **步骤 5：构建应用并确认图标验证通过**

运行：`bash scripts/build-app.sh && bash scripts/build-dmg.sh && bash scripts/verify-release.sh`

预期：应用包与 DMG 校验成功；两处 `MacResourceMonitor.app/Contents/Resources/AppIcon.icns` 均存在，且 `CFBundleIconFile` 指向该文件。

- [ ] **步骤 6：提交图标和打包改动**

```bash
git add Resources/AppIcon-1024.png Resources/AppIcon.icns Resources/Info.plist scripts/build-icon.sh scripts/build-app.sh scripts/verify-release.sh
git commit -m "feat: 添加应用图标"
```

### 任务 4：完整回归与交付新版 DMG

**文件：**
- 修改：`docs/verification/2026-10-01-release-checklist.md`

- [ ] **步骤 1：更新发布检查记录**

在检查表中增加：应用图标源图为 1024×1024、ICNS 已进入应用包、Finder/应用信息显示图标、四张趋势图存在动态三档纵轴、CPU 低负载波动可辨认。

- [ ] **步骤 2：运行完整自动化验证**

运行：

```bash
swift test
swift build -c release --arch arm64
git diff --check
```

预期：全部测试 PASS，arm64 Release 构建成功，Git 差异没有空白错误。

- [ ] **步骤 3：从干净产物重建并验证 DMG**

运行：

```bash
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
```

预期：生成并验证 `dist/MacResourceMonitor.dmg`；应用继续使用 ad-hoc 签名，最低版本仍为 macOS 13，二进制仍为 arm64，DMG 仍包含 Applications 快捷方式与安装说明。

- [ ] **步骤 4：真机最终检查**

从 `dist/MacResourceMonitor.app` 启动应用，检查菜单栏仍不显示时间和 Dock 图标；点击菜单栏后四张趋势图、温度、风扇和磁盘容量均存在；CPU 低负载变化清晰；退出应用后确认没有残留进程。

- [ ] **步骤 5：提交发布检查记录**

```bash
git add docs/verification/2026-10-01-release-checklist.md
git commit -m "docs: 记录图标和动态纵轴发布验证"
```

- [ ] **步骤 6：检查最终状态**

运行：`git status -sb && git log -5 --oneline`

预期：工作树干净，当前功能分支包含设计文档、实现计划和三个实现提交；`build/` 与 `dist/` 均未被跟踪。

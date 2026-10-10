# 折线图刻度参考线与悬停数据实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为 CPU、内存、上传和下载趋势图增加清晰的纵轴水平参考线，并在鼠标悬停时显示最近真实采样点的时间和值。

**架构：** 使用独立的 `SparklineHoverSelection` 值类型承载最近点选择和提示文本格式化，使核心行为可以脱离 SwiftUI 单元测试。`SparklineView` 继续负责 Swift Charts 绘制，通过 `chartOverlay`、`ChartProxy` 和 macOS 13 的 `onContinuousHover` 更新选择，并将竖向指示线、高亮点和边界受控的提示框叠加在现有趋势图上。

**技术栈：** Swift 5.9、SwiftUI、Swift Charts、XCTest、macOS 13+

---

## 文件结构

- 创建 `Sources/MacResourceMonitor/UI/SparklineHoverSelection.swift`：选择距离目标时间最近的有效真实采样点，并生成悬停时间和值文案。
- 创建 `Tests/MacResourceMonitorTests/SparklineHoverSelectionTests.swift`：覆盖最近点、边界、无效数据、断点数据和两类数值格式。
- 修改 `Sources/MacResourceMonitor/UI/SparklineView.swift`：增强纵轴参考线，接入连续悬停，绘制指示线、高亮点和提示框。

### 任务 1：实现可测试的悬停数据选择与格式化

**文件：**
- 创建：`Sources/MacResourceMonitor/UI/SparklineHoverSelection.swift`
- 创建：`Tests/MacResourceMonitorTests/SparklineHoverSelectionTests.swift`

- [ ] **步骤 1：编写最近点和边界行为的失败测试**

```swift
import XCTest
@testable import MacResourceMonitor

final class SparklineHoverSelectionTests: XCTestCase {
    func testSelectsNearestFinitePointAndUsesLaterPointForTie() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.2),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 20), value: nil),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 0.4),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 40), value: .nan)
        ]

        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 20),
            points: points
        ))

        XCTAssertEqual(selection.timestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(selection.value, 0.4)
    }

    func testTargetsOutsideRangeSelectBoundaryPoints() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 3)
        ]

        XCTAssertEqual(
            SparklineHoverSelection(nearestTo: Date(timeIntervalSince1970: 0), points: points)?.timestamp,
            Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            SparklineHoverSelection(nearestTo: Date(timeIntervalSince1970: 50), points: points)?.timestamp,
            Date(timeIntervalSince1970: 30)
        )
    }

    func testEmptyAndInvalidPointsProduceNoSelection() {
        XCTAssertNil(SparklineHoverSelection(nearestTo: Date(), points: []))
        XCTAssertNil(SparklineHoverSelection(
            nearestTo: Date(),
            points: [HistoryPoint(timestamp: Date(), value: nil),
                     HistoryPoint(timestamp: Date(), value: .infinity)]
        ))
    }

    func testSegmentBoundaryStillReturnsAnActualSample() throws {
        let points = [
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.2),
            HistoryPoint(timestamp: Date(timeIntervalSince1970: 30), value: 0.8, startsNewSegment: true)
        ]
        let selection = try XCTUnwrap(SparklineHoverSelection(
            nearestTo: Date(timeIntervalSince1970: 20),
            points: points
        ))

        XCTAssertEqual(selection.timestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(selection.value, 0.8)
    }
}
```

- [ ] **步骤 2：运行目标测试并确认因类型不存在而失败**

运行：

```bash
swift test --filter SparklineHoverSelectionTests
```

预期：编译失败，报告找不到 `SparklineHoverSelection`。

- [ ] **步骤 3：实现最近有效真实采样点选择**

```swift
import Foundation

struct SparklineHoverSelection: Equatable {
    let timestamp: Date
    let value: Double

    init?(nearestTo target: Date, points: [HistoryPoint]) {
        let candidates = points.compactMap { point -> (Date, Double)? in
            guard let value = point.value, value.isFinite else { return nil }
            return (point.timestamp, value)
        }
        var nearest: (Date, Double)?
        for candidate in candidates {
            guard let current = nearest else {
                nearest = candidate
                continue
            }
            let candidateDistance = abs(candidate.0.timeIntervalSince(target))
            let currentDistance = abs(current.0.timeIntervalSince(target))
            if candidateDistance < currentDistance
                || (candidateDistance == currentDistance && candidate.0 > current.0) {
                nearest = candidate
            }
        }
        guard let nearest else { return nil }
        timestamp = nearest.0
        value = nearest.1
    }
}
```

- [ ] **步骤 4：运行目标测试并确认最近点行为通过**

运行：

```bash
swift test --filter SparklineHoverSelectionTests
```

预期：4 个测试通过。

- [ ] **步骤 5：编写提示文本格式的失败测试**

将以下测试加入 `SparklineHoverSelectionTests`：

```swift
func testFormatsPercentageAndRateValues() throws {
    let selection = try XCTUnwrap(SparklineHoverSelection(
        nearestTo: Date(timeIntervalSince1970: 10),
        points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 0.237)]
    ))
    XCTAssertEqual(selection.valueLabel(for: .percentage), "24%")

    let rate = try XCTUnwrap(SparklineHoverSelection(
        nearestTo: Date(timeIntervalSince1970: 10),
        points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1_250_000)]
    ))
    XCTAssertEqual(rate.valueLabel(for: .rate), "1.3 MB/s")
}

func testFormatsRelativeTimeWithoutInventingFutureElapsedTime() throws {
    let selection = try XCTUnwrap(SparklineHoverSelection(
        nearestTo: Date(timeIntervalSince1970: 10),
        points: [HistoryPoint(timestamp: Date(timeIntervalSince1970: 10), value: 1)]
    ))
    XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 10)), "现在")
    XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 55)), "45 秒前")
    XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 70)), "1 分钟前")
    XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 75)), "1 分 5 秒前")
    XCTAssertEqual(selection.timeLabel(relativeTo: Date(timeIntervalSince1970: 5)), "现在")
}
```

- [ ] **步骤 6：运行目标测试并确认因格式化方法不存在而失败**

运行：

```bash
swift test --filter SparklineHoverSelectionTests
```

预期：编译失败，报告缺少 `valueLabel(for:)` 和 `timeLabel(relativeTo:)`。

- [ ] **步骤 7：实现数值和相对时间格式化**

在 `SparklineHoverSelection` 中加入：

```swift
func valueLabel(for kind: SparklineAxisKind) -> String {
    switch kind {
    case .percentage: return MetricFormatter.percent(value * 100)
    case .rate: return MetricFormatter.rate(value)
    }
}

func timeLabel(relativeTo referenceDate: Date) -> String {
    let seconds = max(0, Int(referenceDate.timeIntervalSince(timestamp).rounded()))
    guard seconds > 0 else { return "现在" }
    guard seconds >= 60 else { return "\(seconds) 秒前" }
    let minutes = seconds / 60
    let remainder = seconds % 60
    return remainder == 0 ? "\(minutes) 分钟前" : "\(minutes) 分 \(remainder) 秒前"
}
```

- [ ] **步骤 8：运行目标测试并确认全部通过**

运行：

```bash
swift test --filter SparklineHoverSelectionTests
```

预期：6 个测试通过。

- [ ] **步骤 9：提交悬停展示模型**

```bash
git add Sources/MacResourceMonitor/UI/SparklineHoverSelection.swift Tests/MacResourceMonitorTests/SparklineHoverSelectionTests.swift
git commit -m "feat: 添加折线图悬停数据选择"
```

### 任务 2：接入 Swift Charts 悬停交互并增强参考线

**文件：**
- 修改：`Sources/MacResourceMonitor/UI/SparklineView.swift:33-94`

- [ ] **步骤 1：在图表中保存并绘制悬停选择**

在 `SparklineView` 属性中加入：

```swift
@State private var hoverTarget: Date?
```

在 `body` 中创建 `presentation` 后，根据最新的可见采样计算选择，避免每次采样刷新时留下过期值或让静止指针的提示消失：

```swift
let hoverPoints = presentation.segments.flatMap { $0 }
let hoverSelection = hoverTarget.flatMap {
    SparklineHoverSelection(nearestTo: $0, points: hoverPoints)
}
```

在现有分段折线的 `ForEach` 之后加入：

```swift
if let hoverSelection {
    RuleMark(x: .value("悬停时间", hoverSelection.timestamp))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .foregroundStyle(.secondary.opacity(0.55))
    PointMark(
        x: .value("悬停时间", hoverSelection.timestamp),
        y: .value("悬停数值", hoverSelection.value)
    )
    .symbolSize(34)
    .foregroundStyle(style.tint)
}
```

- [ ] **步骤 2：增强所有纵轴刻度的水平参考线**

将现有 `AxisGridLine` 样式调整为：

```swift
AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75))
    .foregroundStyle(.secondary.opacity(0.32))
```

保留 `axis.ticks`、`axis.labels` 和动态 `chartYScale`，不增加固定纵轴范围。

- [ ] **步骤 3：增加连续悬停覆盖层和边界受控提示框**

在 `chartXScale` 后增加 `chartOverlay`。覆盖层使用 `geometry[proxy.plotAreaFrame]` 判断指针是否位于绘图区，使用 `proxy.value(atX:as:)` 将 X 坐标转换为日期，再从 `presentation.segments.flatMap { $0 }` 创建选择：

```swift
.chartOverlay { proxy in
    GeometryReader { geometry in
        let plotFrame = geometry[proxy.plotAreaFrame]
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        guard plotFrame.contains(location),
                              let target = proxy.value(
                                  atX: location.x - plotFrame.minX,
                                  as: Date.self
                              ) else {
                            hoverTarget = nil
                            return
                        }
                        hoverTarget = target
                    case .ended:
                        hoverTarget = nil
                    }
                }

            if let hoverSelection,
               let pointX = proxy.position(forX: hoverSelection.timestamp),
               let pointY = proxy.position(forY: hoverSelection.value) {
                hoverTooltip(for: hoverSelection, referenceDate: presentation.timeDomain.upperBound)
                    .frame(width: 108, alignment: .leading)
                    .position(
                        x: tooltipX(pointX: plotFrame.minX + pointX, plotFrame: plotFrame),
                        y: max(plotFrame.minY + 18, plotFrame.minY + pointY - 22)
                    )
            }
        }
    }
}
```

在 `SparklineView` 中加入以下私有辅助内容，确保提示框在选中点左右切换并保持在绘图区内：

```swift
private let tooltipWidth: CGFloat = 108

private func tooltipX(pointX: CGFloat, plotFrame: CGRect) -> CGFloat {
    let halfWidth = tooltipWidth / 2
    let proposed = pointX <= plotFrame.midX
        ? pointX + halfWidth + 8
        : pointX - halfWidth - 8
    return min(max(proposed, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
}

private func hoverTooltip(for selection: SparklineHoverSelection, referenceDate: Date) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(selection.timeLabel(relativeTo: referenceDate))
            .foregroundStyle(.secondary)
        Text(selection.valueLabel(for: style.axisKind))
            .fontWeight(.medium)
    }
    .font(.caption2)
    .monospacedDigit()
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
}
```

- [ ] **步骤 4：在设置变化时清除悬停目标**

在图表修饰器链中增加：

```swift
.onChange(of: historyDuration) { _ in hoverTarget = nil }
.onChange(of: refreshInterval) { _ in hoverTarget = nil }
```

普通采样刷新不主动清空 `hoverTarget`；`body` 会用新的可见采样重新计算 `hoverSelection`，因此鼠标静止时提示不会闪退，也不会保留已从可见历史中移除的旧采样对象。

- [ ] **步骤 5：构建并修正 Swift Charts API 或布局编译问题**

运行：

```bash
swift build
```

预期：构建成功；若编译器要求 `ChartProxy.value(atX:)` 依赖上下文推断，则保持显式 `as: Date.self`，不得改用仅在 macOS 14 可用的选择 API。

- [ ] **步骤 6：运行完整测试与 arm64 Release 构建**

运行：

```bash
swift test
swift build -c release --arch arm64
```

预期：全部测试通过，arm64 Release 构建成功。

- [ ] **步骤 7：检查代码差异与磁盘监控约束**

运行：

```bash
git diff --check
rg -n "disk.*rate|readBytes|writeBytes|读写速率" Sources Tests
git status --short
```

预期：`git diff --check` 无输出；搜索不出现新增磁盘读写速率实现；状态只包含本计划列出的 Swift 文件。

- [ ] **步骤 8：提交图表交互**

```bash
git add Sources/MacResourceMonitor/UI/SparklineView.swift
git commit -m "feat: 添加折线图刻度参考线与悬停提示"
```

### 任务 3：执行完成前验证

**文件：**
- 验证：`Sources/MacResourceMonitor/UI/SparklineHoverSelection.swift`
- 验证：`Sources/MacResourceMonitor/UI/SparklineView.swift`
- 验证：`Tests/MacResourceMonitorTests/SparklineHoverSelectionTests.swift`

- [ ] **步骤 1：重新运行项目要求的验证命令**

```bash
swift test
swift build -c release --arch arm64
git diff --check
git status -sb
```

预期：测试与 Release 构建成功；差异检查无输出；分支只领先于远端且工作区干净。

- [ ] **步骤 2：检查提交内容**

```bash
git log --oneline -4
git show --stat --oneline HEAD~2..HEAD
```

预期：包含悬停选择模型和图表交互两个功能提交，文件范围与本计划一致。

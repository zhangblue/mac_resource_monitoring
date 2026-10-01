# 任务 1 报告：动态纵轴展示模型

## 实现内容

- 新增纯 Swift `SparklineAxisKind` 与 `SparklineAxisPresentation`，输出纵轴 domain、三个刻度和标签，不触碰采样数据或 SwiftUI 视图。
- 百分比轴围绕数据中心留出 10% 空间，至少保持 0.10 跨度并约束在 0...1；触边时从另一侧补足。
- 速率轴按要求计算目标跨度，使用 `1、2、5 × 10ⁿ` nice step 生成可容纳数据的两段刻度，并按上界统一选择单位。
- 忽略非有限值；无有限样本时返回 nil。

## 修改文件

- `Sources/MacResourceMonitor/UI/SparklineAxisPresentation.swift`
- `Tests/MacResourceMonitorTests/SparklineAxisPresentationTests.swift`

## TDD RED / GREEN

- RED：`CLANG_MODULE_CACHE_PATH=/private/tmp/codex-axis-module-cache swift test --scratch-path /private/tmp/codex-axis-build --filter SparklineAxisPresentationTests`
  - 关键输出：`error: cannot find 'SparklineAxisPresentation' in scope`，确认因目标类型尚不存在而失败。初次未指定临时 scratch 路径的运行被本机缓存目录权限阻止；使用临时 scratch 路径并获准运行后得到预期 RED。
- GREEN：同一聚焦命令在实现后通过，`Executed 6 tests, with 0 failures`。
- 完整回归：`CLANG_MODULE_CACHE_PATH=/private/tmp/codex-axis-module-cache swift test --scratch-path /private/tmp/codex-axis-build`
  - `Executed 88 tests, with 0 failures`。
- `git diff --check` 通过。

## 自审与疑虑

- 自审确认仅新增模型与模型测试；没有改动 SwiftUI、采样频率、历史窗口或底层采样值。
- 无功能疑虑。构建仍报告既有测试中的 `weak var` 未修改警告；测试宿主报告平台为 arm64e macOS 14.0，未单独验证 macOS 13。

## 修复第 1 轮：速率轴两侧留白

- 发现：原下界直接按数据最小值向下对齐，可能令非零基线紧贴坐标轴底边。
- 测试先行：将基线样本下界/上界断言改为严格小于/大于，并新增恒定 8 MB/s 两侧留白测试。
- RED 命令：`CLANG_MODULE_CACHE_PATH=/private/tmp/codex-axis-module-cache swift test --scratch-path /private/tmp/codex-axis-build --filter SparklineAxisPresentationTests`
  - 关键输出：`XCTAssertLessThan failed: ("8000000.0") is not less than ("8000000.0")`；两项留白测试失败，其余测试通过。
- 实现：先按目标跨度对样本范围两侧扩展，再对扩展后的下界执行 nice-step 刻度对齐；若对齐后的上界不足以容纳扩展区间，则增大步长。
- GREEN 聚焦命令同 RED；关键输出：`Executed 7 tests, with 0 failures`。
- 完整命令：`CLANG_MODULE_CACHE_PATH=/private/tmp/codex-axis-module-cache swift test --scratch-path /private/tmp/codex-axis-build`
  - 关键输出：`Executed 89 tests, with 0 failures`。
- `git diff --check` 通过。

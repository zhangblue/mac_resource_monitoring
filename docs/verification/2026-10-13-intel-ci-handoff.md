# Intel CI 本地交接（MRM-INTEL-11-I）

本轮只在 `feature/intel-support` 本地新增 `.github/workflows/intel-ci.yml` 及静态契约测试；未推送、未运行 GitHub Actions，亦未创建 tag/Release、安装应用或修改真实登录项。

## 触发及权限

- 唯一触发条件为推送 `ci/intel-validation` 分支。推送 `feature/intel-support`、`v*` tag、PR 和手动 dispatch 均不触发此工作流。`workflow_dispatch` 要求文件先位于默认分支，因此不使用它作为首轮验证入口。
- 单一 `macos-15-intel` job，`contents: read`。先 checkout，再打印 `GITHUB_SHA` 并比对 checkout 的 `HEAD`，检查 `uname -m` 为 `x86_64`，打印 `sw_vers` 与 Swift 版本。之后运行 workflow 静态测试、`swift test`、`swift build -c release --arch x86_64`，并用 `lipo -archs` 校验生成的可执行文件恰为薄 `x86_64`。
- 不上传 artifact、不构建 DMG、不安装、不调用发布脚本或创建 Release；现有 `.github/workflows/release.yml` 未改动。

## 本地证据与待验

- 静态测试先因缺少新工作流失败，新增工作流后 20 项 Python 工作流测试通过；既有 `python3 Tests/scripts/check-release-workflow.py` 通过。新契约测试拒绝额外 trigger、错误 runner/权限、发布或上传步骤，以及移除关键验证命令。
- 本机 `swift test` 为 155 项、0 失败；`swift build -c release --arch x86_64` 退出 0，本机构建的可执行文件 `lipo -archs` 为 `x86_64`。这是 Apple Silicon 本机交叉构建证据，不是 Intel runner 上的测试运行。
- **待分别批准**：首先推送 `feature/intel-support`（不会触发此工作流）；之后单独批准推送**同一 commit** 到 `ci/intel-validation`（该 push 将自动触发 GitHub Intel CI），核对 run 的 SHA、host 架构、测试及构建日志。请在第二次批准前核实 GitHub Intel runner 可用性及预算/配额；本任务未开启新持续费用承诺。
- GitHub Intel runner 尚未运行。真实 Intel Mac 上的 SMC 温度/风扇候选键与 GUI、菜单栏、登录项、睡眠唤醒等仍未验收；CI 即使通过也不能替代真机人工验收。参见 `2026-10-01-release-checklist.md` 的 Intel universal 发布门禁。

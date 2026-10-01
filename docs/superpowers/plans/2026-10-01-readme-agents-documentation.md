# README 与 AGENTS 文档实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 创建面向使用者和开发者的 `README.md`，以及约束后续开发代理的仓库级 `AGENTS.md`。

**架构：** README 作为项目入口，引用现有 `INSTALL.md` 并直接给出经过验证的 SwiftPM 与发布脚本命令。AGENTS 只记录稳定的产品边界、目录职责、工程命令和验证规则，不重复实现细节。

**技术栈：** Markdown、Swift Package Manager、Bash、XCTest、macOS `hdiutil` 与 `codesign`

---

## 文件结构

- 创建：`README.md` —— 项目介绍、功能、安装、编译、运行、测试和打包入口。
- 创建：`AGENTS.md` —— 仓库级开发代理说明及不可破坏的产品约束。

### 任务 1：创建并验证项目入口文档

**文件：**
- 创建：`README.md`
- 创建：`AGENTS.md`

- [ ] **步骤 1：记录文档创建前的失败检查**

运行：

```bash
test -f README.md
test -f AGENTS.md
```

预期：两个检查均失败，因为文件尚未创建。

- [ ] **步骤 2：创建 README.md**

README 按以下顺序编写：

1. 标题与一句话介绍。
2. 当前功能清单；明确磁盘只统计系统启动卷已用/总容量，不显示读写速率。
3. 系统要求：Apple Silicon、macOS 13+、源码构建需要完整 Xcode 并同意许可证。
4. DMG 安装与首次右键打开，链接 `INSTALL.md`。
5. 源码运行命令：`swift run MacResourceMonitor`。
6. 编译命令：`swift build`、`swift build -c release --arch arm64` 和 `bash scripts/build-app.sh`，说明应用输出为 `dist/MacResourceMonitor.app`。
7. 测试命令：`swift test`。
8. DMG 构建与校验：依次运行 `build-app.sh`、`build-dmg.sh`、`verify-release.sh`，输出为 `dist/MacResourceMonitor.dmg`。
9. 项目结构、ad-hoc 签名及未公证说明。

- [ ] **步骤 3：创建 AGENTS.md**

AGENTS 包含以下可执行约束：

- 首版仅支持 Apple Silicon 和 macOS 13+；后续 Intel 支持不能破坏 arm64 路径。
- 应用是 `LSUIElement` 菜单栏应用，不得新增常驻 Dock 图标。
- 菜单栏只显示 CPU、内存、上传、下载；面板包含趋势、温度、风扇和启动卷容量。
- 磁盘保持 capacity-only，不得恢复读写速率字段、采集器或 UI。
- 保持每秒采样、300 点历史、单项失败隔离和睡眠唤醒后网络基线重置。
- 说明 `Sources/`、`Tests/`、`Resources/`、`scripts/` 和 `docs/` 的职责。
- 代码修改至少运行 `swift test` 与 `swift build -c release --arch arm64`。
- 发布修改需运行三个发布脚本；不提交 `build/`、`dist/`，不擅自写入 `/Applications` 或切换真实登录项。

- [ ] **步骤 4：验证内容和命令一致性**

运行：

```bash
test -f README.md
test -f AGENTS.md
rg -n "swift run MacResourceMonitor|swift build -c release --arch arm64|swift test|scripts/build-app.sh|scripts/build-dmg.sh|scripts/verify-release.sh" README.md AGENTS.md
rg -n "磁盘.*(容量|已用|总容量)|capacity-only|读写速率" README.md AGENTS.md
git diff --check
```

预期：文件存在；所有实际命令均可找到；两个文档都明确磁盘容量范围；空白检查通过。

- [ ] **步骤 5：运行完整测试与 Release 构建**

运行：

```bash
swift test
swift build -c release --arch arm64
```

预期：82 项 XCTest 全部通过，Release 构建成功。现有测试源文件可能报告弱引用变量可改为常量的提示，但不得出现错误或测试失败。

- [ ] **步骤 6：提交文档**

```bash
git add README.md AGENTS.md
git commit -m "docs: 添加项目说明和开发指南"
```

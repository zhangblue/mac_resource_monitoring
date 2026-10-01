# README 与 AGENTS 文档设计

## 目标

为 Mac Resource Monitor 增加两份入口文档，使普通用户能够了解、安装和运行应用，使开发者或自动化代理能够安全地继续维护项目。

## README.md

README 面向使用者和开发者，采用中文编写，包含：

- 项目定位及当前支持范围：Apple Silicon、macOS 13 及以上、菜单栏应用。
- 功能清单：CPU、内存、网络上传下载、温度、风扇、五分钟趋势和启动卷容量；明确磁盘不统计读写速率。
- 环境要求：完整 Xcode、已同意 Xcode 许可证、Swift Package Manager。
- DMG 安装与首次运行说明，并链接 `INSTALL.md`。
- 源码调试运行：`swift run MacResourceMonitor`。
- Release 编译：优先使用 `scripts/build-app.sh`，同时说明输出目录。
- 测试、DMG 构建及发布验证命令。
- 项目目录概览、签名与公证限制。

命令必须与仓库现有脚本一致，不添加项目中不存在的依赖或流程。

## AGENTS.md

AGENTS 面向后续开发代理，作为仓库级工作约束，包含：

- 产品范围与不可破坏的行为：纯菜单栏、无 Dock 图标、Apple Silicon 首版、磁盘 capacity-only。
- 关键目录及模块职责。
- 构建、测试、运行、打包和验证命令。
- 修改原则：保持单项采集失败隔离、睡眠唤醒基线、300 点历史、ad-hoc 签名与安装说明一致性。
- 验证要求：代码修改至少运行 `swift test` 和 Release 构建；发布相关修改还需完整重建并验证 DMG。
- 安全要求：不擅自安装到 `/Applications`、不修改登录项、不把 `build/` 和 `dist/` 纳入 Git。

## 验证

- 检查两个文件存在、Markdown 标题和本地链接有效。
- 检查文档中的命令与 `Package.swift`、`scripts/` 和 `INSTALL.md` 一致。
- 运行 `git diff --check`。
- 运行 `swift test`，确认文档变更没有破坏项目状态。

## 范围外

- 不修改应用功能、界面、构建脚本或安装行为。
- 不新增 Intel 支持、Developer ID 签名或 Apple 公证流程。

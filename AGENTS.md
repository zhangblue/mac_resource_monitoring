# 仓库代理指南

## 产品与兼容性约束

- 首版仅支持 Apple Silicon 和 macOS 13 及以上版本。后续若增加 Intel 支持，必须保留并验证 arm64 构建路径。
- 应用通过 `LSUIElement` 作为纯菜单栏应用运行，不得新增常驻 Dock 图标。
- 菜单栏只显示 CPU、内存、上传和下载；详情面板必须保留趋势、温度、风扇和系统启动卷容量。
- 磁盘监控保持 capacity-only：只提供系统启动卷已用容量和总容量。不得增加或恢复磁盘读写速率字段、采集器或 UI。
- 保持每秒采样和 300 点趋势历史。CPU、内存、网络、磁盘或传感器中单项采集失败时，应隔离该项失败，不中断其余指标。
- 睡眠唤醒后必须重置 CPU 与网络速率基线，避免跨越睡眠时间计算速率。

## 目录职责

- `Sources/`：应用入口、指标模型、监控协调、系统采集提供器及用户界面。功能实现应放在对应模块中。
- `Tests/`：Swift 测试。新增或修改行为时，应在相应测试中覆盖。
- `Resources/`：应用包资源和 `Info.plist`。保持最低系统版本、菜单栏应用属性与产品支持范围一致。
- `scripts/`：构建应用包、制作 DMG 和验证发布产物的脚本。命令和输出路径以这些脚本为准。
- `docs/`：设计说明、实施计划与发布校验资料。产品行为变化时同步更新相关文档。

## 开发与验证

- 在仓库根目录运行应用：`swift run MacResourceMonitor`。
- 常规构建：`swift build`。
- 每次代码修改至少运行 `swift test` 和 `swift build -c release --arch arm64`。
- 涉及发布产物、应用包元数据或打包脚本的修改，依次运行 `bash scripts/build-app.sh`、`bash scripts/build-dmg.sh` 和 `bash scripts/verify-release.sh`。
- 发布仍使用 ad-hoc 签名且未经公证；不要在文档中声称已公证或要求关闭 Gatekeeper。

## 工作区安全

- 不要将 `build/` 或 `dist/` 生成物加入版本控制。
- 不要擅自把应用写入 `/Applications`，也不要擅自更改真实登录项。需要验证安装时，优先检查仓库内构建产物和 DMG 内容。
- 修改安装或首次启动说明时，保持 `README.md`、`INSTALL.md` 与实际脚本行为一致。

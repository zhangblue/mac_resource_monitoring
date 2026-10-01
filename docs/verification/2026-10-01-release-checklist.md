# Mac Resource Monitor 1.0 发布验收记录

验收日期：2026-10-01

测试机：Mac mini（Mac16,11，Apple M4 Pro，24 GB 内存）

系统：macOS 15.7.9（arm64）

范围：Apple Silicon、macOS 13 或更高版本、菜单栏应用、ad-hoc 签名且未公证。

## 结论摘要

- **已验证**：arm64 Release 构建、应用包结构、ad-hoc 签名、DMG 完整性及只读挂载内容、应用启动冒烟检查、严格并发同源监控及采样边界 harness、磁盘容量同源 harness、根卷容量读取和磁盘 capacity-only 展示逻辑。采样边界验证包含真实 Mach 端口引用计数，以及模拟工作区睡眠/唤醒通知。
- **受环境限制**：当前仅安装 Command Line Tools，测试目标缺少 `XCTest` 模块；`swift test` 已实际执行但无法编译测试目标，因此不能记为通过。
- **未验证**：真实拖入 `/Applications` 的完整安装/卸载流程、首次右键打开及 Gatekeeper 提示、登录项开关、界面视觉与 Dock 状态、高负载/下载/大文件复制、睡眠唤醒和网络接口切换。发布前应在目标 Mac 上补做这些交互场景。

## 自动化与构建验证

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| XCTest 测试套件 | **受环境限制** | `swift test --disable-sandbox` 退出 1；`Tests/MacResourceMonitorTests/DomainTests.swift:1:8` 报 `no such module 'XCTest'`。没有将此项记为通过。 |
| 监控引擎同源 harness | **已验证** | 以 `-strict-concurrency=complete -warnings-as-errors` 编译并运行，输出 `PASS: monitoring lifecycle and diagnostic logging scenarios`。覆盖采样生命周期、失败隔离、历史与诊断日志场景。 |
| 磁盘容量同源 harness | **已验证** | 以严格并发模式编译并运行，输出 `PASS: disk capacity conversion, live root volume, presentation, progress bounds and menu bar`。包含真实根卷容量读取、数值边界、容量进度和菜单栏四项文本。 |
| 采样边界同源 harness | **已验证** | `SamplingBoundaryTests.swift` 以 `-DSAMPLING_BOUNDARY_HARNESS -strict-concurrency=complete -warnings-as-errors` 编译并运行，输出 `PASS: sampling boundary checks`。CPU、内存各 100 次真实采样前后 host send-right 引用数均为 `1 -> 1`；修复前分别增长 100。 |
| 睡眠通知和并发边界 | **已验证（模拟通知）** | 同源 harness 发送 `NSWorkspace` 睡眠/唤醒通知：2 秒短睡眠后首次网络采样为 `—`、第二次恢复 100 B/s 下载和 20 B/s 上传；跨睡眠在途读取被丢弃，睡中采样不进入历史，单独唤醒通知也重置基线，engine 释放后观察者对象释放。未令测试机实际睡眠。 |
| 折线采样空档 | **已验证（逻辑）** | 120 秒空档分成两段；1.8 秒抖动和恰好 3 秒间隔保持连续；3.001 秒、重复/倒退时间戳和不可用点断线。修复前 120 秒空档检查失败。 |
| arm64 Release 构建 | **已验证** | `swift build -c release --arch arm64 --disable-sandbox` 退出 0，输出 `Build complete!`。 |
| 应用包构建 | **已验证** | `bash scripts/build-app.sh` 退出 0；可执行文件为 thin arm64 Mach-O。 |
| 应用元数据 | **已验证** | 发布验证脚本核对 bundle ID `com.local.MacResourceMonitor`、版本 `1.0 (1)`、最低系统 `13.0`、`LSUIElement=true` 和可执行文件名。 |
| 应用签名 | **已验证** | `codesign --verify --deep --strict` 通过；`codesign -dv` 显示 `Signature=adhoc`。未声称 Developer ID 签名或 Apple 公证。 |
| DMG 构建 | **已验证** | `bash scripts/build-dmg.sh` 在允许使用 macOS 磁盘映像设备的受控环境中退出 0。默认受限沙箱会报 `hdiutil: create failed - 设备未配置`，属于设备访问限制。 |
| DMG 内容与完整性 | **已验证** | `bash scripts/verify-release.sh` 退出 0；校验和有效，只读挂载后检查了镜像内应用、arm64、签名、`Applications -> /Applications` 链接和 `INSTALL.md`，并完成卸载清理。 |
| 应用启动冒烟检查 | **已验证** | 从 `dist/MacResourceMonitor.app` 启动后进程保持运行；检查完成后已结束进程。此项不代表界面视觉或指标准确性已经验收。 |
| Git 空白与生成物忽略 | **已验证** | `git diff --check` 通过；`build/`、`dist/` 由 `.gitignore` 忽略，DMG 不纳入版本控制。 |

## 功能验收状态

| 场景 | 状态 | 说明 |
| --- | --- | --- |
| 菜单栏显示 CPU、内存、上传、下载四项 | **已验证（逻辑）/未验证（视觉）** | capacity harness 核对四项文案；尚未人工查看真实菜单栏宽度、刷新和布局。 |
| 点击菜单栏后显示总览和五分钟折线 | **未验证** | 源码已构建，未完成人工界面操作和视觉核对。 |
| 磁盘仅显示系统启动卷已用/总容量 | **已验证（逻辑）/未验证（视觉）** | 同源 harness 核对真实根卷读取、capacity-only 文案和进度边界；源码及最终规格没有磁盘读写速率字段或界面。尚未人工查看卡片。 |
| 芯片温度、风扇转速及无风扇降级 | **未验证（本轮真机交互）** | 生产代码已构建；本轮未在面板中观察真实传感器数值，也未在无风扇设备上验证。 |
| 单项采集失败不阻断其他指标 | **已验证（同源 harness）** | 监控 harness 覆盖 provider 错误隔离和诊断日志；尚未通过真机故障注入观察界面。 |
| 空闲、高 CPU 场景趋势方向 | **未验证** | 未制造高负载，避免影响用户当前工作。 |
| 网络下载、接口切换及速率恢复 | **未验证** | 未发起下载，也未切换网络接口。 |
| 大文件复制 | **未验证** | 用户已取消磁盘读写速率功能；磁盘只验收容量，因此无需以复制场景验证读写速率。 |
| 睡眠/唤醒后第二次采样恢复速率 | **已验证（模拟通知）/未验证（真机睡眠）** | 同源 harness 验证通知驱动的基线重置、在途采样隔离及第二次速率恢复；未控制测试机真实睡眠/唤醒或人工查看界面。 |
| 无 Dock 图标 | **已验证（配置）/未验证（视觉）** | `Info.plist` 的 `LSUIElement=true` 已验证；尚未人工观察 Dock。 |
| “登录时自动启动”开启、关闭和重启 | **未验证** | 未修改用户登录项。设置名称已与 `INSTALL.md` 核对一致。 |

## 安装生命周期

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| DMG 内应用、Applications 链接和安装说明 | **已验证** | 发布脚本以只读方式挂载并检查。 |
| 拖入 `/Applications` | **未验证** | 未擅自写入系统应用目录。 |
| 首次右键“打开”及系统安全提示 | **未验证** | 未执行真实首次安装，具体 Gatekeeper 提示可能随 macOS 版本变化。 |
| 退出、重新启动、卸载 | **未验证（完整安装流程）** | 仅对 `dist` 中应用做过启动/结束进程冒烟检查。 |
| 安装说明与实现一致性 | **已验证（静态核对）** | `INSTALL.md` 使用实际设置名“登录时自动启动”，说明菜单栏入口、未公证状态和卸载顺序；不要求关闭 Gatekeeper。 |

## 交付物

- DMG：`/Users/zhangdi/works/workspace/github/mac_resource_monitoring/.worktrees/mac-resource-monitor/dist/MacResourceMonitor.dmg`
- 大小：423230 bytes（约 413.3 KiB，本次修复后构建）
- SHA-256：`353004f25347d1a8d8a013c173ee43e74f826531e51359484cfa7c6504214d6c`
- 签名：ad-hoc
- 公证：未公证

## 发布前人工补验建议

1. 按 `INSTALL.md` 从 DMG 拖入 `/Applications`，完成首次右键打开。
2. 人工核对菜单栏四项、面板折线、温度、风扇和磁盘容量卡片；确认 Dock 无图标。
3. 开关“登录时自动启动”，重启登录会话确认行为，再关闭该选项。
4. 分别观察空闲、高 CPU、网络下载、网络接口切换和睡眠唤醒场景；不再验收磁盘读写速率。
5. 退出应用并删除 `/Applications/MacResourceMonitor.app`，确认卸载说明可执行。

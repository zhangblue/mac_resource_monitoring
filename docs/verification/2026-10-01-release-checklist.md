# Mac Resource Monitor 1.0 发布验收记录

验收日期：2026-10-01；图标与动态纵轴、监控设置回归：2026-10-02；进程 Top 5、nettop 卡死与固定排行高度回归：2026-10-17

测试机：Mac mini（Mac16,11，Apple M4 Pro，24 GB 内存）

系统：macOS 15.7.9（arm64）

范围：Apple Silicon、macOS 13 或更高版本、菜单栏应用、ad-hoc 签名且未公证。

## 结论摘要

- **已验证**：完整 XCTest 测试套件、arm64 Release 构建、应用包结构、ad-hoc 签名、DMG 完整性及只读挂载内容、应用启动冒烟检查、严格并发同源监控及采样边界 harness、磁盘容量同源 harness、根卷容量读取和磁盘 capacity-only 展示逻辑。采样边界验证包含真实 Mach 端口引用计数，以及模拟工作区睡眠/唤醒通知。
- **测试工具链**：Xcode 26.3（Build 17C529）、Apple Swift 6.2.4；2026-10-17 在 nettop 卡死修复工作树重新执行 `swift test`，共 188 项 XCTest，0 失败，退出 0；生产 runner 连续完成 300 次真实 `nettop` 采样，详见本轮回归表。
- **未验证**：真实拖入 `/Applications` 的完整安装/卸载流程、首次右键打开及 Gatekeeper 提示、登录项开关、监控设置真机交互与重启保留、界面视觉与 Dock 状态、高负载/下载/大文件复制、睡眠唤醒和网络接口切换。发布前应在目标 Mac 上补做这些交互场景。

## 自动化与构建验证

### 2026-10-17 nettop 卡死与固定排行高度回归

本轮在 `codex/fix-nettop-freeze-fixed-rows` 工作树验证；以下记录不替代历史发布产物校验，未重建 DMG。

| 项目 | 状态 | 本轮证据 |
| --- | --- | --- |
| 现场根因 | **已确认** | 对旧运行版本执行线程采样时，后台线程持续停在 `NetTopExecution.collect()` 调用的 `Process.waitUntilExit()`，同时该应用已经没有 `nettop` 子进程；说明子进程退出后，脱离适当 RunLoop 的同步等待仍可能不返回，并阻塞等待全部 provider 的采样轮次。 |
| 生命周期修复 | **已验证（自动化）** | 生产代码在 `process.run()` 前注册 `terminationHandler`，用一次性 async 闩锁覆盖“先退出”和“先等待”两种时序；runner 独占 800 ms watchdog，超时/取消/输出超限先发送 TERM，短宽限后仅对仍运行且 PID 有效的同一进程发送 KILL。13 项聚焦测试覆盖双管道 EOF、首个错误保留、强制结束、取消清理和立即重启；生产源码不再调用 `waitUntilExit()`。 |
| 完整测试 | **已验证** | `swift test` 退出 0；188 项 XCTest，0 失败、0 unexpected，约 16.04 秒。编译期间仍存在既有测试代码的 `weak` 变量可改为常量提示，不影响结果。 |
| arm64 Release 构建 | **已验证** | `swift build -c release --arch arm64` 退出 0，输出 `Build complete!`。 |
| 真实 `nettop` 持续采集 | **已验证（本机）** | 临时验证夹具使用生产 `FoundationNetTopCommandRunner` 连续执行固定命令 300 次：300 成功、0 失败，单次最长约 21.43 ms，每次均低于 2 秒；夹具随后删除，结束后无遗留 `nettop` 子进程。 |
| 应用持续运行 | **已验证（进程与线程）/未验证（面板视觉）** | 从本工作树启动裸可执行文件并持续运行 5 分 9 秒；结束前线程采样未出现 `waitUntilExit()`，并捕获到正常的 `NetTopExecution.launch/read` 采样活动。结束仅由本轮启动的 PID 后，应用和 `nettop` 均无遗留。界面工具不能连接裸可执行文件，因此不据此声称菜单栏数值或面板视觉通过。 |
| 排行卡固定高度 | **已验证（自动渲染）/未验证（真实弹窗视觉）** | presentation 对 0/1/3/5 项及等待、不可用状态始终生成 5 个槽位；真实行不足时以无文字且对辅助功能隐藏的空行补齐。`ImageRenderer` 在相同宽度下核对所有状态像素高度一致；既有窄卡 OCR 仍确认重复进程 PID 与数字值可见。 |
| 既有界面回归 | **已验证（自动化）** | `ProcessRankingViewTests` 11 项和 `UITests` 29 项均通过；保留 PID 后缀、纯数字数值、菜单栏四项总量、折线图窗口及磁盘 capacity-only 行为。真实菜单栏弹窗仍需人工补验。 |

#### 本轮人工视觉补验

1. 打开 CPU、内存、上传、下载四张卡，观察进程数从 0～5 变化时卡片外框、两列对齐和整个面板高度均不跳动。
2. 确认不足五项时剩余位置为空白行，没有横条、占位符或辅助功能朗读内容。
3. 同时复核折线图、动态纵轴、水平刻度线、悬停数据、温度、风扇、磁盘容量和设置入口未发生视觉回归。

### 2026-10-17 进程 Top 5 回归

本轮在 `process-top-five` 工作树、功能提交 `11816c7` 上验证；以下记录不替代历史发布产物校验，未重建 DMG。

| 项目 | 状态 | 本轮证据 |
| --- | --- | --- |
| 完整测试 | **已验证** | `swift test` 退出 0；182 项 XCTest，0 失败、0 unexpected，约 17.12 秒。首次受限沙箱运行存在缓存不可写及只读构建数据库错误，退出 1，不作为通过证据；允许写入构建缓存后重跑通过。 |
| arm64 Release 构建 | **已验证** | `swift build -c release --arch arm64` 退出 0，输出 `Build complete!`。 |
| 本机 `nettop` 冒烟 | **已验证（本机）/受限沙箱不可用** | `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out` 在受限沙箱退出 70，提示 `NStatManagerCreate failed`；获准在沙箱外以当前用户运行同一只读命令后退出 0，CSV 表头包含 `bytes_in`、`bytes_out`，存在可解析的 `名称.PID` 行。该差异为执行环境的 NStat 限制。 |
| 进程排行与失败隔离 | **已验证（自动化）/未验证（真机故障注入）** | 测试覆盖 CPU 单核口径及超过 100%、内存首轮可用、同轮网络收发分别排序、PID 复用、基线重置、网络进程采集失败隔离、超时及子进程清理；网络排行失败不阻断 CPU/内存及总量历史。 |
| 卡片与菜单栏约束 | **已验证（源码与逻辑）/未验证（视觉）** | 源码保留 380 pt 面板、两列卡片、四张趋势图的纵轴和水平网格及悬停；排行为序号、进程名和数值，无条形图，同名附 PID、长名称尾部截断。测试核对 Top 5 展示和菜单栏只含四项总量。磁盘仍仅显示系统启动卷已用/总容量。 |
| 应用启动与界面工具 | **已验证（进程冒烟）/未验证（界面交互）** | `swift run MacResourceMonitor` 构建并保持运行；界面工具不识别裸可执行文件。随后 `bash scripts/build-app.sh` 退出 0，尝试连接本工作树 `dist` 应用包时返回 `timeoutReached`，未取得面板 AX 内容或截图。未据此确认布局、四图、悬停或设置交互，待按下方清单补验。仅清理本轮启动的进程；未安装到 `/Applications`，未修改真实登录项。 |
| Git | **已验证** | `git diff --check` 退出 0；本轮仅修改 README 和本验收记录，生成的应用包由忽略规则排除。 |

### 进程 Top 5 真机补验步骤

以下步骤尚未通过本轮界面工具验收；须在目标 Mac 上执行并记录结果。故障注入应使用测试构建的替身采集器，不修改系统 `nettop` 或应用权限。

1. 打开 CPU 密集任务，确认 CPU Top 5 在下一轮差值采样后更新且允许超过 100%。
2. 打开多个同名辅助进程，确认重复名称附带 PID，长名称被尾部截断。
3. 产生上传和下载流量，确认两张网络卡使用同一轮采样但分别排序。
4. 切换 1/3/5 秒刷新，确认 CPU/网络排行先等待一轮后恢复，内存排行立即可用。
5. 睡眠再唤醒，确认没有跨睡眠区间的 CPU 或网络尖峰。
6. 临时模拟 `nettop` 失败，确认上传/下载排行暂不可用而折线图及其他指标继续刷新。
7. 打开面板，确认 380 pt 内四张资源卡仍为两列，四图趋势、纵轴、水平网格及悬停正常；Top 5 为进程名和数字数值、无条形图，设置入口可打开，菜单栏仍只显示 CPU、内存、上传和下载总量。

### 2026-10-02 监控设置回归

| 项目 | 状态 | 本轮证据 |
| --- | --- | --- |
| 完整测试 | **已验证** | 监控设置工作树执行 `swift test` 退出 0；117 项 XCTest，0 失败、0 unexpected，约 7.78 秒。首次受限沙箱运行因缓存不可写和只读构建数据库退出 1；该次不作为通过证据。 |
| arm64 Release 与发布产物重建 | **已验证** | `swift build -c release --arch arm64`、`bash scripts/build-app.sh`、`bash scripts/build-dmg.sh`、`bash scripts/verify-release.sh` 依次执行，全部退出 0；应用包与 DMG 已重建。 |
| 最终应用与 DMG | **已验证** | 发布脚本核对 dist 与只读 DMG 内应用的 arm64、最低 macOS `13.0`、`LSUIElement=true`、应用图标、ad-hoc 签名及严格签名校验；DMG 校验和有效，Applications 链接和安装说明存在，验证后自动卸载。发布仍未经公证。 |
| 监控设置与历史窗口 | **已验证（自动化）/未验证（真机交互）** | 测试覆盖设置默认值及持久化、刷新间隔更新、时间窗口裁剪、单项 600 点上限、缩短立即裁剪和延长不补造历史；真机清单见下表。 |
| Git | **已验证** | `git diff --check` 退出 0；`build/`、`dist/` 被忽略且 `git ls-files build dist` 无输出。仅修改本任务指定的三份文档。 |

以下图标、动态纵轴和 2026-10-01 验证记录作为既有证据保留；除上表明确列出的项目，本轮未重新执行这些历史检查。

### 2026-10-02 图标与动态纵轴最终回归

| 项目 | 状态 | 本轮证据 |
| --- | --- | --- |
| 完整测试 | **已验证** | 合并后的 `main` 执行 `swift test` 退出 0；93 项 XCTest，0 失败、0 unexpected，约 5.09 秒。首次受限沙箱运行退出 1，出现缓存不可写及只读构建数据库；该次不能作为通过证据。 |
| Release 与干净产物重建 | **已验证** | `swift build -c release --arch arm64`、`swift package clean`、`bash scripts/build-app.sh`、`bash scripts/build-dmg.sh`、`bash scripts/verify-release.sh` 依次执行，全部退出 0；清理后重新编译并重建 app bundle 和 DMG。 |
| 最终应用元数据、架构与签名 | **已验证** | 发布脚本同时检查 dist 与只读 DMG 内应用：macOS `13.0`、`LSUIElement=true`、thin arm64、`Signature=adhoc`、严格签名校验。发布未经公证。 |
| 图标源图与包内资源 | **已验证** | `sips` 核对源图为 1024×1024 且有 alpha；最终 DMG 内 `CFBundleIconFile=AppIcon.icns`，资源 SHA-256 与仓库一致：`7a69666a6e40bf3e3edcf4756e55c47332400af43085132950b8cd6b784922e1`。 |
| Finder / 应用信息图标 | **已验证（最终 DMG 内应用）** | Finder 打开 `/Volumes/Mac Resource Monitor 1/MacResourceMonitor.app` 的“显示简介”；可访问性信息确认来源为本轮最终 DMG，截图顶部小图标和预览均显示蓝色圆角折线图标。深色背景正常预览尺寸未见白色方底或可辨认顶部淡边。未实际安装到 `/Applications`，安装后图标未验证。 |
| DMG 范围 | **已验证** | 根目录仅应用、`Applications -> /Applications` 和 `INSTALL.md`；未添加 `.VolumeIcon.icns` 或专用卷图标。 |
| 四图动态三档纵轴与低 CPU 波动 | **已验证（逻辑）/未验证（实际面板）** | 8 项纵轴测试和 3 项可见窗口轴测试通过，包含窗口外峰值、非有限值与系统时间回拨边界；源码 CPU、内存、上传、下载均使用动态 domain 与三档 ticks。低 CPU 窄范围测试通过。不能据此宣称真实面板 CPU 起伏、标签裁切或浅/深色可读性通过。 |
| 真机启动和退出 | **已验证（进程冒烟）/未验证（菜单栏视觉）** | 从最终 `dist/MacResourceMonitor.app` 启动并核对进程。CUA 连接菜单栏应用返回 `timeoutReached`，未取得弹窗；菜单栏无时间、四图、传感器、磁盘容量及 Dock 视觉继续待补验。检查后结束本轮应用进程并确认无残留。 |
| Git | **已验证** | `git diff --check` 退出 0；`build/`、`dist/` 被忽略且 `git ls-files build dist` 无输出。 |

下表中 2026-10-01 的 harness 及历史验证记录保留作为既有证据，不代表监控设置回归重新执行；当前发布产物以监控设置回归表和交付物数据为准。

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| XCTest 测试套件 | **已验证** | 安装并启用完整 Xcode 后，`swift test --disable-sandbox` 退出 0；共执行 82 项测试，0 失败、0 unexpected，耗时约 5.19 秒。测试代码存在 4 条 `weak` 变量可改为常量的编译器提示，不影响测试结果。 |
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
| 点击菜单栏后显示总览和所选历史时长的折线 | **未验证（真机交互）** | 默认最近 5 分钟，可选择 1/5/10 分钟；源码已构建，未完成人工界面操作和视觉核对。 |
| 刷新时间 1/3/5 秒修改即时生效 | **未验证（真机交互）** | 在设置逐一选择，回到面板观察菜单栏和数值按所选节奏更新；不需重启。 |
| 历史时长 1/5/10 分钟修改即时生效 | **未验证（真机交互）** | 逐一选择并核对设置摘要、四张趋势卡片文案和时间窗口立即一致。 |
| 监控设置重启保留 | **未验证（真机交互）** | 选择非默认刷新与历史时长，退出并重新打开仓库内应用，确认选择和面板窗口保留。 |
| 缩短历史立即裁剪 | **未验证（真机交互）** | 积累超过 1 分钟历史后从 10 或 5 分钟切换为 1 分钟，确认四图立即移除窗口外旧点。 |
| 延长历史不补造样本 | **未验证（真机交互）** | 从 1 分钟改为 5 或 10 分钟，确认窗口扩展但旧点不会重现，也不出现人工补点；后续真实采样逐步累积。 |
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

- DMG：`/Users/zhangdi/.codex/worktrees/monitoring-settings/mac_resource_monitoring/dist/MacResourceMonitor.dmg`
- 大小：2546119 bytes（约 2.43 MiB，2026-10-02 在监控设置工作树重建）
- SHA-256：`7e9aacbe85e3572def30ded5d71206ef4a45cb626135bfddb41fa26b340072c2`
- 签名：ad-hoc
- 公证：未公证

## 发布前人工补验建议

1. 按 `INSTALL.md` 从 DMG 拖入 `/Applications`，完成首次右键打开。
2. 人工核对菜单栏四项、面板折线、温度、风扇和磁盘容量卡片；确认 Dock 无图标。
3. 逐一修改“刷新时间”1/3/5 秒和“保留最近时间”1/5/10 分钟，核对即时生效；退出并重新打开应用，确认非默认设置保留。
4. 积累历史后缩短为 1 分钟，核对四图立即裁剪；延长为 5 或 10 分钟，核对只扩展时间窗口、不补造旧样本。
5. 开关“登录时自动启动”，重启登录会话确认行为，再关闭该选项。
6. 分别观察空闲、高 CPU、网络下载、网络接口切换和睡眠唤醒场景；不再验收磁盘读写速率。
7. 退出应用并删除 `/Applications/MacResourceMonitor.app`，确认卸载说明可执行。

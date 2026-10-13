# Intel 支持技术设计（MRM-INTEL-03）

## 意图与边界

交付 macOS 13+ 的 arm64 与 Intel x86_64 单一 universal 应用及 DMG，保留现有菜单栏四项、趋势、设置、系统启动卷 capacity-only、登录项、睡眠后 CPU/网络基线。Intel 温度与风扇只作尽力读取；每项独立标注不可用，绝不以 0 冒充缺失；仅在可信地读取到风扇数为零时显示「无风扇」。应用仍为 `LSUIElement` 菜单栏程序、ad-hoc 签名、未公证，不新增权限、SMC 写入或第三方依赖。此设计是开发目标，**不是 Intel 真机已验证的声明**。

本阶段仅产出设计及实施计划，不改源码/测试、不构建发布、不提交或推送、不操作真实登录项。后续实现与实际发布是不同授权边界；真机签收单独阻塞。若 Intel 机器无法提供可信温度/风扇数据，通用功能仍正常、相应卡片显示「— / 暂不可用」，不能为了填数扩大私有接口或伪造值。

## 当前证据与关键问题

- `Package.swift` 已设 macOS 13；`Resources/Info.plist` 的 `LSMinimumSystemVersion=13.0`、`LSUIElement=true`。
- `Monitoring/ProviderProtocols.swift` 的 `ProviderSet.live` 通过 `SystemSensorProvider` 延迟创建 `AppleSiliconSensorProvider`；未按架构选择。`SensorProviding.sample() -> ThermalMetric`，`ThermalMetric` 将可空温度和非可空风扇绑在一起；当前读取 `FNum` 或任何风扇失败导致整个 thermal `.unavailable`，可用温度也消失。
- `SMCClient` 限于 AppleSMC 读指令，连接/缓存受锁保护；`SMCTypes.swift` 解码 `sp78/fpe2/ui8 /ui16/ui32/flt `，其中浮点注释只确认 Apple Silicon；协议和具体 Intel 温度键/类型并未在 Intel 真机验证。
- `scripts/build-app.sh` 与 `scripts/verify-release.sh` 仅检验 arm64；`scripts/build-dmg.sh` 从 app 复制；`.github/workflows/release.yml` 在 `macos-15` runner 测试并调用这三个脚本，签名与 SHA-256 在后。`README.md` / `INSTALL.md` / `AGENTS.md` 仍宣称首版 Apple Silicon。

## 架构与接口决策

**分派选编译期，不选运行时探测。** macOS 在加载 universal 可执行文件时选择本机 slice；在 `ProviderSet.live` 的 `#if arch(x86_64)` 构造 Intel provider、`#elseif arch(arm64)` 构造 Apple Silicon provider；`#else` 显式编译失败，不静默落入错误策略。每个 slice 都有相同的 `SensorProviding` 合约。真实 `.live` 仅此一处选路，保持延迟打开 SMC；测试通过显式注入 mock transport/provider 验证两个策略，arm64 主机不声称执行过 x86_64 运行路径。无需基于 `uname`/Rosetta 的运行时分派，Rosetta 选择 x86_64 slice 时也使用 x86_64 策略；原生 Intel 真机验收仍不可替代。

建议将 `ThermalMetric` 改为 `temperature: Reading<Double>` 与 `fan: Reading<FanMetric>`（保留 snapshot 的外层 `thermal: Reading<ThermalMetric>` 以最小化引擎改动）：温度与风扇分别读取并捕获错误；不再通过可空温度表示采集失败。外层 `.unavailable` 表示连接/采集器级失败（例如 AppleSMC 不可打开），UI 对两项均展示不可用；正常采样返回 `.value(ThermalMetric(...))`，内部两个 reading 可各自失败。`Reading.unavailable` 理由用于诊断，但 UI 仅显示统一「暂不可用」，避免暴露私有键错误。启动尚未采样显示「等待下一次采样」。温度成功必须是有限且可信区间 10...125 °C；不能通过 `MetricFormatter` 对无效值归零。风扇 `.rpm(0)` 仅代表已确认存在的风扇确实停转，`.fanless` 仅代表 `FNum` 成功且解码为整数 0；`FNum` 缺失、格式错误或读速度失败均为不可用。多风扇保留最高可信实际速度，任一应读风扇失败则风扇整体不可用；温度不受影响。有效风扇数继续沿用当前整数 0...10 上限。

Apple Silicon 温度延续 `Tp` 枚举/可信范围选择；风扇读失败不再遮蔽有效温度。Intel 使用独立 `IntelSensorProvider(transport: any SMCTransport)`，优先针对 CPU 温度候选键直接逐一读取和解码，不把任意 `T*` 温度（电池、机箱）冒充 CPU；候选 `TC0P`、`TC0D` **仅为待 Intel 真机核验的实验候选**，无证据时不能在文档或界面声称这些键可靠、总存在或适用于全部 Intel 机型。具体优先序、含义和类型应经真机观测确认后再冻结；在验证前候选全部失效就显示不可用。共享只读 SMC 传输及必要的风扇读取校验可以提取到 `SMCSensorReadings`，但不改变 SMCClient 写入能力（仍无写 API）、布局及状态校验；`flt ` 的字节序/语义不得从 arm64 测试推断为 Intel 适用。键读失败继续尝试下一个候选，不因一个键阻断风扇；不可对同一个失败值回退伪造数据。

`MonitoringEngine.collect` 原有其他采集器并发失败隔离、sleep generation、CPU/网络速率基线与 `MetricHistory` 均保留；只改 thermal 内部结构及 diagnostics：内部某项失败不能仅因为外层 `.value` 而在日志中记为传感器全部成功，应按传感器现有 `DiagnosticComponent.sensors` 输出可诊断的非敏感失败摘要，恢复时清除；其他 CPU/内存/网络/磁盘读数照常提交。菜单栏不显示 thermal，仪表盘两卡分别消费各自 `Reading`；失败值「—」/「暂不可用」，可信 `.fanless` 显示「无风扇」。

## 构建、产物与发布门禁

`build-app.sh` 独立构建 `--arch arm64` 与 `--arch x86_64` release 二进制，分别确认薄 slice 后 `lipo -create` 到 app 的唯一 executable，**合并后再** ad-hoc 签名；不因宿主机器架构不同而改变输出目标。SwiftPM 两个 `--show-bin-path` 必须对应各自架构，输出及缓存路径不可相互覆盖；任何一步失败立即退出，不留可被误发的旧 app/DMG（至少删除目标 app，构建 DMG 前必须重建并验证 app）。`build-dmg.sh` 保持单一 DMG、安装说明和 Applications 快捷方式。`verify-release.sh` 同时对 `dist/` app 和只读挂载的 DMG 内 app 校验 `lipo -archs` **恰好含** arm64、x86_64 两个 slice，且对每个 slice 执行最低系统版本检查（如 `vtool -show-build -arch ...`，按真实工具输出解析，不以 plist 代替 Mach-O 检查）；保留 plist、图标、可执行权限、ad-hoc 签名与 `hdiutil verify` 等现有检查。对 DMG 内外二进制可比较 SHA-256 以确认打包的是同一可执行文件。不能单靠 `file` 字符串中出现 `arm64`。发布工作流在创建 Release 之前运行 `swift test`、两个架构 release 构建及三脚本验证；校验失败不得上传或创建 Release。首次 Tag 发布只在另行授权后进行，既有 ad-hoc/未公证措辞不变。

## 验证矩阵及阻塞

| 层次 | arm64 | x86_64 | 通过条件 |
|---|---|---|---|
| 纯逻辑/传感器 mock | Swift XCTest | 交叉构建；真机再跑 XCTest | 温度/风扇独立失败、错误解码、FNum=0 与失败区别、无错误架构选路 |
| 编译 | `swift build -c release --arch arm64` | `swift build -c release --arch x86_64` | 各自退出 0，产物薄 slice 架构符合预期；交叉编译不等于运行验证 |
| 包 | 同一 universal app | 同一 universal app | app 与 DMG 内外 `lipo -archs` 两架构、per-slice deployment target 为 macOS 13.0（不能高于 13.0 而失去对 macOS 13 的支持）、签名及包元数据合格 |
| 功能回归 | 本机 `swift test` + 启动验收 | Intel 机 `swift test` + 启动验收 | 菜单栏四项、CPU/内存/网络、趋势与设置、启动卷容量、登录项仅模拟测试、睡眠后基线；无需修改真实登录项 |
| 硬件传感器 | 现有 Apple Silicon 样机 | **阻塞：需 macOS 13+ Intel 真机** | 记录机型/OS、SMC 可访问性、候选键及原始类型/字节的脱敏观测、逐卡读数/不可用状态、风扇是否物理存在；无证据不得宣称 Intel 键已适配 |

自动化通过并不能解除 Intel 真机阻塞。若 Intel 真机温度/风扇皆不可读，按尽力读降级仍可讨论发布，但必须向协调人呈现真实结果并由产品负责人确认对外措辞；不能把未测作已测。对 UI 登录项只用 fake service，不注册/注销真实服务。

## 设计取舍与风险

- 选编译期分派是按 universal slice 确定 provider，少一条硬件探测错误路径；代价是 arm64 host 的测试不能运行 Intel slice，需独立跨架构构建与真机验证。
- Intel SMC 私有协议及温度键随机型差异可能无效，候选键不构成已验证能力；失败降级比硬编码「0 °C/0 RPM/无风扇」安全。
- 分离读数会影响所有 `ThermalMetric` fixture、UI presentation 和 diagnostics；必须回归 Apple Silicon 无风扇、停转、缺键情形。
- 交叉架构 SwiftPM/SDK 与 GitHub runner 的可用性需实际构建确认；本设计不声称已完成构建或 Intel 真机测试。

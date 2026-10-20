# MRM-DEV-005：全关菜单栏交互核验记录

## 自动化替代证据

- `SelectionIntegrationTests` 使用独立 `UserDefaults` suite 与可计数提供器，贯穿设置、Store、Engine、异步发布、菜单栏文案及详情可见板块：旧设置迁移；全关首帧与零指标调用；重新开启上传的首轮速率基线、后续速率/排行与历史；七项逐一开启时未选分支零调用；网络进程排行及温度单侧故障隔离。
- `Resources/Info.plist` 经 `plutil -lint` 检查有效，`LSUIElement=true`、`LSMinimumSystemVersion=13.0`、标识 `com.local.MacResourceMonitor`。应用入口使用窗口式 `MenuBarExtra`，全关时菜单栏文案为“监控”，空详情保留“设置”和“退出应用”按钮。
- 自动化模型/代码检查**不能证明真实 macOS 菜单栏入口可点击**，不能代替人工点击验收。

## 仓库内真机尝试及限制

- 为避免覆盖已有 `dist/MacResourceMonitor.app`，使用仓库内 `build/mrm-dev-005/MacResourceMonitor.app` 测试副本，源自 arm64 Release 可执行文件；复制原 `Info.plist` 和图标，将测试副本的 bundle ID 改为独立域 `com.local.MacResourceMonitor.MRMDEV005` 后 ad-hoc 签名并验证签名。未安装到 `/Applications`，未修改真实登录项、原产品 bundle ID 的偏好或已有 `dist/` 产物。
- 向该独立测试域写入七项 `false`，`defaults read` 返回七个 `0`；`open -n -a` 启动的进程路径指向上述仓库内测试副本。
- `computer_use` 按测试 bundle ID 捕获返回 `no on-screen window matched app`；按 PID 捕获提示必须同时指定 window ID，而 `list_windows` 没有该菜单栏应用窗口。定向 `System Events` UI 查询 30 秒超时。**未获取菜单栏入口/弹窗的可交互元素或点击证据**，故入口→设置→重新启用→退出链路仍待交互环境人工核验。尝试后已终止仅该测试副本进程并删除独立测试域偏好。

## 可执行后续核验路径

在能够访问菜单栏并授权所需辅助功能的交互 macOS 桌面，先确认使用本仓库最新构建而非 `/Applications` 中同名旧版；优先用独立 bundle ID 测试副本，避免改变现有用户偏好。点击菜单栏入口，在设置中逐一关闭七项；确认标签为“监控”、点击后为空状态且仍有设置和退出；再由设置重新开启上传，返回确认只有上传卡片和菜单栏摘要，首轮为速率基线，后续更新；最后点击面板“退出应用”并核实该测试进程退出。应记录实际点击步骤、界面截图/辅助功能状态和测试包路径；若仍不能访问菜单栏，明确保留未验收状态并由具备交互桌面的人员执行。

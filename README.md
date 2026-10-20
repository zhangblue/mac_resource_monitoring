# Mac Resource Monitor

Mac Resource Monitor 是一款面向 Apple Silicon 的 macOS 菜单栏资源监视器，可快速查看系统资源状态。

## 当前功能

- 菜单栏最多显示 CPU、内存、网络上传和下载摘要；应用没有常驻 Dock 图标。
- 设置页以固定可见的“返回首页”按钮作为返回入口；其余设置内容可滚动，面板高度上限为 520 pt。七项显示板块使用可再次点击的状态按钮：开启为强调色高亮，关闭为灰色；各项保留独立持久化，辅助功能提供板块名称及“显示”／“不显示”状态。CPU、内存、上传、下载、芯片温度、风扇、磁盘容量默认全选并自动保存；前四项同时控制菜单栏摘要和详情卡片（含趋势及进程排行），后三项仅控制详情。未选中的指标不单独采集，仍被选中指标所需的共享采集继续运行。
- 允许七项全关：菜单栏保留可点击的“监控”入口；空面板仍可进入设置或退出应用，不再调用指标采集器。重新开启速率指标时，首轮建立新基线，随后显示速率；重启时在首帧前恢复选择，不闪现旧指标。
- 面板按选择提供 CPU、内存、上传和下载趋势，以及芯片温度和风扇状态。
- CPU、内存、上传和下载卡片各显示实时进程 Top 5，以进程名和数值列出排行；CPU 按单核占用计，可超过 100%，内存显示常驻内存。上传和下载排行由系统 `nettop` 的同一轮采样分别排序。
- CPU 和网络进程排行在首次采样、刷新间隔切换或睡眠唤醒后等待一轮差值采样，内存排行可立即显示；单项排行暂不可用不影响总量指标及趋势刷新。
- 磁盘仅统计系统启动卷的已用容量和总容量，不显示磁盘读写速率。
- 默认每 1 秒刷新，默认保留最近 5 分钟趋势；可在设置中选择 1/3/5 秒刷新间隔和 1/5/10 分钟历史时长。

## 系统要求

- Apple Silicon Mac。
- macOS 13 或更高版本。
- 从源码构建需要完整 Xcode，并已同意 Xcode 许可证；项目使用 Swift Package Manager。

## 安装

下载并打开 DMG，将 `MacResourceMonitor.app` 拖到映像中的 Applications 快捷方式。首次运行时，在“应用程序”中右键点击该应用并选择“打开”，然后在确认框中继续打开。详细说明见[安装指南](INSTALL.md)。

## 从源码运行

在仓库根目录运行：

```bash
swift run MacResourceMonitor
```

## 编译

构建调试版本和 arm64 Release 可执行文件：

```bash
swift build
swift build -c release --arch arm64
```

生成可运行的应用包：

```bash
bash scripts/build-app.sh
```

应用包输出到 `dist/MacResourceMonitor.app`。

## 测试

```bash
swift test
```

## 构建并校验 DMG

依次运行以下脚本；应用包输出为 `dist/MacResourceMonitor.app`，磁盘映像输出为 `dist/MacResourceMonitor.dmg`：

```bash
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
```

## 项目结构与发布说明

- `Sources/MacResourceMonitor/`：应用、监控、系统数据提供器和界面源码。
- `Tests/MacResourceMonitorTests/`：单元与集成测试。
- `Resources/`：应用包资源及 `Info.plist`。
- `scripts/`：应用包和 DMG 构建、发布产物校验脚本。
- `docs/`：设计、实施计划和发布校验资料。

当前发布使用 ad-hoc（临时）签名，尚未经过 Apple 公证。首次打开时请按[安装指南](INSTALL.md)操作。

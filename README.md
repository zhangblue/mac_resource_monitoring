# Mac Resource Monitor

Mac Resource Monitor 是一款面向 Apple Silicon 的 macOS 菜单栏资源监视器，可快速查看系统资源状态。

## 当前功能

- 菜单栏仅显示 CPU、内存、网络上传和下载摘要；应用没有常驻 Dock 图标。
- 面板提供 CPU、内存、上传和下载趋势，以及芯片温度和风扇状态。
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

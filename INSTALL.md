# 安装 Mac Resource Monitor

当前版本支持 Apple Silicon Mac 和 macOS 13 或更高版本。应用常驻菜单栏，不会在 Dock 中显示图标；点击菜单栏中的 CPU、内存、上传和下载摘要，可查看五分钟趋势、芯片温度、风扇状态以及系统启动卷的已用/总容量。

1. 双击 `MacResourceMonitor.dmg` 挂载磁盘映像。
2. 将 `MacResourceMonitor.app` 拖到映像中的 `Applications` 快捷方式，完成安装。
3. 首次运行时，在“应用程序”中右键点击 `MacResourceMonitor.app` 并选择“打开”，然后在确认框中继续打开。如果系统仍阻止启动，请前往“系统设置”→“隐私与安全性”，确认要打开该应用。

本版本使用临时（ad-hoc）签名，尚未经过 Apple 公证，因为目前没有 Developer ID 证书。无需关闭 Gatekeeper。

如需随系统启动，请点击菜单栏摘要，进入“设置”，打开“登录时自动启动”。

卸载前，先在“设置”中关闭“登录时自动启动”，点击“退出应用”，再删除 `/Applications/MacResourceMonitor.app`。

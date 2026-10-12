# GitHub Tag 自动发布设计

## 目标

当维护者向 GitHub 推送形如 `v*` 的 Git Tag 时，由 GitHub Actions 在 Apple Silicon macOS Runner 上构建、校验并发布可下载的 DMG 安装包。发布流程沿用仓库现有脚本，不改变应用功能、签名方式或安装说明。

## 触发与权限

- 工作流仅由 `push.tags: v*` 触发，普通分支推送和 Pull Request 不创建 Release。
- Job 使用 `macos-15` Runner，以保持 arm64 构建路径。
- 工作流仅申请 `contents: write`，供仓库内置 `GITHUB_TOKEN` 创建 GitHub Release 和上传附件。
- 同一 Git 引用只允许一个发布任务运行，且已开始的发布任务不会因新任务而取消。

## 构建与发布流程

工作流按以下顺序执行，任一步失败都会阻止 Release 创建：

1. 检出触发 Tag 对应的源码。
2. 运行 `swift test`。
3. 运行 `bash scripts/build-app.sh`，生成 ad-hoc 签名的 arm64 应用包。
4. 运行 `bash scripts/build-dmg.sh`，生成 `dist/MacResourceMonitor.dmg`。
5. 运行 `bash scripts/verify-release.sh`，验证应用包、架构、签名、DMG 和安装内容。
6. 为 DMG 生成 `dist/MacResourceMonitor.dmg.sha256`。
7. 使用 GitHub CLI 为当前 Tag 创建 Release，自动生成发行说明，并上传 DMG 与校验文件。

发布命令使用 `--verify-tag`，确保 Release 只对应已经存在的触发 Tag。Release 标题为 `Mac Resource Monitor <tag>`。

## 版本与兼容性

- 首个发布 Tag 使用 `v1.0`，与当前 `Resources/Info.plist` 及 `scripts/verify-release.sh` 中的版本 `1.0` 保持一致。
- 本次不把版本号自动注入构建产物。后续发布新版本时，维护者仍需同步更新应用版本和发布校验脚本。
- 发布仍使用 ad-hoc 签名且未经 Apple 公证。工作流不得宣称产物已经公证，也不改变现有首次打开说明。
- 产物仅支持 Apple Silicon 和 macOS 13 及以上版本。

## 交付内容

- `.github/workflows/release.yml`
- GitHub Release 附件：
  - `MacResourceMonitor.dmg`
  - `MacResourceMonitor.dmg.sha256`

## 验证

- 检查工作流 YAML 可解析。
- 检查工作流引用的脚本和产物路径均存在。
- 依次运行 `bash scripts/build-app.sh`、`bash scripts/build-dmg.sh` 和 `bash scripts/verify-release.sh`。
- 运行 `git diff --check`。
- 不在本地模拟创建 GitHub Release，以免产生远端变更；首次推送 `v1.0` 后由 GitHub Actions 完成端到端验证。

# GitHub Tag 自动发布实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 推送 `v*` Tag 时，在 GitHub Actions 中构建并校验 arm64 DMG，然后创建带安装包和 SHA-256 校验文件的 GitHub Release。

**架构：** 单个 GitHub Actions 工作流负责协调仓库现有测试、应用打包、DMG 制作和发布校验脚本。只有全部本地构建步骤成功后，工作流才通过 GitHub CLI 使用内置令牌创建 Release 并上传附件。

**技术栈：** GitHub Actions YAML、Swift Package Manager、macOS `hdiutil`、GitHub CLI。

---

## 文件结构

- 创建 `.github/workflows/release.yml`：定义 Tag 触发、arm64 macOS 构建、校验和 GitHub Release 发布流程。

### 任务 1：添加 Tag 自动发布工作流

**文件：**
- 创建：`.github/workflows/release.yml`

- [x] **步骤 1：确认配置测试的适用方式**

该交付物是 GitHub Actions 配置文件，属于 TDD 技能列出的配置文件例外。无需新增产品单元测试；通过 YAML 解析、路径断言、现有 Swift 测试及完整发布构建验证其行为。

- [x] **步骤 2：创建最小发布工作流**

```yaml
name: Release macOS DMG

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build-and-release:
    runs-on: macos-15

    steps:
      - name: Checkout source
        uses: actions/checkout@v6

      - name: Run tests
        run: swift test

      - name: Build application
        run: bash scripts/build-app.sh

      - name: Build DMG
        run: bash scripts/build-dmg.sh

      - name: Verify release
        run: bash scripts/verify-release.sh

      - name: Generate checksum
        run: |
          shasum -a 256 dist/MacResourceMonitor.dmg \
            > dist/MacResourceMonitor.dmg.sha256

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            dist/MacResourceMonitor.dmg \
            dist/MacResourceMonitor.dmg.sha256 \
            --verify-tag \
            --generate-notes \
            --title "Mac Resource Monitor $GITHUB_REF_NAME"
```

- [x] **步骤 3：静态校验工作流**

运行 YAML 解析器读取 `.github/workflows/release.yml`，并断言：

- Tag 过滤器为 `v*`。
- `runs-on` 为 `macos-15`。
- 权限包含 `contents: write`。
- 工作流引用的三个脚本均存在。
- Release 上传 DMG 和 SHA-256 文件。

预期：解析成功，所有断言通过。

- [x] **步骤 4：执行仓库发布验证**

依次运行：

```bash
swift test
bash scripts/build-app.sh
bash scripts/build-dmg.sh
bash scripts/verify-release.sh
git diff --check
```

预期：所有命令退出码均为 0；验证输出确认 DMG 有效、应用为 arm64 且使用 ad-hoc 签名。

- [x] **步骤 5：审查最终差异**

运行：

```bash
git diff -- .github/workflows/release.yml
git status --short
```

预期：除实现计划外，仅新增 `.github/workflows/release.yml`，且不包含 `build/`、`dist/` 产物。

- [x] **步骤 6：提交实现**

```bash
git add .github/workflows/release.yml docs/superpowers/plans/2026-10-12-github-tag-release.md
git commit -m "ci: 添加 Tag 自动发布工作流"
```

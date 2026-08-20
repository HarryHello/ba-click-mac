# Changelog

All notable changes to **BA Click** — the native macOS (Swift + Metal) version of the Blue Archive click effect + cursor trail.

---

## [0.1.1] - 2026-08-20

### Changed / 变更
- **New app icon**: authored in the modern Icon Composer (`icons/icon.icon`, macOS 26+ format) — BA triangle finders + click-effect arcs on a glass layer. Full-bleed square, macOS applies its own squircle mask. Regenerated via `tools/build-icon.sh` (uses the bundled `ictool` CLI).

### Fixed / 修复
- Unit tests are now hermetic: `test.sh` runs with an isolated `HOME` so `FXSettings.load()` can't pick up the user's real `~/.ba-click-mac-settings.json` and break the "invalid JSON falls back to defaults" test.

### Engineering / 工程
- `tools/build-icon.sh` added; README documents the Icon Composer workflow.

---

## [0.1.0] - 2026-08-20

Initial release of the native Swift + Metal build.

### 核心功能 / Core
- **1:1 复刻原版特效**：点击圆环 + 三角粒子 + 光标尾迹，使用原版 BA 纹理与曲线（Metal 渲染）。
- **全屏 / 桌面双场景覆盖**：单个持久 NSPanel（`fullScreenAuxiliary`），自动跟随进入全屏 Space —— QQ、Chrome B站 全屏下特效依然在最上层。
- **无 Dock 图标**（`.accessory`），菜单栏常驻图标，点击弹出菜单：打开管理面板 / 退出。
- **原生 Liquid Glass 管理面板**（macOS 26+ 自动使用 `NSGlassEffectView`，旧系统回退 `NSVisualEffectView`），界面语言自动跟随系统（中文 / English）。
- **开机自启**（LaunchAgent），设置本地持久化（`settings.json`）。

### 管理面板设置项 / Settings
| 设置 | 说明 |
|---|---|
| 效果开关 | 一键开关全部特效 |
| 开机自启 | 登录时自动启动 |
| 始终显示尾迹 | 关 = 仅左键拖拽时显示尾迹 |
| 尾迹粗细 / 尾迹辉光亮度 | 尾迹外观 |
| 点击效果大小 / 点击效果亮度 | 统一圆盘 / 圆环 / 碎片大小与亮度 |
| 点击圆盘不透明度 / 三角粒子不透明度 | 分项透明度 |
| 效果刷新率 | 24–240 fps（vsync 对齐） |

### 渲染 / Rendering
- **CADisplayLink vsync 渲染循环**（macOS 14+，13 回退 Timer），**逐帧采样鼠标位置** —— 尾迹平滑连续、无折线、无卡顿。
- 真实 **bloom**（半分辨率 `rgba16Float` 金字塔 + 高斯扩散），HDR 发光尾迹。
- **空闲自动停止渲染**（无特效时零 GPU 占用）。
- **看门狗自动重建渲染循环** —— 切换 Space 后特效不再"假死"。

### 修复 / Fixes
- 显示器分辨率/排列变化后特效坐标漂移 → `ScreenGeometry` 统一坐标并随显示变化刷新。
- 面板交互式玻璃导致的整机卡顿 → 关闭 `effectIsInteractive`。
- 菜单栏"打开管理面板"文案不再因关闭面板而残留为"关闭管理面板"。
- 全屏开关关闭时彻底停止全屏背后的渲染（省电）。

### 工程 / Engineering
- 单一构建入口 `build.sh`（二进制 / `.app` / `--release` 签名 DMG），删除废弃的 `Package.swift`。
- **87 项自动化测试**（特效数据、粒子系统、设置持久化、本地化、设置存储）。
- 新增设置项的 6 步 runbook 写入 README。
- **双架构发布**：`BA-Click-0.1.0-arm64.dmg`（Apple Silicon）+ `BA-Click-0.1.0-x64.dmg`（Intel）。
  - 使用自签名证书 `BA Click Mac Signing` 签名。
  - ⚠️ 自签名证书**无法公证**（notarization），首次启动会出现"未受信任的开发者"提示：**右键 → 打开**即可运行。

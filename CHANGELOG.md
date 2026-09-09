# Changelog

All notable changes to **BA Click** — the native macOS (Swift + Metal) version of the Blue Archive click effect + cursor trail.

---

## [0.3.0] - 2026-09-10

### 优化 / Performance
- **渲染帧只绘制有活动粒子的显示器**：多显示器下每帧原来对所有屏幕跑完整的场景+bloom 管线，现在空屏幕整条管线跳过——双屏日常使用 GPU 开销约减半，视觉零差异。
- 「检查更新」的"已是最新版本"现在显示**当前运行版本号**（测试版此前会显示成线上发布版号，如 `v0.2.2`）。

### 新增 / Added
- **多显示器支持**（#2，原作者 [@cjhgit](https://github.com/cjhgit)，在其方案基础上移植到当前架构）：每个物理显示器一个透明覆盖层，点击与尾迹按光标所在显示器路由——特效不再只出现在主屏幕。显示器热插拔/分辨率布局变化自动重建或改尺寸；全屏检测按"任一屏被前台窗口覆盖"判断。

---

## [0.2.2] - 2026-09-09

### Fixed / 修复
- **版本比较支持预发布后缀**：`normalizeVersion` 此前把 `0.2.2-beta1` 的最后一段整体丢弃，导致测试版被解析成 `0.2` 而误报"发现新版本"。现在按 semver 语义比较：`0.2.2-beta1 > 0.2.1`（核心版本更新）但 `0.2.2-beta1 < 0.2.2`（预发布低于对应正式版）。
- **开关"开机自启"会当场拉起第二个实例**：旧实现的 `launchctl bootstrap` 会立即运行 `RunAtLoad` 任务（第二个 BA Click 出现），关闭开关时的 `bootout` 又把它杀掉。捆绑版（正常安装）已改用 **SMAppService**——注册进 系统设置 → 通用 → 登录项，与系统里的开关状态同步，注册绝不当场启动；裸二进制（run.sh 开发用）回退的 LaunchAgent 改为"禁用 → 注册 → 启用"休眠注册，同样不会当场启动。旧版（≤0.2.1）的 LaunchAgent 注册会在下次切换开关时自动迁移/清理。
- **新增单实例保护**（`flock` 锁，`~/.ba-click-mac.lock`）：无论重复打开 .app 还是 run.sh 与已装版并存，第二个实例立即自动退出——不再出现两层特效叠加、设置写入竞争。

---

## [0.2.1] - 2026-09-09

### 新增 / Added
- **仅接通电源时启用**：新开关（默认关）。开启后使用电池时自动暂停全部特效（IOKit 电源源监测，插回电源立即恢复）；没有电池的台式机视为始终接通电源，此开关无副作用。把电池消耗降到最低。
- **自动检测更新**：新开关（默认开）。开启后每次启动软件（延迟 3 秒）和每次打开管理面板时各检查一次更新；60 秒节流，避免频繁开关面板刷爆 GitHub API。自动检查是静默的——离线/失败不会弹"检查失败"，手动点"检查更新"不受影响且始终实时检查。
- **面板常显版本号**：更新状态栏在没有消息时始终显示当前版本（如 `v0.2.1`）；检查后显示 `v0.2.1 已是最新版本` / `发现新版本 vX.Y.Z`。

### Changed / 变更
- **自更新签名校验**：更新助手在替换应用前，先校验下载包签名是否满足当前应用的设计需求（identifier + 证书哈希锁定），不一致（如被代理投递的篡改包）则拒绝替换并跳转 Releases。
- **原子替换 + 回滚**：助手改为先把新应用复制到暂存目录、再改名交换；任一步失败自动回滚旧应用，不会再出现"复制失败、应用消失"。
- 删除 macOS 13 的 Timer 渲染回退死代码（部署目标已是 macOS 14）。

### 工程 / Engineering
- 新增 `PowerMonitor.swift`（IOKit 电源源 + 变更通知）。
- 新增单元测试：更新助手脚本的安全不变量（签名校验、原子交换 + 回滚、禁止先删后拷）、GitHub 代理 URL 构造（原先藏在联网门控后，现在常跑）、自动检查节流、0.2.1 新设置项的解码与回环。
- `build.sh --release` 空签名参数数组在 bash 3.2 `set -u` 下的崩溃已修复（发布管线恢复可用）。

---

## [0.2.0] - 2026-08-20

### 新增 / Added
- **右键 & 中键点击效果**：现在右键（按钮 2）和中键（按钮 3）也会触发点击特效；面板新增「右键点击效果」「中键点击效果」两个开关，可独立关闭。拖拽尾迹同样支持右键/中键（关闭「始终显示尾迹」时，按住任意按钮拖动都会出现尾迹）。
- **版本更新检测**：面板新增「检查更新」按钮，查询 GitHub Releases 最新版本并与当前版本对比；有更新时可一键自动更新（下载对应架构 DMG → 挂载 → 替换应用 → 自动重启），无法自动更新（裸二进制运行 / 应用目录不可写 / 下载或挂载失败）时自动跳转 GitHub Releases 页面手动下载。
- **跳转 GitHub 仓库**：「GitHub 仓库」按钮与「检查更新」同一行，一键打开仓库主页。

### 工程 / Engineering
- `AppInfo.swift` 集中管理版本号与 GitHub 链接；`UpdateManager.swift` 实现检查 / 下载 / 自动更新（更新日志写入 `~/Library/Logs/BA Click/update.log`）。
- 新增设置项测试与版本比较单元测试。
- 修复 `build.sh --release` 在未设置 `BA_CLICK_P12` 时空签名参数数组触发 bash 3.2 `set -u` 报错（`SIGN_ARGS[@]: unbound variable`），发布管线恢复可用。

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

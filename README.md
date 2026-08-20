# ba-click-mac

> A native macOS version of the **Blue Archive click effect + cursor trail**, written in **Swift + Metal**.
>
> **碧蓝档案点击特效 + 鼠标光迹** 的原生 macOS 版本，使用 **Swift + Metal** 实现。

It creates a transparent, borderless, **click-through** overlay covering the main screen. Global mouse events are observed with AppKit's global event monitor and fed into a CPU particle system; Metal renders particles/trail with the **original game textures** (`Circle_01` / `Ring3` / `Triangle_02_1` / `Trail_03`) extracted from `ba-click-fx`, plus a ported **MXFinalBloom** glow.

它创建一个覆盖主屏幕的透明、无边框、**可点击穿透**的覆盖层。全局鼠标事件通过 AppKit 的全局事件监听器收集，交给 CPU 粒子系统模拟；Metal 使用从 `ba-click-fx` 解包出的**原始游戏贴图**（`Circle_01` / `Ring3` / `Triangle_02_1` / `Trail_03`）渲染粒子与光迹，并移植了 **MXFinalBloom** 辉光。

---

## Features / 功能

| | English | 中文 |
|---|---|---|
| Overlay | Transparent click-through overlay on the main screen; never steals focus | 主屏幕透明可穿透覆盖层；从不抢占焦点 |
| Click effect | Center disk → two arcs (弧光) from random sides spread/converge → disk fades → arcs shrink; flying shards | 中心圆盘 → 随机两侧弧光相向扩散/汇聚 → 圆盘消失 → 弧光收缩；飞散碎片 |
| Trail | Cursor trail with width taper (tail thins, color stays constant) | 鼠标光迹，尾部收细（颜色不变） |
| Glow | Ported original `MXFinalBloom` (multi-level pyramid, prefilter → downsample → upsample → additive) | 移植原版 `MXFinalBloom`（多级金字塔：预过滤 → 降采样 → 升采样 → 叠加） |
| Fullscreen | NSPanel (`fullScreenAuxiliary`) is carried into fullscreen apps' Spaces automatically — works over QQ / Chrome fullscreen video | NSPanel（`fullScreenAuxiliary`）自动进入全屏应用的 Space —— QQ / Chrome 全屏视频下均正常 |
| Live tuning | Edit `settings.json`, hot-reloaded every 0.5 s; partial files allowed | 编辑 `settings.json`，每 0.5 秒热重载；允许只写要改的键 |
| Power saving | Stops rendering when idle; no GPU work behind hidden fullscreen (`showInFullscreen=false`) | 闲置时停止渲染；隐藏全屏时不产生 GPU 开销（`showInFullscreen=false`） |

## Status / 状态

- ✅ Transparent click-through overlay / 透明可穿透覆盖层
- ✅ Global click + mouse-move tracking / 全局点击 + 鼠标移动追踪
- ✅ Click effect: center disk, rotating dissolve arcs, flying shards / 点击特效：中心圆盘、旋转溶解弧光、飞散碎片
- ✅ Cursor trail with width taper / 带收细的鼠标光迹
- ✅ Original game textures + Unity particle curves / 原始游戏贴图 + Unity 粒子曲线
- ✅ Multi-pass MXFinalBloom (HDR scene → pyramid → additive glow) / 多级 MXFinalBloom 辉光（HDR 场景 → 金字塔 → 叠加辉光）
- ✅ Works over fullscreen apps (single persistent NSPanel) / 全屏应用之上正常显示（单一常驻 NSPanel）
- ✅ Manual 60 fps render loop (display-link stalls fixed) / 手动 60fps 渲染循环（修复 display link 停滞）
- ✅ Idle power saving (render stops when nothing is on screen) / 闲置省电（无内容时停止渲染）
- ✅ Unit tests (`./test.sh`) + CI (`GitHub Actions`) / 单元测试 + CI
- ✅ App icon (Dock) + menu bar icon (status item) / 应用图标（Dock）+ 菜单栏图标
- ⏳ Multi-monitor (currently only the main screen) / 多显示器（目前仅主屏幕）
- ⏳ Control panel / tray icon / 控制面板 / 托盘图标

## Requirements / 环境要求

- macOS 13+ (see `Package.swift` → `.macOS(.v13)`)
- Xcode Command Line Tools or Xcode (Swift toolchain)
- A Metal-capable Mac (any Apple Silicon, most Intel Macs)
- 需要 Metal 支持的 Mac（Apple Silicon 或大部分 Intel Mac）

## Build, run & test / 构建、运行与测试

```bash
./build.sh            # compile → .build/ba-click-mac
./run.sh              # build (if needed) then run
./test.sh             # unit tests: BAEval / ParticleSystem / FXSettings
```

Or build a double-clickable app bundle / 或构建可双击的 .app 包:

```bash
./build-app.sh        # == ./build.sh --app → build/BaClickMac.app
open build/BaClickMac.app
```

Quit / 退出: the app shows in the Dock (`.regular` activation policy) and adds a **menu bar icon** — use the Dock icon, the menu bar icon, **Quit BaClickMac** (`Cmd+Q`), or `pkill BaClickMac` from the terminal.
应用显示在 Dock（`.regular` 激活策略），并在菜单栏添加图标——用 Dock 图标、菜单栏图标、**Quit BaClickMac**（`Cmd+Q`），或终端 `pkill BaClickMac` 退出。

### Isolated click testing / 单独测试点击特效

```bash
BA_CLICK_LOOP=1 ./run.sh   # auto-clicks screen center every 0.9 s
```

## Environment variables / 环境变量

| Variable | Effect | 说明 |
|---|---|---|
| `BA_CLICK_LOOP=1` | Auto-click at screen center every 0.9 s (isolated click-effect testing) | 每 0.9 秒在屏幕中心自动点击（单独测试点击特效） |
| `BA_SHOW_HUD=1` | Show the debug HUD (bloom/particle counts) in the top-left corner | 在左上角显示调试 HUD（辉光/粒子数量） |
| `BA_DISABLE_BLOOM=1` | Disable bloom entirely (core effect only) | 完全关闭辉光（只画核心特效） |
| `BA_BLOOM_DEBUG_VIEW=1` | Show only the bloom pyramid (no core) — for verifying the glow itself | 只显示辉光金字塔（无核心）—— 用于验证辉光本身 |

## settings.json (live tuning / 实时调参)

The app loads `settings.json` from the **current working directory**, the **executable's folder**, or `~/.ba-click-mac-settings.json` (first found wins) and **reloads it every 0.5 s** — edit and save, no restart needed. The file is optional: **the defaults below are the tuned "best" values**, so you can run without any settings file. A full template lives in `settings.example.json`.

应用会从**当前工作目录**、**可执行文件所在目录**或 `~/.ba-click-mac-settings.json`（按顺序取第一个存在的）加载 `settings.json`，并**每 0.5 秒热重载**——改完保存即可，无需重启。该文件是可选的：**下表默认值就是调好的"最佳"参数**，不提供文件也能直接跑。完整模板见 `settings.example.json`。

| Key | Default | Meaning / 含义 |
|---|---|---|
| `diskScale` | `0.8` | Center disk size multiplier / 中心圆盘尺寸倍率 |
| `ringScale` | `0.8` | Arc (弧光) radius multiplier / 弧光半径倍率 |
| `shardScale` | `0.8` | Shard size/speed multiplier / 碎片大小与速度倍率 |
| `trailScale` | `2.2` | Trail width multiplier / 光迹宽度倍率 |
| `showInFullscreen` | `true` | Keep overlay over fullscreen apps; `false` = hide + stop rendering | 在全屏应用上显示覆盖层；`false` = 隐藏并停止渲染 |
| `clickBloomStrength` | `0.1` | Click glow-source energy / 点击辉光源能量 |
| `trailBloomStrength` | `3.5` | Trail glow-source energy / 光迹辉光源能量 |
| `bloomStrength` | `1.7` | MXFinalBloom exposure (`2^(strength/10)-1` in composite) / 辉光曝光 |
| `bloomLevels` | `16` | Max pyramid levels (actual count follows the diffusion formula) / 金字塔最大层数（实际层数由扩散公式决定） |
| `bloomDiffusion` | `7.0` | MXFinalBloom diffusion — drives iteration count + sample scale / 扩散度——决定迭代次数与采样尺度 |
| `bloomThreshold` | `1.0` | Brightness threshold (gamma space) for bloom prefilter / 辉光预过滤亮度阈值（伽马空间） |
| `bloomFalloff` | `0.35` | Rational falloff knee `a = lum/(lum+k)` / 有理式衰减拐点 |
| `bloomBoost` | `1.2` | Extra glow overlay brightness / 辉光叠加额外亮度 |

> **Lenient parsing / 宽容解析**: a `settings.json` may contain **only the keys you want to override** — missing keys keep the defaults. Unknown keys print a warning to stderr (ignored); invalid JSON prints a warning and falls back to defaults. This is intentional, so a partial edit never silently wipes your other settings.
>
> **解析规则**：`settings.json` 可以**只写你要改的键**——缺失的键沿用默认值。未知键会在 stderr 打印告警（忽略）；JSON 非法会打印告警并回退默认值。这是刻意设计：部分修改不会悄悄丢掉其它设置。
>
> `settings.json` is **git-ignored** (personal tuning stays local); commit changes to `settings.example.json` instead.
> `settings.json` 已被 **git 忽略**（个人调参留在本地）；如需提交参数，请改 `settings.example.json`。

## How it works / 工作原理

- **Single persistent `NSPanel`** — borderless, non-activating, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `ignoresMouseEvents = true`. Because it is a `fullScreenAuxiliary` panel, macOS carries it **into every fullscreen app's Space automatically** — no window switching or detection needed.
  **单一常驻 `NSPanel`**——无边框、非激活、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`、`ignoresMouseEvents = true`。因为是 `fullScreenAuxiliary` 面板，macOS 会**自动把它带进每个全屏应用的 Space**——无需切换窗口或检测。
- **Manual 60 fps render loop** — the MTKView's internal display link randomly stalls after Space/fullscreen transitions (the effect appeared "sometimes dead"). We keep `isPaused = true` and drive `MTKView.draw()` from our own `Timer` (`.common` mode) instead. An App Nap activity (`beginActivity(.userInitiated)`) keeps the background app's timer alive.
  **手动 60fps 渲染循环**——MTKView 内部 display link 在 Space/全屏切换后会随机停滞（表现为特效"时有时无"）。我们保持 `isPaused = true`，用自建 `Timer`（`.common` 模式）驱动 `MTKView.draw()`。`beginActivity(.userInitiated)` 防止 App Nap 节流后台应用。
- **Idle power saving** — the render loop stops itself as soon as nothing is on screen; clicks / mouse moves / the click-loop wake it. With `showInFullscreen=false`, the overlay hides and rendering fully stops over fullscreen apps.
  **闲置省电**——屏幕上没有内容时渲染循环自动停止；点击 / 移动鼠标 / 自动点击循环会唤醒它。`showInFullscreen=false` 时，全屏应用之上会隐藏覆盖层并完全停止渲染。
- **Events** — `NSEvent.addGlobalMonitorForEvents` observes clicks/moves system-wide. The app must **never** become frontmost, or the global monitor stops receiving events (we use `orderFrontRegardless()`, never `activate`).
  **事件**——`NSEvent.addGlobalMonitorForEvents` 全局监听点击/移动。应用**绝不能**变成前台，否则全局监听会收不到事件（我们只用 `orderFrontRegardless()`，绝不 `activate`）。
- **Rendering** — offscreen HDR scene (`rgba16Float`) → `MXFinalBloom` pyramid (prefilter → downsample → upsample) → additive composite over the sharp core. Bloom is skipped entirely when nothing is on screen.
  **渲染**——离屏 HDR 场景（`rgba16Float`）→ `MXFinalBloom` 金字塔（预过滤 → 降采样 → 升采样）→ 在锐利核心之上做叠加。屏幕无内容时完全跳过辉光。

## Project layout / 工程结构

```
Sources/BaClickMac/
  main.swift                 App entry, NSApplication + delegate
  AppDelegate.swift          NSPanel setup, 60 fps render loop, mouse monitor,
                             fullscreen handling, watchdog, HUD
  TransparentMTKView.swift   Non-opaque MTKView
  MouseMonitor.swift         Global mouse event observation
  ParticleSystem.swift       Click particles + trail simulation
  Renderer.swift             Metal pipelines, geometry building, bloom pyramid
  Shaders.swift              Metal Shader Language source (runtime compiled)
  FXSettings.swift           settings.json loading / defaults (lenient decode)
  BAEffectData.swift         Unity keyframes / game-derived values
  DebugLog.swift             stderr logging + bail() helper
  ResourceLocator.swift      Shared bundled-resource lookup
Resources/
  AppIcon.icns               macOS app icon (used by the .app bundle)
  icon.png                   App icon bitmap (Dock icon for the raw binary)
  bar_icon_22/44.png         Menu bar icon (1x / 2x template)
  circle/ring/trail/triangle  Game-derived effect textures
icons/
  icon.svg / bar_icon.svg    Icon sources (for regenerating the PNGs/ICNS)
Tests/
  main.swift                 Unit tests: BAEval / ParticleSystem / FXSettings
.github/workflows/build.yml  CI: build + unit tests on macOS
build.sh                     Build binary, or --app for the .app bundle
build-app.sh                 Wrapper for ./build.sh --app
test.sh                      Build & run the unit tests
settings.example.json        Template for optional runtime tuning
```

## Permissions / 权限

Global mouse observation via `NSEvent.addGlobalMonitorForEvents` is generally allowed on macOS — no special permission needed. (A future `CGEventTap` would require Accessibility.)
通过 `NSEvent.addGlobalMonitorForEvents` 的全局鼠标监听在 macOS 上一般无需额外权限。（未来若改用 `CGEventTap` 则需要"辅助功能"权限。）

## Troubleshooting / 排障

- **Effect appears randomly / 特效随机消失或时有时无**: this used to be the MTKView display link stalling after Space/fullscreen transitions — now fixed by the manual 60 fps render loop. If it ever looks dead again, check the watchdog (a stale frame forces a redraw every 0.5 s). / 这曾是 MTKView display link 在 Space/全屏切换后停滞所致——现已通过手动 60fps 渲染循环修复。若再次看起来"死了"，看门狗每 0.5 秒会强制补一帧。
- **App exits immediately with a `FATAL:` message / 启动即退出并打印 `FATAL:`**: Metal device / shader compile / texture load failed — run from a terminal to see the exact reason (resources must exist in `Resources/` with the expected sizes). / Metal 设备 / Shader 编译 / 纹理加载失败——请从终端运行查看具体原因（`Resources/` 下资源必须存在且尺寸匹配）。
- **No click response at all / 点击完全无反应**: make sure the app is not frontmost (never `activate` it); the global mouse monitor only receives events while another app is active. / 请确认应用不是前台（绝不 `activate`）；全局鼠标监听只在其他应用为前台时才能收到事件。
- **HUD shows nothing / HUD 不显示**: it is off by default — run with `BA_SHOW_HUD=1`. / 默认关闭——用 `BA_SHOW_HUD=1` 运行。
- **Settings not applied / 设置没生效**: the app reloads every 0.5 s; watch stderr for `[settings] WARNING:` (invalid JSON → defaults; unknown key → ignored). / 应用每 0.5 秒重载；留意 stderr 的 `[settings] WARNING:`（JSON 非法 → 回退默认值；未知键 → 忽略）。

## Notes / 备注

- The overlay never steals focus; clicks pass through to the apps below. / 覆盖层从不抢占焦点；点击穿透到下层应用。
- Coordinates are in AppKit screen points, scaled by screen height (mirroring the web project's 1080p reference). / 坐标基于 AppKit 屏幕点，按屏幕高度缩放（对齐网页版的 1080p 参考高度）。
- A from-scratch native implementation; visual parameters are ported from the `ba-click-fx` web project's unpacked Unity data. / 原生从零实现；视觉参数移植自 `ba-click-fx` 网页项目解包出的 Unity 数据。

# ba-click-mac

A native macOS version of the **Blue Archive click effect and cursor trail**, written in **Swift + Metal**.

It creates a transparent, borderless, always-on-top, **click-through** overlay covering the main screen. Global mouse events are observed with AppKit's global event monitor and fed into a CPU particle system; Metal renders particles/trail with runtime-generated textures.

## Status

This is an early working prototype:

- ✅ Transparent click-through overlay on macOS
- ✅ Global click + mouse-move tracking
- ✅ Click effect: center disk, rotating dissolve rings, flying shards
- ✅ Cursor trail with fade
- ✅ Metal rendering (vertex/fragment shaders, additive-ish alpha blending, simulated glow)

Not yet implemented (future work):

- Exact Unity parameter-level fidelity and real multi-pass bloom
- Multi-monitor support (currently only the main screen)
- Background-aware capture / HDR
- macOS ScreenCaptureKit integration
- Control panel / tray icon

## Requirements

- macOS 13+
- Command Line Tools or Xcode with Swift
- A Metal-capable Mac (any Apple Silicon or most Intel Macs)

## Build & run

```bash
./build.sh
./run.sh
```

Or build a double-clickable app bundle:

```bash
./build-app.sh
open build/BaClickMac.app
```

Quit from the menu bar → **Quit BaClickMac** (`Cmd+Q`), or kill the process from the terminal.

## Permissions

Global mouse observation through `NSEvent.addGlobalMonitorForEvents` is generally allowed on macOS. If a future version moves to `CGEventTap` (needed for more precise system-wide events), the user will need to grant **Accessibility** permission in System Settings → Privacy & Security.

## Project layout

```
Sources/BaClickMac/
  main.swift              App entry point
  AppDelegate.swift       Window setup, menu, overlay view
  OverlayWindow? (AppDelegate)  Transparent borderless window
  TransparentMTKView.swift      Non-opaque MTKView
  MouseMonitor.swift      Global mouse event observation
  ParticleSystem.swift    BA click particles + trail simulation
  Renderer.swift          Metal pipeline, geometry building, textures
  Shaders.swift           Metal Shader Language source (runtime compiled)
```

## Notes

- The overlay never steals focus; clicks pass through to the apps below.
- The effect coordinates are in AppKit screen points and scaled by screen height, mirroring the web project's 1080p reference height.
- This is a from-scratch native implementation. The visual parameters are inspired by/ported from the `ba-click-fx` web project.
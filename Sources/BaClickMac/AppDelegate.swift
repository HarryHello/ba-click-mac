import AppKit
import MetalKit
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var overlayView: TransparentMTKView?
    private var mouseMonitor: MouseMonitor?
    private var renderer: Renderer?
    private var statusLabel: NSTextField?
    private var statusTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var clickLoopTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fatalError("No screen available")
        }

        let frame = screen.frame

        // Transparent, borderless, always-on-top, click-through overlay.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Floating keeps the overlay above normal app windows but below the
        // macOS menu bar, Force Quit dialog, and other system UI.
        window.level = .floating
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }

        let overlayView = TransparentMTKView(frame: frame, device: device)
        overlayView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        overlayView.layer?.isOpaque = false
        overlayView.layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.framebufferOnly = true
        overlayView.colorPixelFormat = .bgra8Unorm
        overlayView.preferredFramesPerSecond = 120
        overlayView.isPaused = false
        overlayView.enableSetNeedsDisplay = false
        self.overlayView = overlayView

        let renderer = Renderer(view: overlayView)
        self.renderer = renderer
        window.contentView = overlayView
        window.orderFrontRegardless()

        self.reapplyTransparency()

        // Some macOS Spaces switches demote or hide the overlay window even
        // though it joins all spaces; re-assert ordering + transparency after
        // every active-space / screen change so the effect doesn't vanish.
        let recover: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.window?.level = .floating
                self.window?.orderFrontRegardless()
                self.reapplyTransparency()
            }
        }
        self.spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: recover
        )
        // Resolution/configuration changes and windows moving between
        // screens also re-attach the layer and can stall the overlay.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
            using: recover
        )
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main,
            using: recover
        )
        // Every time another app becomes frontmost (including entering
        // fullscreen), re-assert the overlay above it. Fullscreen apps take
        // over a Space; the .fullScreenAuxiliary overlay needs to re-order
        // onto that Space or it stays hidden behind the fullscreen content.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: recover
        )

        // TEMP debug HUD: show bloom/settings/particle state on the overlay.
        let label = NSTextField(labelWithString: "ba-click status")
        label.frame = NSRect(x: 20, y: frame.height - 50, width: 800, height: 26)
        label.isBezeled = false
        label.drawsBackground = false
        label.textColor = .white
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        overlayView.addSubview(label)
        self.statusLabel = label
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatus()
            self?.checkStall()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.statusTimer = timer
        updateStatus()

        // Capture global mouse events. The overlay itself ignores mouse events,
        // so we observe them system-wide and feed the effect manually.
        let monitor = MouseMonitor(screenFrame: frame)
        monitor.onMouseDown = { [weak renderer] point in
            renderer?.particleSystem.addClick(at: point)
        }
        monitor.onMouseMove = { [weak renderer] point in
            renderer?.particleSystem.addTrailPoint(at: point)
        }
        monitor.start()
        mouseMonitor = monitor

        // BA_CLICK_LOOP=1 auto-spawns a click at screen center every 0.9s so
        // the click animation (disk -> arcs -> shrink) can be inspected in
        // isolation without the cursor trail.
        if getenv("BA_CLICK_LOOP") != nil {
            let center = SIMD2<Float>(
                Float(frame.midX),
                Float(frame.midY)
            )
            let loop = Timer(timeInterval: 0.9, repeats: true) { [weak renderer] _ in
                renderer?.particleSystem.addClick(at: center)
            }
            RunLoop.main.add(loop, forMode: .common)
            clickLoopTimer = loop
        }

        self.window = window

        // NOTE: do NOT call NSApp.activate(...) here. If our app becomes
        // frontmost, AppKit's global mouse monitor stops receiving clicks from
        // our own app and the effect appears dead until the user focuses
        // another application.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-assert the CAMetalLayer transparency. The layer can reset its
    /// opaque/background state when the view is re-attached after a Spaces
    /// switch, which otherwise makes the overlay disappear.
    private func reapplyTransparency() {
        guard let view = window?.contentView else { return }
        DispatchQueue.main.async {
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Watchdog: system animations (Mission Control, Spaces, full-screen
    /// transitions) can stall the MTKView display link, leaving the last
    /// frame frozen on screen. If no draw callback has run for >0.75s,
    /// restart the display link and reassert the window/layer.
    private func checkStall() {
        guard let renderer, let overlayView else { return }
        guard renderer.lastDrawTime > 0 else { return }
        let now = CACurrentMediaTime()
        if now - renderer.lastDrawTime > 0.75 {
            overlayView.isPaused = true
            overlayView.isPaused = false
            window?.level = .floating
            window?.orderFrontRegardless()
            reapplyTransparency()
        }
    }

    private func updateStatus() {
        guard let renderer, let label = statusLabel else { return }
        let s = renderer.settings
        label.stringValue = String(
            format: "bloom=%@ I=%.2f(->%.3f) boost=%.1f levels=%d scale=%.3f diff=%.1f th=%.2f falloff=%.1f bursts=%d shards=%d trail=%d",
            renderer.bloomEnabled ? "ON" : "OFF",
            s.bloomStrength,
            renderer.debugBloomIntensityFactor,
            s.bloomBoost,
            renderer.debugBloomLevels,
            renderer.debugBloomSampleScale,
            s.bloomDiffusion,
            s.bloomThreshold,
            s.bloomFalloff,
            renderer.particleSystem.bursts.count,
            renderer.particleSystem.shards.count,
            renderer.particleSystem.trail.count
        )
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit BaClickMac",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
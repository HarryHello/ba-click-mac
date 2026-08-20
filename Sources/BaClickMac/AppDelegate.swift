import AppKit
import MetalKit
import QuartzCore
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var overlayView: TransparentMTKView?
    private var mouseMonitor: MouseMonitor?
    private var renderer: Renderer?
    private var statusLabel: NSTextField?
    private var statusTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var clickLoopTimer: Timer?
    /// Menu bar (status) item so the overlay can be quit without the Dock.
    private var statusItem: NSStatusItem?
    private var openMenuItem: NSMenuItem?
    /// Manual 60fps render loop. We drive MTKView.draw() ourselves instead of
    /// relying on the MTKView display link, which macOS randomly stalls after
    /// Space/fullscreen transitions — that made the effect appear "randomly".
    private var renderTimer: Timer?
    /// Prevents App Nap from throttling the render timer while we are a
    /// non-activating background overlay.
    private var activityToken: NSObjectProtocol?
    /// Set when we intentionally hid+paused the overlay for a fullscreen app,
    /// so recover()/checkStall() don't fight the hidden state.
    private var fullscreenHidden = false
    private var lastFullscreenState: Bool?

    /// Single source of truth for settings (management panel + renderer).
    let store = SettingsStore()
    private var settingsPanel: SettingsPanelController?
    /// Current render timer interval; follows the effect refresh rate.
    private var currentRenderInterval: TimeInterval = 1.0 / 60.0

    private static let housekeepingInterval: TimeInterval = 0.5
    private static let stallThreshold: TimeInterval = 0.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setupStatusItem()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            bail("No screen available")
        }

        let frame = screen.frame

        // Single persistent NSPanel (the configuration that actually works).
        // Being a fullScreenAuxiliary panel means macOS carries it INTO the
        // fullscreen app's Space automatically — no detection/switch needed.
        // .stationary and .ignoresCycle are restored to keep the normal-desktop
        // behavior as close to the original overlay as possible.
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        window = panel

        guard let device = MTLCreateSystemDefaultDevice() else {
            bail("Metal is not supported on this Mac")
        }

        let overlayView = TransparentMTKView(frame: frame, device: device)
        overlayView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        overlayView.layer?.isOpaque = false
        overlayView.layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.framebufferOnly = true
        overlayView.colorPixelFormat = .bgra8Unorm
        overlayView.preferredFramesPerSecond = 60
        // Manual render loop: pause the MTKView's internal display link and
        // drive draw() ourselves (see startRenderTimer). The display link
        // stalls randomly after Space/fullscreen transitions; a self-driven
        // timer keeps rendering deterministic.
        overlayView.isPaused = true
        overlayView.enableSetNeedsDisplay = false
        self.overlayView = overlayView

        guard let renderer = Renderer(view: overlayView) else {
            bail("Failed to initialize Metal renderer (shader compile or resource load failed)")
        }
        self.renderer = renderer
        window?.contentView = overlayView
        window?.orderFrontRegardless()

        self.reapplyTransparency()

        // Management panel + live settings wiring: every panel change applies
        // to the renderer immediately and (if the render timer is running)
        // restarts it at the new refresh rate.
        renderer.applySettings(store.model)
        settingsPanel = SettingsPanelController(store: store)
        currentRenderInterval = 1.0 / Double(max(1, store.model.refreshRate))
        store.onChange = { [weak self] in
            guard let self else { return }
            self.renderer?.applySettings(self.store.model)
            self.syncRenderTimer()
            if !self.store.model.enabled {
                self.renderer?.particleSystem.clear()
            }
        }

        // This overlay is never the frontmost app, so App Nap would throttle
        // its timers/rendering randomly. Assert an activity so clicks are
        // always processed and frames always drawn.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "ba-click overlay: keep rendering and mouse handling live"
        )

        startRenderTimer()

        // Some macOS Spaces switches demote or hide the overlay window even
        // though it joins all spaces; re-assert ordering + transparency after
        // every active-space / screen change so the effect doesn't vanish.
        let recover: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // Don't fight the intentional hide used for fullscreen apps.
                guard !self.fullscreenHidden else { return }
                self.startRenderTimer()
                // Recompute fullscreen state immediately (e.g. on app
                // activation / Space change) instead of waiting for the next
                // 0.5s housekeeping tick.
                self.updateFullscreenState()
                self.reapplyTransparency()
                self.overlayView?.window?.orderFrontRegardless()
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

        // Debug HUD: hidden by default; enable with BA_SHOW_HUD=1. The 0.5s
        // housekeeping timer always runs (fullscreen state + stall watchdog);
        // it only touches the label when the HUD is actually shown.
        if getenv("BA_SHOW_HUD") != nil {
            let label = NSTextField(labelWithString: "ba-click status")
            label.frame = NSRect(x: 20, y: frame.height - 50, width: 800, height: 26)
            label.isBezeled = false
            label.drawsBackground = false
            label.textColor = .white
            label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            overlayView.addSubview(label)
            self.statusLabel = label
        }
        let timer = Timer(timeInterval: Self.housekeepingInterval, repeats: true) { [weak self] _ in
            self?.updateStatus()
            self?.updateFullscreenState()
            self?.checkStall()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.statusTimer = timer
        updateStatus()

        // Capture global mouse events. The overlay itself ignores mouse events,
        // so we observe them system-wide and feed the effect manually.
        let monitor = MouseMonitor(screenFrame: frame)
        monitor.onMouseDown = { [weak renderer, weak self] point in
            guard let self, self.store.model.enabled else { return }
            self.startRenderTimer() // wake the idle-stopped render loop
            renderer?.particleSystem.addClick(at: point)
        }
        monitor.onMouseDrag = { [weak renderer, weak self] point in
            guard let self, self.store.model.enabled else { return }
            self.startRenderTimer()
            renderer?.particleSystem.addTrailPoint(at: point)
        }
        monitor.onMouseMove = { [weak renderer, weak self] point in
            // Trail only follows a free mouse move when "always visible" is on;
            // dragging (left button held) always draws it.
            guard let self, self.store.model.enabled, self.store.model.trailAlwaysVisible else { return }
            self.startRenderTimer()
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
            let loop = Timer(timeInterval: 0.9, repeats: true) { [weak renderer, weak self] _ in
                guard let self, self.store.model.enabled else { return }
                self.startRenderTimer()
                renderer?.particleSystem.addClick(at: center)
            }
            RunLoop.main.add(loop, forMode: .common)
            clickLoopTimer = loop
        }

        // NOTE: do NOT call NSApp.activate(...) here. If our app becomes
        // frontmost, AppKit's global mouse monitor stops receiving clicks from
        // our own app and the effect appears dead until the user focuses
        // another application.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-assert the CAMetalLayer transparency. The layer can reset its
    /// opaque/background state when the view is re-attached (after a Spaces
    /// switch or when moved between primary window and fullscreen panel),
    /// which otherwise makes the overlay disappear.
    private func reapplyTransparency() {
        guard let view = overlayView else { return }
        DispatchQueue.main.async {
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Watchdog: with the manual render timer, a stall can only happen if the
    /// main runloop was blocked (Space animation, Mission Control, etc.). If
    /// the timer is running but no draw callback has fired for >0.5s, force
    /// one frame immediately and reassert the layer.
    private func checkStall() {
        guard let renderer, let overlayView else { return }
        // If we intentionally stopped rendering for a fullscreen app, that's
        // not a stall — don't wake it up to burn GPU behind the fullscreen app.
        if fullscreenHidden { return }
        // If we intentionally stopped rendering while idle (see
        // startRenderTimer), that's not a stall either.
        guard renderTimer != nil else { return }
        let now = CACurrentMediaTime()
        if renderer.lastDrawTime == 0 || now - renderer.lastDrawTime > Self.stallThreshold {
            overlayView.draw() // force one frame now instead of waiting a tick
            overlayView.window?.orderFrontRegardless()
            reapplyTransparency()
        }
    }

    /// Start the manual render loop at the configured refresh rate
    /// (idempotent). The MTKView's own display link stays paused; we call
    /// draw() ourselves so rendering never depends on AppKit's fragile
    /// display-link lifecycle.
    ///
    /// Power saving: the loop stops itself as soon as nothing is on screen
    /// (idle -> zero GPU work). Clicks / mouse moves / the click-loop wake it
    /// up again.
    private func startRenderTimer() {
        guard renderTimer == nil, let overlayView else { return }
        overlayView.isPaused = true
        let timer = Timer(timeInterval: currentRenderInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.overlayView?.draw()
            // Nothing left on screen -> stop until the next interaction.
            if !(self.renderer?.particleSystem.hasActiveParticles() ?? false) {
                self.stopRenderTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    /// Restart the render timer if the effect refresh rate changed while it is
    /// running (idle-stopped timers pick up the new rate on their next wake).
    private func syncRenderTimer() {
        let interval = 1.0 / Double(max(1, store.model.refreshRate))
        if abs(interval - currentRenderInterval) > 0.0001 {
            currentRenderInterval = interval
            if renderTimer != nil {
                stopRenderTimer()
                startRenderTimer()
            }
        }
    }

    /// Fullscreen handling for the single persistent NSPanel:
    ///  - showInFullscreen=true (default): the panel is already a
    ///    fullScreenAuxiliary member of every Space, so macOS carries it into
    ///    the fullscreen app's Space automatically — nothing to do here.
    ///  - showInFullscreen=false: when a fullscreen app is active, hide + stop
    ///    rendering so no GPU work happens behind it; resume on desktop.
    private func updateFullscreenState() {
        guard let renderer else { return }
        let fullscreen = isFullscreenAppActive()
        if fullscreen == lastFullscreenState { return }
        lastFullscreenState = fullscreen

        if fullscreen && !renderer.settings.showInFullscreen {
            fullscreenHidden = true
            stopRenderTimer()
            window?.orderOut(nil)
        } else {
            fullscreenHidden = false
            startRenderTimer()
            window?.level = .floating
            window?.orderFrontRegardless()
            reapplyTransparency()
        }
    }

    /// Best-effort detection of whether the frontmost app has a fullscreen
    /// window covering the screen (layer 0, on-screen, screen-sized bounds).
    /// Bounds/layer need no screen-recording permission (only names do).
    private func isFullscreenAppActive() -> Bool {
        guard let screenFrame = window?.screen?.frame else { return false }
        let minW = screenFrame.width * 0.97
        let minH = screenFrame.height * 0.97
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let frontPID = Int(
            NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        )
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid == frontPID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double else { continue }
            if w >= minW && h >= minH {
                return true
            }
        }
        return false
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
            withTitle: "退出 BA Click",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    /// Menu bar (status) icon using the Blue Archive bar icon.
    /// Rendered at 22pt (chosen for clarity). The bar icon artwork was shrunk
    /// inside the SVG canvas so the glyph reads well at this size;
    /// 22px = 1x, 44px = 2x at 22pt.
    /// Clicking the icon shows a menu: open/close the management panel, quit.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(size: NSSize(width: 22, height: 22))
            if let rep = loadIcon(name: "bar_icon_22")?.representations.first {
                rep.size = NSSize(width: 22, height: 22)
                image.addRepresentation(rep)
            }
            if let rep = loadIcon(name: "bar_icon_44")?.representations.first {
                rep.size = NSSize(width: 22, height: 22)
                image.addRepresentation(rep)
            }
            image.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开管理面板",
            action: #selector(togglePanel(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)
        openMenuItem = openItem
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 BA Click",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel(_ sender: Any?) {
        settingsPanel?.toggle()
        updateOpenMenuTitle()
    }

    private func updateOpenMenuTitle() {
        openMenuItem?.title = (settingsPanel?.isVisible ?? false)
            ? "关闭管理面板"
            : "打开管理面板"
    }

    private func loadIcon(name: String) -> NSImage? {
        guard let url = findResourceURL(name: name, ext: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
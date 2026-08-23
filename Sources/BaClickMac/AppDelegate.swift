import AppKit
import MetalKit
import QuartzCore
import CoreGraphics
import simd

final class AppDelegate: NSObject, NSApplicationDelegate {
    private final class Overlay {
        let window: NSWindow
        let view: TransparentMTKView
        let renderer: Renderer
        var screenFrame: NSRect

        init(window: NSWindow, view: TransparentMTKView, renderer: Renderer, screenFrame: NSRect) {
            self.window = window
            self.view = view
            self.renderer = renderer
            self.screenFrame = screenFrame
        }
    }

    private var overlays: [Overlay] = []
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
    /// Manual render loop driver: CADisplayLink (vsync-synced, macOS 14+) or a
    /// fallback Timer. We call MTKView.draw() ourselves so rendering never
    /// depends on the MTKView's own (fragile) display-link lifecycle.
    private var renderTimer: Timer?
    private var renderDisplayLink: CADisplayLink?
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
        setupStatusItem()

        guard !NSScreen.screens.isEmpty || NSScreen.main != nil else {
            bail("No screen available")
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            bail("Metal is not supported on this Mac")
        }

        overlays = makeOverlays(device: device)
        guard let primaryOverlay = overlays.first else {
            bail("Failed to initialize overlay windows")
        }
        window = primaryOverlay.window
        overlayView = primaryOverlay.view
        renderer = primaryOverlay.renderer
        overlays.forEach { $0.window.orderFrontRegardless() }

        self.reapplyTransparency()

        // Management panel + live settings wiring: every panel change applies
        // to the renderer immediately and (if the render timer is running)
        // restarts it at the new refresh rate.
        settingsPanel = SettingsPanelController(store: store)
        currentRenderInterval = 1.0 / Double(max(1, store.model.refreshRate))
        store.onChange = { [weak self] in
            guard let self else { return }
            self.applySettingsToRenderers()
            self.syncRenderTimer()
            if !self.store.model.enabled {
                self.overlays.forEach { $0.renderer.particleSystem.clear() }
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
                // Display layout may have changed: re-read the virtual desktop
                // frame and resize the overlay to cover every attached screen.
                self.updateOverlayGeometry()
                // Don't fight the intentional hide used for fullscreen apps.
                guard !self.fullscreenHidden else { return }
                self.startRenderTimer()
                // Recompute fullscreen state immediately (e.g. on app
                // activation / Space change) instead of waiting for the next
                // 0.5s housekeeping tick.
                self.updateFullscreenState()
                self.reapplyTransparency()
                self.overlays.forEach { $0.window.orderFrontRegardless() }
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
            label.frame = NSRect(x: 20, y: primaryOverlay.screenFrame.height - 50, width: 800, height: 26)
            label.isBezeled = false
            label.drawsBackground = false
            label.textColor = .white
            label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            primaryOverlay.view.addSubview(label)
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
        //
        // The event callbacks only WAKE the render loop; the actual trail
        // sampling happens every render tick (renderTick) so the trail stays
        // dense even when events are coalesced. The click still feeds directly.
        let monitor = MouseMonitor()
        monitor.onMouseDown = { [weak self] point in
            guard let self, self.store.model.enabled else { return }
            self.startRenderTimer() // wake the idle-stopped render loop
            if let routed = self.overlay(containing: point) {
                routed.overlay.renderer.particleSystem.addClick(at: routed.localPoint)
            }
        }
        monitor.onMouseDrag = { [weak self] _ in
            guard let self, self.store.model.enabled else { return }
            self.startRenderTimer()
        }
        monitor.onMouseMove = { [weak self] _ in
            // Trail follows a free move only when "always visible" is on;
            // dragging (left button held) always wakes it.
            guard let self, self.store.model.enabled, self.store.model.trailAlwaysVisible else { return }
            self.startRenderTimer()
        }
        monitor.start()
        mouseMonitor = monitor

        // BA_CLICK_LOOP=1 auto-spawns a click at screen center every 0.9s so
        // the click animation (disk -> arcs -> shrink) can be inspected in
        // isolation without the cursor trail.
        if getenv("BA_CLICK_LOOP") != nil {
            let loop = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
                guard let self, self.store.model.enabled else { return }
                guard let screenFrame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame else { return }
                let centerPoint = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
                self.startRenderTimer()
                if let routed = self.overlay(containing: centerPoint) {
                    routed.overlay.renderer.particleSystem.addClick(at: routed.localPoint)
                }
            }
            RunLoop.main.add(loop, forMode: .common)
            clickLoopTimer = loop
        }

        // NOTE: do NOT call NSApp.activate(...) here. If our app becomes
        // frontmost, AppKit's global mouse monitor stops receiving clicks from
        // our own app and the effect appears dead until the user focuses
        // another application.
    }

    private func makeOverlays(device: MTLDevice) -> [Overlay] {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        return screens.compactMap { screen in
            makeOverlay(device: device, screen: screen)
        }
    }

    private func makeOverlay(device: MTLDevice, screen: NSScreen) -> Overlay? {
        let frame = screen.frame
        let panel = NSPanel(
            // When a specific NSScreen is supplied, AppKit treats contentRect
            // as screen-local. Passing the global screen frame would apply the
            // screen origin twice for displays left/below the main screen.
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(frame, display: false)
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

        let view = TransparentMTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = false

        guard let renderer = Renderer(view: view) else { return nil }
        renderer.applySettings(store.model)
        panel.contentView = view
        return Overlay(window: panel, view: view, renderer: renderer, screenFrame: frame)
    }

    private func applySettingsToRenderers() {
        overlays.forEach { $0.renderer.applySettings(store.model) }
    }

    private func overlay(containing point: NSPoint) -> (overlay: Overlay, localPoint: SIMD2<Float>)? {
        let geometry = ScreenGeometry.shared
        if let overlay = overlays.first(where: { Self.contains(point, in: $0.screenFrame) }) {
            return (overlay, geometry.convert(point, in: overlay.screenFrame))
        }
        guard let nearest = overlays.min(by: {
            Self.distanceSquared(from: point, to: $0.screenFrame) <
                Self.distanceSquared(from: point, to: $1.screenFrame)
        }) else { return nil }
        return (nearest, geometry.convert(point, in: nearest.screenFrame))
    }

    private static func contains(_ point: NSPoint, in frame: NSRect) -> Bool {
        point.x >= frame.minX &&
            point.x <= frame.maxX &&
            point.y >= frame.minY &&
            point.y <= frame.maxY
    }

    private static func distanceSquared(from point: NSPoint, to frame: NSRect) -> CGFloat {
        let clampedX = min(max(point.x, frame.minX), frame.maxX)
        let clampedY = min(max(point.y, frame.minY), frame.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    /// Re-assert the CAMetalLayer transparency. The layer can reset its
    /// opaque/background state when the view is re-attached (after a Spaces
    /// switch or when moved between primary window and fullscreen panel),
    /// which otherwise makes the overlay disappear.
    private func reapplyTransparency() {
        DispatchQueue.main.async {
            for overlay in self.overlays {
                overlay.view.wantsLayer = true
                overlay.view.layer?.isOpaque = false
                overlay.view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    /// Keep one transparent overlay aligned with each attached display.
    private func updateOverlayGeometry() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let frames = screens.map(\.frame)
        let needsRebuild = frames.count != overlays.count ||
            zip(frames, overlays.map(\.screenFrame)).contains { !$0.equalTo($1) }

        if needsRebuild, let device = overlayView?.device ?? MTLCreateSystemDefaultDevice() {
            let label = statusLabel
            overlays.forEach { $0.window.orderOut(nil) }
            overlays = screens.compactMap { makeOverlay(device: device, screen: $0) }
            guard let primaryOverlay = overlays.first else { return }
            window = primaryOverlay.window
            overlayView = primaryOverlay.view
            renderer = primaryOverlay.renderer
            if let label {
                label.removeFromSuperview()
                label.frame.origin.y = primaryOverlay.screenFrame.height - 50
                primaryOverlay.view.addSubview(label)
            }
            if !fullscreenHidden {
                overlays.forEach { $0.window.orderFrontRegardless() }
            }
            return
        }

        for (overlay, screen) in zip(overlays, screens) {
            let frame = screen.frame
            overlay.screenFrame = frame
            overlay.window.setFrame(frame, display: true)
            overlay.view.frame = NSRect(origin: .zero, size: frame.size)
            overlay.view.bounds = NSRect(origin: .zero, size: frame.size)
        }
        if let first = overlays.first {
            statusLabel?.frame.origin.y = first.screenFrame.height - 50
        }
    }

    /// Watchdog: with the manual render timer, a stall can only happen if the
    /// main runloop was blocked (Space animation, Mission Control, etc.). If
    /// the timer is running but no draw callback has fired for >0.5s, force
    /// one frame immediately and reassert the layer.
    private func checkStall() {
        guard !overlays.isEmpty else { return }
        // If we intentionally stopped rendering for a fullscreen app, that's
        // not a stall — don't wake it up to burn GPU behind the fullscreen app.
        if fullscreenHidden { return }
        // If we intentionally stopped rendering while idle (see
        // startRenderTimer), that's not a stall either.
        guard renderTimer != nil || renderDisplayLink != nil else { return }
        let now = CACurrentMediaTime()
        let stalled = overlays.contains { overlay in
            overlay.renderer.lastDrawTime == 0 || now - overlay.renderer.lastDrawTime > Self.stallThreshold
        }
        if stalled {
            // The driver may have stalled (e.g. display link after a Space
            // switch): rebuild it and force a frame now.
            stopRenderTimer()
            startRenderTimer()
            overlays.forEach {
                $0.view.draw()
                $0.window.orderFrontRegardless()
            }
            reapplyTransparency()
        }
    }

    /// Start the manual render loop at the configured refresh rate
    /// (idempotent). Uses a vsync-synced CADisplayLink on macOS 14+ (smooth,
    /// no frame-phase jitter), falling back to a Timer on macOS 13. The MTKView
    /// keeps its own display link paused; we call draw() ourselves so rendering
    /// never depends on the MTKView's fragile display-link lifecycle.
    ///
    /// Power saving: the loop stops itself as soon as nothing is on screen
    /// (idle -> zero GPU work). Clicks / mouse moves / the click-loop wake it
    /// up again.
    private func startRenderTimer() {
        guard renderTimer == nil, renderDisplayLink == nil, let overlayView else { return }
        overlays.forEach { $0.view.isPaused = true }
        if #available(macOS 14.0, *) {
            let link = overlayView.displayLink(target: self, selector: #selector(renderTick))
            link.preferredFrameRateRange = frameRateRange(for: store.model.refreshRate)
            link.add(to: .main, forMode: .common)
            renderDisplayLink = link
        } else {
            let timer = Timer(timeInterval: currentRenderInterval, repeats: true) { [weak self] _ in
                self?.renderTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            renderTimer = timer
        }
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
        renderDisplayLink?.invalidate()
        renderDisplayLink = nil
    }

    @available(macOS 14.0, *)
    private func frameRateRange(for rate: Int) -> CAFrameRateRange {
        CAFrameRateRange(minimum: 24, maximum: 240, preferred: Float(max(1, rate)))
    }

    /// One render tick (called by the display link / fallback timer).
    ///
    /// Samples the live mouse position every frame so the trail stays dense
    /// (smooth curves, no polylines) even when the OS coalesces mouse-moved
    /// events while the main thread is busy rendering.
    @objc private func renderTick() {
        guard !overlays.isEmpty else { return }
        if store.model.enabled {
            let dragging = (NSEvent.pressedMouseButtons & 1) != 0
            if store.model.trailAlwaysVisible || dragging {
                let point = NSEvent.mouseLocation
                if let routed = overlay(containing: point) {
                    routed.overlay.renderer.particleSystem.addTrailPoint(at: routed.localPoint)
                }
            }
        }
        overlays.forEach { $0.view.draw() }
        // Nothing left on screen -> stop until the next interaction.
        if !overlays.contains(where: { $0.renderer.particleSystem.hasActiveParticles() }) {
            stopRenderTimer()
        }
    }

    /// Update the driver if the effect refresh rate changed while it is
    /// running (idle-stopped drivers pick up the new rate on their next wake).
    private func syncRenderTimer() {
        let interval = 1.0 / Double(max(1, store.model.refreshRate))
        if abs(interval - currentRenderInterval) > 0.0001 {
            currentRenderInterval = interval
            if #available(macOS 14.0, *) {
                renderDisplayLink?.preferredFrameRateRange = frameRateRange(for: store.model.refreshRate)
            }
            if renderTimer != nil {
                stopRenderTimer()
                startRenderTimer()
            }
        }
    }

    /// Fullscreen handling for the persistent per-screen NSPanels:
    ///  - showInFullscreen=true (default): each panel is already a
    ///    fullScreenAuxiliary member of every Space, so macOS carries it into
    ///    the fullscreen app's Space automatically — nothing to do here.
    ///  - showInFullscreen=false: when a fullscreen app is active, hide + stop
    ///    rendering so no GPU work happens behind it; resume on desktop.
    private func updateFullscreenState() {
        guard let renderer else { return }
        // When we always keep the overlay over fullscreen apps (the default),
        // there is nothing to hide or resume — skip the window-list polling.
        if renderer.settings.showInFullscreen { return }
        let fullscreen = isFullscreenAppActive()
        if fullscreen == lastFullscreenState { return }
        lastFullscreenState = fullscreen

        if fullscreen {
            fullscreenHidden = true
            stopRenderTimer()
            overlays.forEach { $0.window.orderOut(nil) }
        } else {
            fullscreenHidden = false
            startRenderTimer()
            overlays.forEach {
                $0.window.level = .floating
                $0.window.orderFrontRegardless()
            }
            reapplyTransparency()
        }
    }

    /// Best-effort detection of whether the frontmost app has a fullscreen
    /// window covering the screen (layer 0, on-screen, screen-sized bounds).
    /// Bounds/layer need no screen-recording permission (only names do).
    private func isFullscreenAppActive() -> Bool {
        let screenFrames = NSScreen.screens.map(\.frame)
        guard !screenFrames.isEmpty else { return false }
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
            let coversAnyScreen = screenFrames.contains { frame in
                w >= frame.width * 0.97 && h >= frame.height * 0.97
            }
            if coversAnyScreen {
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
        // Static "open" item: the panel is closed via its own traffic-light
        // button, so the menu item never toggles its label.
        let openItem = NSMenuItem(
            title: L10n.t("openPanel"),
            action: #selector(openPanel(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: L10n.t("quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel(_ sender: Any?) {
        // Idempotent: opens the panel, or brings it forward if already open.
        settingsPanel?.show()
    }

    private func loadIcon(name: String) -> NSImage? {
        guard let url = findResourceURL(name: name, ext: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

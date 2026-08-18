import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var mouseMonitor: MouseMonitor?
    private var renderer: Renderer?

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

        let renderer = Renderer(view: overlayView)
        self.renderer = renderer
        window.contentView = overlayView
        window.orderFrontRegardless()

        // Re-apply transparency after the view is attached to the window; the
        // CAMetalLayer can reset its opaque/background state during attach.
        DispatchQueue.main.async { [weak overlayView] in
            overlayView?.wantsLayer = true
            overlayView?.layer?.isOpaque = false
            overlayView?.layer?.backgroundColor = NSColor.clear.cgColor
        }

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

        self.window = window

        // NOTE: do NOT call NSApp.activate(...) here. If our app becomes
        // frontmost, AppKit's global mouse monitor stops receiving clicks from
        // our own app and the effect appears dead until the user focuses
        // another application.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
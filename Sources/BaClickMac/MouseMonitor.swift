import AppKit
import simd

/// Observes global mouse events so the overlay can react to clicks and movement
/// anywhere on the screen while remaining click-through.
final class MouseMonitor {
    var onMouseDown: ((SIMD2<Float>) -> Void)?
    /// Right button click (button 2). Only fires when the panel toggle is on
    /// (the AppDelegate applies the toggle; the monitor just reports events).
    var onRightMouseDown: ((SIMD2<Float>) -> Void)?
    /// Middle button click (button 3).
    var onMiddleMouseDown: ((SIMD2<Float>) -> Void)?
    /// Left button held + dragging (always feeds the trail).
    var onMouseDrag: ((SIMD2<Float>) -> Void)?
    /// Plain mouse move, no button (feeds the trail only when "always visible").
    var onMouseMove: ((SIMD2<Float>) -> Void)?

    private var monitor: Any?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .leftMouseDown, .leftMouseDragged,
                .rightMouseDown, .rightMouseDragged,
                .otherMouseDown, .otherMouseDragged,
                .mouseMoved
            ]
        ) { [weak self] event in
            guard let self else { return }
            let point = ScreenGeometry.shared.convert(NSEvent.mouseLocation)
            switch event.type {
            case .leftMouseDown:
                self.onMouseDown?(point)
            case .rightMouseDown:
                self.onRightMouseDown?(point)
            case .otherMouseDown:
                // .otherMouseDown covers buttons 3+; we only care about the
                // middle button (buttonNumber == 2).
                if event.buttonNumber == 2 {
                    self.onMiddleMouseDown?(point)
                }
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                // Any held button dragging feeds the trail.
                self.onMouseDrag?(point)
            case .mouseMoved:
                self.onMouseMove?(point)
            default:
                break
            }
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

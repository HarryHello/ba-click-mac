import AppKit

/// Observes global mouse events so the overlay can react to clicks and movement
/// anywhere on the screen while remaining click-through.
final class MouseMonitor {
    var onMouseDown: ((NSPoint) -> Void)?
    /// Left button held + dragging (always feeds the trail).
    var onMouseDrag: ((NSPoint) -> Void)?
    /// Plain mouse move, no button (feeds the trail only when "always visible").
    var onMouseMove: ((NSPoint) -> Void)?

    private var monitor: Any?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown:
                self.onMouseDown?(point)
            case .leftMouseDragged:
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

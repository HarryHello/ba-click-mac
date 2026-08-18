import AppKit
import simd

/// Observes global mouse events so the overlay can react to clicks and movement
/// anywhere on the screen while remaining click-through.
final class MouseMonitor {
    var onMouseDown: ((SIMD2<Float>) -> Void)?
    var onMouseMove: ((SIMD2<Float>) -> Void)?

    private let screenFrame: NSRect
    private var monitor: Any?

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return }
            let point = self.convert(NSEvent.mouseLocation)
            switch event.type {
            case .leftMouseDown:
                self.onMouseDown?(point)
            case .leftMouseDragged, .mouseMoved:
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

    private func convert(_ point: NSPoint) -> SIMD2<Float> {
        SIMD2(
            Float(point.x - screenFrame.origin.x),
            Float(point.y - screenFrame.origin.y)
        )
    }
}
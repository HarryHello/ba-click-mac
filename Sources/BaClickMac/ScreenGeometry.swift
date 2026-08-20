import AppKit
import simd

/// Shared screen geometry: converts global mouse coordinates (bottom-left
/// origin) to the overlay's local coordinates. The frame is refreshed on
/// demand (and on display changes) so resolution/layout changes never leave
/// stale offsets — used by both the mouse monitor and the render tick.
final class ScreenGeometry {
    static let shared = ScreenGeometry()

    private(set) var screenFrame: NSRect

    private init() {
        screenFrame = Self.currentMainFrame()
    }

    /// Re-read the main screen frame (call on didChangeScreenParameters).
    func refresh() {
        screenFrame = Self.currentMainFrame()
    }

    func convert(_ point: NSPoint) -> SIMD2<Float> {
        SIMD2(
            Float(point.x - screenFrame.origin.x),
            Float(point.y - screenFrame.origin.y)
        )
    }

    static func currentMainFrame() -> NSRect {
        NSScreen.main?.frame ?? .zero
    }
}

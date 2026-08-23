import AppKit
import simd

/// Shared screen geometry: converts global mouse coordinates (bottom-left
/// origin) to an overlay window's local coordinates. Each physical display gets
/// its own overlay window because macOS does not reliably show one giant
/// transparent window across every screen/Space configuration.
final class ScreenGeometry {
    static let shared = ScreenGeometry()

    private init() {}

    func convert(_ point: NSPoint, in frame: NSRect) -> SIMD2<Float> {
        SIMD2(
            Float(point.x - frame.origin.x),
            Float(point.y - frame.origin.y)
        )
    }
}

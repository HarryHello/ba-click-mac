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

    /// Index of the frame containing `point`. When no frame contains it
    /// (gaps in a non-aligned display layout), the index of the nearest
    /// frame, so clicks right at a display edge still land somewhere sane.
    /// Nil only when `frames` is empty.
    static func frameIndex(for point: NSPoint, in frames: [NSRect]) -> Int? {
        if let index = frames.firstIndex(where: { contains(point, in: $0) }) {
            return index
        }
        var nearest: (index: Int, distance: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let distance = distanceSquared(from: point, to: frame)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        return nearest?.index
    }

    private static func contains(_ point: NSPoint, in frame: NSRect) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX &&
            point.y >= frame.minY && point.y <= frame.maxY
    }

    private static func distanceSquared(from point: NSPoint, to frame: NSRect) -> CGFloat {
        let clampedX = min(max(point.x, frame.minX), frame.maxX)
        let clampedY = min(max(point.y, frame.minY), frame.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

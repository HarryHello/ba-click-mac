import AppKit
import MetalKit

/// MTKView that reports itself as non-opaque so AppKit/WindowServer
/// keeps the overlay transparent.
final class TransparentMTKView: MTKView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
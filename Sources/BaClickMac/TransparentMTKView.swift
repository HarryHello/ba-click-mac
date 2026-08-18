import MetalKit

/// MTKView that reports itself as non-opaque so AppKit/WindowServer
/// keeps the overlay transparent.
final class TransparentMTKView: MTKView {
    override var isOpaque: Bool { false }
}
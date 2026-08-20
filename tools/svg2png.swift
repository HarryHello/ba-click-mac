import AppKit
import Foundation

// Render an SVG to a PNG at an exact pixel size.
// Uses AppKit's NSImage (SVG support since macOS 10.15) — no external tools.
//
// Usage: swift tools/svg2png.swift <input.svg> <output.png> <pixelSize>
//
// Example:
//   swift tools/svg2png.swift icons/bar_icon.svg Resources/bar_icon_22.png 22
//   swift tools/svg2png.swift icons/bar_icon.svg Resources/bar_icon_44.png 44

let args = CommandLine.arguments
guard args.count == 4,
      let px = Int(args[3]),
      px > 0 else {
    FileHandle.standardError.write(Data("usage: swift tools/svg2png.swift <input.svg> <output.png> <pixelSize>\n".utf8))
    exit(2)
}

let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: inURL) else {
    FileHandle.standardError.write(Data("error: cannot load SVG \(args[1])\n".utf8))
    exit(1)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: px,
    pixelsHigh: px,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("error: cannot create bitmap \(px)x\(px)\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(
    in: NSRect(x: 0, y: 0, width: px, height: px),
    from: .zero,
    operation: .copy,
    fraction: 1.0
)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: outURL)
} catch {
    FileHandle.standardError.write(Data("error: cannot write \(args[2]): \(error)\n".utf8))
    exit(1)
}
print("✅ \(args[2]) \(px)x\(px)")

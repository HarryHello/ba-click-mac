// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BaClickMac",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BaClickMac",
            path: "Sources/BaClickMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
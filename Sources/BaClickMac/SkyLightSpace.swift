import AppKit
import Darwin

/// Minimal SkyLight (private framework) interop for force-topmost mode:
/// creates a dedicated Space pinned above the screen-lock level and moves
/// windows into it, so they render above EVERYTHING — menus, Dock,
/// launchers, even the lock screen.
///
/// Private API, resolved lazily via dlopen and guarded throughout: when
/// anything fails, `available` is false and callers simply keep the normal
/// window level. This app ships outside the App Store, so the private-API
/// tradeoff is acceptable for an opt-in feature.
final class SkyLightSpace {
    static let shared = SkyLightSpace()

    /// Absolute space levels observed in SkyLight (screen lock = 300; the
    /// notification center renders above it).
    enum AbsoluteLevel: Int32 {
        case setupAssistant = 100
        case securityAgent = 200
        case screenLock = 300
        case notificationCenterAtScreenLock = 400
    }

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let addWindows: F_SLSSpaceAddWindowsAndRemoveFromSpaces?
    private let showSpaces: F_SLSShowSpaces?
    private var space: Int32 = -1

    private init() {
        let handler = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        )
        let main: F_SLSMainConnectionID? = Self.symbol(handler, "SLSMainConnectionID")
        let create: F_SLSSpaceCreate? = Self.symbol(handler, "SLSSpaceCreate")
        let setLevel: F_SLSSpaceSetAbsoluteLevel? = Self.symbol(handler, "SLSSpaceSetAbsoluteLevel")
        showSpaces = Self.symbol(handler, "SLSShowSpaces")
        addWindows = Self.symbol(handler, "SLSSpaceAddWindowsAndRemoveFromSpaces")

        var cid: Int32 = -1
        var created: Int32 = -1
        if let main, let create, let setLevel {
            cid = main()
            created = create(cid, 1, 0)
            if created >= 0 {
                _ = setLevel(cid, created, AbsoluteLevel.notificationCenterAtScreenLock.rawValue)
            }
        }
        connection = cid
        space = created
        if space >= 0, let showSpaces {
            _ = showSpaces(connection, [space] as CFArray)
        }
    }

    /// True when the high-level space exists and windows can be delegated.
    var available: Bool { space >= 0 && addWindows != nil }

    /// Move `window` into the high-level space, removing it from all normal
    /// Spaces. The window keeps rendering there until it is destroyed.
    func delegateWindow(_ window: NSWindow) {
        guard available, window.windowNumber >= 0, let addWindows, let showSpaces else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        _ = showSpaces(connection, [space] as CFArray)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

import Foundation
import IOKit.ps

/// AC/battery power state via IOKit power sources, with change notifications.
/// Machines without a battery (desktops) report no power sources and are
/// treated as always plugged in, so the battery-saver toggle is a no-op there.
final class PowerMonitor {
    /// Fired on the main thread whenever the power state may have changed
    /// (and once right after `start()`). Readers must re-query `isOnACPower`.
    var onPowerStateChanged: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    /// True on AC power; false on battery. No power sources at all (desktops,
    /// or IOKit unavailable) counts as AC so effects are never suppressed.
    static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        var sawAnySource = false
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            sawAnySource = true
            if state == kIOPSACPowerValue {
                return true
            }
        }
        // Sources exist but none on AC (e.g. a discharging battery) -> battery.
        return !sawAnySource
    }

    /// Subscribe to power-source change notifications (idempotent) and fire
    /// `onPowerStateChanged` once for the initial state.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { rawContext in
                guard let rawContext else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(rawContext).takeUnretainedValue()
                DispatchQueue.main.async { monitor.onPowerStateChanged?() }
            },
            context
        )?.takeRetainedValue() else {
            dlog("[power] could not create power-source notification source")
            return
        }
        // (Swift's CFRunLoopMode is a thin struct over CFString; there is no
        // .commonMode member on this SDK, so build the mode from RunLoop's.)
        let commonModes = CFRunLoopMode(RunLoop.Mode.common.rawValue as CFString)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, commonModes)
        runLoopSource = source
        onPowerStateChanged?()
    }
}

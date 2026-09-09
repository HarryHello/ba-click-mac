import AppKit
import Darwin

// Single instance: launch-at-login and double-opening the .app must not
// stack a second overlay (double-drawn effects, racing settings writes).
// Runs before any AppKit/monitor setup; the loser exits immediately.
guard SingleInstance.acquire() else {
    dlog("[instance] another BA Click is already running — exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: no Dock icon, no menu bar — the app lives in the menu bar
// (status item) + the management panel only, and stays non-frontmost so the
// global mouse monitor keeps receiving clicks/trails.
app.setActivationPolicy(.accessory)
app.run()
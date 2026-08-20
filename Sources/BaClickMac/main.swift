import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: no Dock icon, no menu bar — the app lives in the menu bar
// (status item) + the management panel only, and stays non-frontmost so the
// global mouse monitor keeps receiving clicks/trails.
app.setActivationPolicy(.accessory)
app.run()
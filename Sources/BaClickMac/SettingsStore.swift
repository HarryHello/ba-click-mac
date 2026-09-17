import Foundation
import Combine
import SwiftUI
import Darwin
import ServiceManagement

/// Single source of truth for all runtime settings. The management panel and
/// the renderer both read from here; changes are applied immediately (via
/// `onChange`) and persisted (debounced) to `settings.json`.
final class SettingsStore: ObservableObject {
    @Published var model: FXSettings

    /// Whether the app starts at login. This is system state (a LaunchAgent
    /// plist), NOT persisted in settings.json; the toggle writes it through.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isSettingLaunchAtLogin else { return }
            isSettingLaunchAtLogin = true
            defer { isSettingLaunchAtLogin = false }
            if !LoginItem.setEnabled(launchAtLogin) {
                // Registration failed (e.g. unwritable path): revert the switch
                // so the UI doesn't claim a state the system doesn't have.
                launchAtLogin = oldValue
                dlog("[login] failed to change launch-at-login")
            }
        }
    }

    private var isSettingLaunchAtLogin = false

    /// Called on the main thread after any setting changed, so the app can
    /// apply it to the renderer / restart the render timer.
    var onChange: (() -> Void)?

    private var persistTimer: Timer?

    init() {
        model = FXSettings.load()
        launchAtLogin = LoginItem.isEnabled
    }

    /// SwiftUI binding to a persisted setting; writes trigger live apply +
    /// debounced persist.
    func binding<T>(_ keyPath: WritableKeyPath<FXSettings, T>) -> Binding<T> {
        Binding(
            get: { self.model[keyPath: keyPath] },
            set: { newValue in
                self.model[keyPath: keyPath] = newValue
                self.changed()
            }
        )
    }

    /// Binding for the unified "click effect size" control: writes the same
    /// value to disk, rings and click shards together.
    func clickScaleBinding() -> Binding<Float> {
        Binding(
            get: { self.model.diskScale },
            set: { value in
                self.model.diskScale = value
                self.model.ringScale = value
                self.model.shardScale = value
                self.changed()
            }
        )
    }

    /// Count one click effect (no-op unless the statistics toggle is on);
    /// persisted with the usual debounced write.
    func registerClick() {
        guard model.clickCountEnabled else { return }
        model.clickCount += 1
        changed()
    }

    /// Restore every persisted SETTING to its default. Launch-at-login is
    /// system state and the click counter is statistics — neither is touched.
    func resetToDefaults() {
        let preservedCount = model.clickCount
        model = FXSettings()
        model.clickCount = preservedCount
        changed()
    }

    private func changed() {
        // Sync the L10n override SYNCHRONOUSLY: SwiftUI re-renders the panel
        // before the async onChange fires, and an out-of-sync L10n made the
        // language picker render the PREVIOUS selection.
        L10n.language = L10n.Language(rawValue: model.language) ?? .system
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
        schedulePersist()
    }

    private func schedulePersist() {
        persistTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.persist()
        }
        RunLoop.main.add(timer, forMode: .common)
        persistTimer = timer
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(model) else { return }
        do {
            try data.write(to: FXSettings.persistURL())
        } catch {
            dlog("[settings] could not persist: \(error)")
        }
    }
}

/// Launch-at-login. Bundled apps (the normal case) register through
/// SMAppService, so the entry lives in System Settings → General → Login
/// Items like every other app's — and registering never starts the app on
/// the spot. The raw command-line binary (dev, run.sh) can't self-register
/// there and falls back to a user LaunchAgent plist. Both states count as
/// enabled; legacy plist registrations migrate to SMAppService on the next
/// toggle.
enum LoginItem {
    static let label = "local.ba-click-mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var isBundledApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        if isBundledApp, SMAppService.mainApp.status == .enabled {
            return true
        }
        // Legacy pre-SMAppService registration (0.1.x–0.2.1) still works.
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Returns true on success (toggle stays up; reverts the switch on false).
    static func setEnabled(_ enabled: Bool) -> Bool {
        if isBundledApp {
            if enabled {
                // Drop any legacy LaunchAgent first so the app can't be
                // auto-started twice (once per mechanism).
                _ = disableLegacy()
                if registerMainApp() { return true }
                // SMAppService refused (signature / bundle oddities) — the
                // legacy plist path still honors the user's intent.
                return enableLegacy()
            }
            unregisterMainApp()
            _ = disableLegacy()
            return true
        }
        return enabled ? enableLegacy() : disableLegacy()
    }

    // MARK: SMAppService (bundled app)

    private static func registerMainApp() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            dlog("[login] SMAppService register failed: \(error)")
            return false
        }
    }

    private static func unregisterMainApp() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            dlog("[login] SMAppService unregister failed: \(error)")
        }
    }

    // MARK: LaunchAgent fallback (raw binary)

    private static func executablePath() -> String {
        if let exe = Bundle.main.executableURL {
            return exe.path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
    }

    private static func enableLegacy() -> Bool {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            dlog("[login] failed to serialize LaunchAgent plist")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL)
        } catch {
            dlog("[login] could not write \(plistURL.path): \(error)")
            return false
        }
        // `bootstrap` runs a RunAtLoad job immediately — a plain call would
        // spawn a second instance right as the user flips the toggle (and
        // `bootout` would then kill it again). Register the job disabled,
        // then re-enable: it stays dormant until the next login.
        let domain = "gui/\(getuid())"
        _ = runLaunchCtl("disable", "\(domain)/\(label)")
        guard runLaunchCtl("bootstrap", domain, plistURL.path) else {
            _ = runLaunchCtl("enable", "\(domain)/\(label)")
            return false
        }
        guard runLaunchCtl("enable", "\(domain)/\(label)") else {
            _ = runLaunchCtl("bootout", "\(domain)/\(label)")
            return false
        }
        return true
    }

    private static func disableLegacy() -> Bool {
        // NOTE: `bootout` terminates the job's process — if this running app
        // was itself launched by the agent (at login), toggling off quits it.
        _ = runLaunchCtl("bootout", "gui/\(getuid())/\(label)")
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            return true
        } catch {
            dlog("[login] could not remove \(plistURL.path): \(error)")
            return false
        }
    }

    private static func runLaunchCtl(_ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            dlog("[login] launchctl \(arguments) failed: \(error)")
            return false
        }
    }
}

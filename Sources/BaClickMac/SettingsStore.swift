import Foundation
import Combine
import SwiftUI
import Darwin

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

    private func changed() {
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

/// Launch-at-login via a user LaunchAgent plist. Works for both the raw binary
/// (run.sh) and the .app bundle.
enum LoginItem {
    static let label = "local.ba-click-mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Returns true on success (plist written + launchctl accepted).
    static func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }

    private static func executablePath() -> String {
        if let exe = Bundle.main.executableURL {
            return exe.path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
    }

    private static func enable() -> Bool {
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
        return runLaunchCtl("bootstrap", "gui/\(getuid())", plistURL.path)
    }

    private static func disable() -> Bool {
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

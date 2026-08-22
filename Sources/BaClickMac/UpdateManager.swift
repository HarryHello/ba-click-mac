import Foundation
import Combine
import AppKit

/// Result states surfaced in the management panel's update row.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case installing
    case failed(String)
}

/// Checks GitHub for a newer BA Click release and — when possible — performs a
/// self-update: downloads the matching DMG, mounts it, replaces the running
/// app bundle via a detached helper script, and relaunches. When auto-update
/// isn't possible (raw binary, unwritable bundle location, or any failure) it
/// falls back to opening the GitHub Releases page so the user can grab the
/// DMG manually.
final class UpdateManager: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var latestVersion: String?
    /// Download progress 0...1 while `.downloading`.
    @Published private(set) var downloadProgress: Double = 0

    private let session: URLSession
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    /// The latest-release JSON from the GitHub API (kept for the asset lookup).
    private var latestRelease: [String: Any]?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    // MARK: - Public actions

    /// Query the GitHub API for the latest published release and compare it
    /// with the running version. Never throws — failures surface as `.failed`.
    func checkForUpdates() {
        guard state != .checking else { return }
        state = .checking
        latestVersion = nil
        latestRelease = nil

        var request = URLRequest(url: AppInfo.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BA-Click-mac/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = object["tag_name"] as? String else {
                    self.state = .failed(L10n.t("updateCheckFailed"))
                    return
                }
                self.latestRelease = object
                self.latestVersion = UpdateManager.versionString(tag)
                let latest = UpdateManager.normalizeVersion(tag)
                let current = UpdateManager.normalizeVersion(AppInfo.version)
                self.state = UpdateManager.compare(current, latest) < 0 ? .updateAvailable : .upToDate
            }
        }
        task.resume()
    }

    /// Open the repository home page in the browser.
    func openRepository() {
        NSWorkspace.shared.open(AppInfo.repoURL)
    }

    /// Open the Releases page in the browser.
    func openReleases() {
        NSWorkspace.shared.open(AppInfo.releasesURL)
    }

    /// Download + install the update for the running architecture. Falls back
    /// to opening the Releases page whenever auto-update can't be done.
    func installUpdate() {
        guard case .updateAvailable = state else { return }
        guard let release = latestRelease,
              let assets = release["assets"] as? [[String: Any]],
              let target = assets.first(where: {
                  ($0["name"] as? String)?.contains("\(AppInfo.archSuffix).dmg") ?? false
              }),
              let urlString = target["browser_download_url"] as? String,
              let url = URL(string: urlString) else {
            fallbackToReleases()
            return
        }
        // Auto-update requires a real .app bundle in a writable location.
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"),
              canReplaceBundle(at: bundlePath) else {
            fallbackToReleases()
            return
        }

        state = .downloading
        downloadProgress = 0
        let task = session.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressObservation = nil
                guard let tempURL, error == nil else {
                    self.state = .failed(L10n.t("updateDownloadFailed"))
                    self.openReleases()
                    return
                }
                self.installFromDMG(at: tempURL, currentApp: bundlePath)
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = min(max(progress.fractionCompleted, 0), 1)
            }
        }
        downloadTask = task
        task.resume()
    }

    // MARK: - Auto-update internals

    /// True when the bundle's parent directory is writable, so the helper can
    /// `rm -rf` + `ditto` the bundle back into place without admin rights.
    private func canReplaceBundle(at path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: parent)
    }

    private func fallbackToReleases() {
        state = .failed(L10n.t("updateNotPossible"))
        openReleases()
    }

    /// Mount the (already downloaded) DMG, locate the app inside, and hand the
    /// replacement + relaunch off to a detached helper script.
    private func installFromDMG(at tempURL: URL, currentApp: String) {
        let fm = FileManager.default

        // URLSession manages tempURL's lifetime; copy to a stable location.
        let dmgURL = fm.temporaryDirectory
            .appendingPathComponent("BA-Click-\(AppInfo.version)-\(AppInfo.archSuffix)-update.dmg")
        do {
            if fm.fileExists(atPath: dmgURL.path) {
                try? fm.removeItem(at: dmgURL)
            }
            try fm.copyItem(at: tempURL, to: dmgURL)
        } catch {
            state = .failed(L10n.t("updateDownloadFailed"))
            openReleases()
            return
        }

        guard let mount = mountDMG(at: dmgURL) else {
            state = .failed(L10n.t("updateMountFailed"))
            openReleases()
            return
        }
        let newApp = mount.appendingPathComponent("BA Click.app")
        guard fm.fileExists(atPath: newApp.path) else {
            detachDMG(mount)
            state = .failed(L10n.t("updateMountFailed"))
            openReleases()
            return
        }

        let helperURL = fm.temporaryDirectory
            .appendingPathComponent("ba-click-update-\(ProcessInfo.processInfo.processIdentifier).sh")
        let logURL = logFileURL()
        guard writeHelperScript(to: helperURL) else {
            detachDMG(mount)
            state = .failed(L10n.t("updateMountFailed"))
            openReleases()
            return
        }

        spawnDetached(
            helperURL,
            args: [
                String(ProcessInfo.processInfo.processIdentifier),
                currentApp,
                newApp.path,
                dmgURL.path,
                mount.path,
                logURL.path,
                helperURL.path
            ]
        )
        state = .installing
        // Give the panel a moment to paint "正在更新…" before we quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }

    /// Mount the DMG read-only and return its mount point, or nil.
    private func mountDMG(at url: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", "-plist", url.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ),
                  let dict = plist as? [String: Any],
                  let entities = dict["system-entities"] as? [[String: Any]] else {
                return nil
            }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func detachDMG(_ mount: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path]
        try? process.run()
    }

    /// A persistent (but small) update log in ~/Library/Logs/BA Click/.
    private func logFileURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BA Click")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }

    /// The helper does the work after the app quits: wait for the old process
    /// to exit, replace the bundle, detach the DMG, clean up, relaunch.
    private func writeHelperScript(to url: URL) -> Bool {
        // Positional args ($1...$7) are supplied by spawnDetached; every path
        // is double-quoted so spaces in e.g. "BA Click.app" are safe.
        let script = """
        #!/bin/bash
        set -u
        APP_PID="$1"; CURRENT_APP="$2"; NEW_APP="$3"; DMG="$4"; MOUNT="$5"; LOG="$6"; SELF="$7"
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
        log "waiting for pid $APP_PID to exit"
        while kill -0 "$APP_PID" 2>/dev/null; do
          sleep 0.5
        done
        sleep 1
        if [ ! -d "$NEW_APP" ]; then
          log "ERROR: new app missing at $NEW_APP"
          open "https://github.com/HarryHello/ba-click-mac/releases"
          hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
          rm -f "$DMG" "$SELF" || true
          exit 1
        fi
        if rm -rf "$CURRENT_APP" && ditto "$NEW_APP" "$CURRENT_APP"; then
          log "replaced $CURRENT_APP"
        else
          log "ERROR: failed to replace $CURRENT_APP"
          open "https://github.com/HarryHello/ba-click-mac/releases"
        fi
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        rm -f "$DMG" "$SELF" || true
        if [ -d "$CURRENT_APP" ]; then
          open "$CURRENT_APP"
        fi
        log "done"
        exit 0
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            dlog("[update] could not write helper script: \(error)")
            return false
        }
    }

    /// Launch the helper detached from this process so it survives the app
    /// quitting. The script is invoked via `/bin/sh -c` with `nohup … &`, so
    /// it is fully decoupled from our process/lifetime and stdout/stderr pipes.
    private func spawnDetached(_ script: URL, args: [String]) {
        let quoted = ([script.path] + args).map { arg -> String in
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        let command = "nohup /bin/sh \(quoted.joined(separator: " ")) >/dev/null 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            dlog("[update] could not spawn helper: \(error)")
        }
    }

    // MARK: - Version parsing

    /// "v1.2.3" -> "1.2.3" (strip a leading v/V for display).
    static func versionString(_ string: String) -> String {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// "v1.2.3" / "1.2.3" -> [1, 2, 3] (numeric components only).
    static func normalizeVersion(_ string: String) -> [Int] {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed.split(separator: ".").compactMap { Int($0) }
    }

    /// -1 when a < b, 0 when equal, 1 when a > b (missing components = 0).
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        let count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }
}

import Foundation

/// Compile-time app metadata: version and GitHub links used by the update
/// checker and the "open repo" button. Keep `fallbackVersion` in sync with
/// `VERSION` in build.sh — it is only used when running the raw command-line
/// binary (no Info.plist); bundled builds read CFBundleShortVersionString.
enum AppInfo {
    static let repoURL = URL(string: "https://github.com/HarryHello/ba-click-mac")!
    static let releasesURL = URL(string: "https://github.com/HarryHello/ba-click-mac/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/HarryHello/ba-click-mac/releases/latest")!

    /// Current running version. Bundled builds carry it in the Info.plist
    /// (written by build.sh); the raw binary falls back to the source default.
    static var version: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        return "0.2.0" // keep in sync with build.sh VERSION
    }

    /// The DMG asset name suffix for the running architecture.
    static var archSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }
}

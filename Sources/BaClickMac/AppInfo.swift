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
        return "0.3.0" // keep in sync with build.sh VERSION
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

/// GitHub access proxies (URL prefixes): the app tries the direct URL first
/// and falls back to these when the direct connection is blocked or fails.
///
/// Kept to the ones verified reachable (probed live); the two `api` entries
/// forward `api.github.com` JSON (needed for the version check), while
/// `download` also includes proxies that only forward release-asset
/// downloads. `gh-proxy.org` is the user-recommended one and comes first.
enum GitHubProxy {
    /// Proxies that forward api.github.com JSON (version check).
    static let api: [String] = [
        "https://gh-proxy.org/",
        "https://gh-proxy.com/",
    ]
    /// Proxies that forward release-asset downloads (DMG download).
    static let download: [String] = [
        "https://gh-proxy.org/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
        "https://ghfast.top/",
    ]
}

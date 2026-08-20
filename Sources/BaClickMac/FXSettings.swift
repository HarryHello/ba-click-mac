import Foundation

/// Runtime tuning parameters. The management panel edits these live; they are
/// persisted to `settings.json` (or `~/.ba-click-mac-settings.json` for the
/// launch-at-login case) and applied to the renderer immediately.
///
/// The defaults below are the tuned "best" values (see README). An optional
/// `settings.json` overrides them; a template lives in `settings.example.json`.
struct FXSettings: Codable {
    // Tuned "best" defaults, kept as single-source constants shared by both
    // the default init and the lenient JSON decoder.
    static let defaultDiskScale: Float = 0.8
    static let defaultRingScale: Float = 0.8
    static let defaultShardScale: Float = 0.8
    static let defaultTrailScale: Float = 2.2
    static let defaultShowInFullscreen: Bool = true
    static let defaultClickBloomStrength: Float = 0.1
    static let defaultTrailBloomStrength: Float = 3.5
    static let defaultBloomStrength: Float = 1.7
    static let defaultBloomLevels: Int = 16
    static let defaultBloomDiffusion: Float = 7.0
    static let defaultBloomThreshold: Float = 1.0
    static let defaultBloomFalloff: Float = 0.35
    static let defaultBloomBoost: Float = 1.2
    // Panel controls.
    static let defaultEnabled: Bool = true
    static let defaultTrailAlwaysVisible: Bool = true
    static let defaultClickBrightness: Float = 1.0
    static let defaultClickDiskOpacity: Float = 1.0
    static let defaultTriangleOpacity: Float = 1.0
    static let defaultRefreshRate: Int = 60

    var diskScale: Float
    var ringScale: Float
    var shardScale: Float
    var trailScale: Float
    var showInFullscreen: Bool
    var clickBloomStrength: Float
    var trailBloomStrength: Float
    var bloomStrength: Float
    var bloomLevels: Int
    var bloomDiffusion: Float
    var bloomThreshold: Float
    var bloomFalloff: Float
    var bloomBoost: Float
    // Panel controls.
    var enabled: Bool
    var trailAlwaysVisible: Bool
    var clickBrightness: Float
    var clickDiskOpacity: Float
    var triangleOpacity: Float
    var refreshRate: Int

    init() {
        diskScale = Self.defaultDiskScale
        ringScale = Self.defaultRingScale
        shardScale = Self.defaultShardScale
        trailScale = Self.defaultTrailScale
        showInFullscreen = Self.defaultShowInFullscreen
        clickBloomStrength = Self.defaultClickBloomStrength
        trailBloomStrength = Self.defaultTrailBloomStrength
        bloomStrength = Self.defaultBloomStrength
        bloomLevels = Self.defaultBloomLevels
        bloomDiffusion = Self.defaultBloomDiffusion
        bloomThreshold = Self.defaultBloomThreshold
        bloomFalloff = Self.defaultBloomFalloff
        bloomBoost = Self.defaultBloomBoost
        enabled = Self.defaultEnabled
        trailAlwaysVisible = Self.defaultTrailAlwaysVisible
        clickBrightness = Self.defaultClickBrightness
        clickDiskOpacity = Self.defaultClickDiskOpacity
        triangleOpacity = Self.defaultTriangleOpacity
        refreshRate = Self.defaultRefreshRate
    }

    /// Lenient decoding: a `settings.json` may contain only the keys the user
    /// wants to override; missing keys keep the defaults. (The synthesized
    /// decoder would require every key, silently dropping the whole file and
    /// falling back to defaults — so a partial edit would be lost.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diskScale = try c.decodeIfPresent(Float.self, forKey: .diskScale) ?? Self.defaultDiskScale
        ringScale = try c.decodeIfPresent(Float.self, forKey: .ringScale) ?? Self.defaultRingScale
        shardScale = try c.decodeIfPresent(Float.self, forKey: .shardScale) ?? Self.defaultShardScale
        trailScale = try c.decodeIfPresent(Float.self, forKey: .trailScale) ?? Self.defaultTrailScale
        showInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .showInFullscreen) ?? Self.defaultShowInFullscreen
        clickBloomStrength = try c.decodeIfPresent(Float.self, forKey: .clickBloomStrength) ?? Self.defaultClickBloomStrength
        trailBloomStrength = try c.decodeIfPresent(Float.self, forKey: .trailBloomStrength) ?? Self.defaultTrailBloomStrength
        bloomStrength = try c.decodeIfPresent(Float.self, forKey: .bloomStrength) ?? Self.defaultBloomStrength
        bloomLevels = try c.decodeIfPresent(Int.self, forKey: .bloomLevels) ?? Self.defaultBloomLevels
        bloomDiffusion = try c.decodeIfPresent(Float.self, forKey: .bloomDiffusion) ?? Self.defaultBloomDiffusion
        bloomThreshold = try c.decodeIfPresent(Float.self, forKey: .bloomThreshold) ?? Self.defaultBloomThreshold
        bloomFalloff = try c.decodeIfPresent(Float.self, forKey: .bloomFalloff) ?? Self.defaultBloomFalloff
        bloomBoost = try c.decodeIfPresent(Float.self, forKey: .bloomBoost) ?? Self.defaultBloomBoost
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaultEnabled
        trailAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .trailAlwaysVisible) ?? Self.defaultTrailAlwaysVisible
        clickBrightness = try c.decodeIfPresent(Float.self, forKey: .clickBrightness) ?? Self.defaultClickBrightness
        clickDiskOpacity = try c.decodeIfPresent(Float.self, forKey: .clickDiskOpacity) ?? Self.defaultClickDiskOpacity
        triangleOpacity = try c.decodeIfPresent(Float.self, forKey: .triangleOpacity) ?? Self.defaultTriangleOpacity
        refreshRate = try c.decodeIfPresent(Int.self, forKey: .refreshRate) ?? Self.defaultRefreshRate
    }

    static let knownKeys: Set<String> = [
        "diskScale", "ringScale", "shardScale", "trailScale",
        "showInFullscreen", "clickBloomStrength", "trailBloomStrength",
        "bloomStrength", "bloomLevels", "bloomDiffusion", "bloomThreshold",
        "bloomFalloff", "bloomBoost",
        "enabled", "trailAlwaysVisible", "clickBrightness",
        "clickDiskOpacity", "triangleOpacity", "refreshRate",
    ]

    static func load() -> FXSettings {
        let candidates = FXSettings.candidateURLs()
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let decoded = try? JSONDecoder().decode(FXSettings.self, from: data) else {
                dlog("[settings] WARNING: could not parse \(url.path) — using defaults")
                continue
            }
            FXSettings.warnUnknownKeys(in: data, url: url)
            return decoded
        }
        let defaults = FXSettings()
        if let url = candidates.first {
            // Write a template so the user can find and edit it.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(defaults) {
                try? data.write(to: url)
            }
        }
        return defaults
    }

    /// Where settings should be persisted: the first existing candidate
    /// (matches load order); if none exists, fall back to the home-directory
    /// file so changes survive the launch-at-login case (cwd = "/" there).
    static func persistURL() -> URL {
        let candidates = FXSettings.candidateURLs()
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home)
                .appendingPathComponent(".ba-click-mac-settings.json")
        }
        return candidates[0]
    }

    /// Typo'd/unknown keys are silently ignored by Codable; warn so the user
    /// doesn't tune a key that does nothing.
    private static func warnUnknownKeys(in data: Data, url: URL) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return }
        for key in dict.keys where !knownKeys.contains(key) {
            dlog("[settings] WARNING: unknown key '\(key)' in \(url.path) (ignored)")
        }
    }

    private static func candidateURLs() -> [URL] {
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var urls = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("settings.json"),
            exeURL.deletingLastPathComponent().appendingPathComponent("settings.json")
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            urls.append(
                URL(fileURLWithPath: home)
                    .appendingPathComponent(".ba-click-mac-settings.json")
            )
        }
        return urls
    }
}

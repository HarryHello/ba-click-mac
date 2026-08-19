import Foundation

/// Runtime tuning parameters. Edit `settings.json` next to the executable
/// (or in the working directory) and save — the app reloads it every 0.5s.
struct FXSettings: Codable {
    var diskScale: Float = 1.5
    var ringScale: Float = 0.85
    var shardScale: Float = 1.0
    var trailScale: Float = 1.4
    // Click (disk + rings) HDR glow-source energy multiplier. This is what
    // feeds the bloom pyramid; keep it >= 1 or the click glow vanishes.
    var clickBloomStrength: Float = 1.5
    var clickBloomSigma: Float = 14.0
    // Trail HDR glow-source energy multiplier for the bloom pyramid.
    var trailBloomStrength: Float = 3.0
    var trailBloomSigma: Float = 8.0
    // Unified MXFinalBloom intensity used by the multi-level bloom path.
    var bloomStrength: Float = 1.0
    // Number of pyramid levels: more levels = wider glow.
    var bloomLevels: Int = 8
    // Prefilter threshold: lower catches weak HDR energy so the outer glow is
    // visible instead of only the brightest core.
    var bloomThreshold: Float = 0.05
    // 1.0 = filmic falloff; < 1 widens the halo, > 1 tightens it.
    var bloomFalloff: Float = 1.0

    static func load() -> FXSettings {
        let candidates = FXSettings.candidateURLs()
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(FXSettings.self, from: data) {
                return decoded
            }
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
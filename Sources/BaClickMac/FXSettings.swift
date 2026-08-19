import Foundation

/// Runtime tuning parameters. Edit `settings.json` next to the executable
/// (or in the working directory) and save — the app reloads it every 0.5s.
struct FXSettings: Codable {
    var diskScale: Float = 1.5
    var ringScale: Float = 0.85
    var shardScale: Float = 1.0
    var trailScale: Float = 1.4
    // Click bloom source is intentionally weak; users can raise it if wanted.
    var clickBloomStrength: Float = 0.05
    var clickBloomSigma: Float = 14.0
    // Trail HDR glow-source energy multiplier: this controls how strongly the
    // trail lights up the area around it.
    var trailBloomStrength: Float = 4.0
    var trailBloomSigma: Float = 8.0
    // Game MXFinalBloom exposure. Original uses Intensity 1.7, which becomes
    // 2^(1.7/10)-1 = 0.125 in the composite.
    var bloomStrength: Float = 1.7
    // Maximum pyramid levels; the actual count follows the original diffusion
    // formula and this only caps it.
    var bloomLevels: Int = 16
    // Original MXFinalBloom diffusion, drives iteration count and sample scale.
    var bloomDiffusion: Float = 7.0
    // Original MXFinalBloom prefilter threshold (in gamma space; shader converts
    // to linear). Game value is 1.0.
    var bloomThreshold: Float = 1.0
    // Low-gamma alpha lift for the transparent overlay: < 1 lifts the faint
    // outer halo so it visibly illuminates the surroundings; > 1 tightens it.
    var bloomFalloff: Float = 0.6

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
import Foundation

/// Runtime tuning parameters. Edit `settings.json` next to the executable
/// (or in the working directory) and save — the app reloads it every 0.5s.
struct FXSettings: Codable {
    // User-tuned: trail thicker, click slightly smaller than strict 1:1.
    var diskScale: Float = 0.8
    var ringScale: Float = 0.8
    var shardScale: Float = 0.8
    var trailScale: Float = 1.8
    // The NSPanel (+ fullScreenAuxiliary + canJoinAllSpaces) is added onto the
    // fullscreen app's Space, so the fullscreen desktop contains BOTH windows
    // (app window + this overlay) — that's how it appears over fullscreen apps.
    // Default true so the panel is kept on the fullscreen Space; set false to
    // hide + stop rendering (no GPU work) over fullscreen instead.
    var showInFullscreen: Bool = true
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
    // Rational falloff knee for the glow overlay: a = lum/(lum+k). Smaller k lifts
// the faint mid/far halo (overall brighter) while the core stays narrow.
    var bloomFalloff: Float = 0.35
    // Extra brightness for the glow overlay.
    var bloomBoost: Float = 1.2

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
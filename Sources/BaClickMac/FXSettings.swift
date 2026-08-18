import Foundation

/// Runtime tuning parameters. Edit `settings.json` next to the executable
/// (or in the working directory) and save — the app reloads it every 0.5s.
struct FXSettings: Codable {
    var diskScale: Float = 1.5
    var ringScale: Float = 0.85
    var shardScale: Float = 1.0
    var trailScale: Float = 1.0
    var bloomStrength: Float = 2.0

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
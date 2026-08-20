import Foundation

/// Find a bundled resource: Bundle.main first, then next to the executable
/// (`Resources/` or flat), matching how build.sh / run.sh lay out files.
func findResourceURL(name: String, ext: String) -> URL? {
    if let url = Bundle.main.url(forResource: name, withExtension: ext) {
        return url
    }
    let exeURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let candidates = [
        exeURL.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)"),
        exeURL.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

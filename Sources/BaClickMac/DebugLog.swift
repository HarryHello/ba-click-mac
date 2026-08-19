import Foundation
import Darwin

func dlog(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

/// Print a fatal error to stderr and exit cleanly (no crash dialog).
func bail(_ message: String) -> Never {
    dlog("FATAL: \(message)")
    exit(1)
}

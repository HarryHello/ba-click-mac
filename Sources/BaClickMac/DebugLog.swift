import Foundation

func dlog(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

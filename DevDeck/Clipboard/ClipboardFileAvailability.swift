import Foundation

protocol ClipboardFileChecking: Sendable {
    func isAvailable(_ url: URL) -> Bool
}
struct ClipboardFileAvailability: ClipboardFileChecking {
    func isAvailable(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }
}

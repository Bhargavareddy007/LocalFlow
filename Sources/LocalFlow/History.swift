import Foundation

/// The last dictation, kept in memory only and only for a short time, so it can be copied again
/// from the menu if the paste didn't land. Nothing is written to disk.
final class History {
    static let shared = History()
    static let lifetime: TimeInterval = 120

    private(set) var last: String?
    private var expiry: Timer?

    func remember(_ text: String) {
        last = text
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            self?.forget()
        }
    }

    func forget() {
        last = nil
        expiry?.invalidate()
        expiry = nil
    }

    /// Versions before 0.2.0 kept up to 300 dictations in history.json; remove that file.
    static func deleteLegacyFile() {
        try? FileManager.default.removeItem(at: Settings.historyURL)
    }
}

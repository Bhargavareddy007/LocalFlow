import Foundation

enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalFlow.log")
    private static let queue = DispatchQueue(label: "localflow.log")
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let maxBytes = 1_000_000

    /// Keep the log small: if it grew past 1 MB, start over.
    static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxBytes { try? FileManager.default.removeItem(at: url) }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    static func info(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)\n"
        fputs(line, stderr)
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                // The same 1 MB limit during long sessions, not only at launch: start over.
                if h.seekToEndOfFile() > UInt64(maxBytes) {
                    try? h.close()
                    try? FileManager.default.removeItem(at: url)
                    try? line.data(using: .utf8)!.write(to: url)
                    return
                }
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

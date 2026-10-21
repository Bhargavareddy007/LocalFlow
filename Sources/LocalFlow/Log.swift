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

    /// Keep the log small: if it grew past 1 MB, start over.
    static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    }

    static func info(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)\n"
        fputs(line, stderr)
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

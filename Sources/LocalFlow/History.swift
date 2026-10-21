import Foundation

struct HistoryEntry: Codable {
    let date: Date
    let text: String
    let engine: String
    let seconds: Double
}

final class History {
    static let shared = History()
    private(set) var entries: [HistoryEntry] = []
    private let limit = 300

    init() { load() }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Settings.historyURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(entries) { try? data.write(to: Settings.historyURL) }
    }
}

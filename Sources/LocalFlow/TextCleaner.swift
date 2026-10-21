import Foundation

/// Local, rule-based cleanup: filler words, personal dictionary, spoken commands, spacing.
enum TextCleaner {
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w'])(?:um+|uh+|uhm+|umm+|erm+|hmm+|mm+|ah+|eh+)(?![\w'])[,.]?\s*"#)

    private static let commandPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?i)[,.]?\s*\bnew paragraph\b[,.]?\s*"#), "\n\n"),
        (try! NSRegularExpression(pattern: #"(?i)[,.]?\s*\bnew line\b[,.]?\s*"#), "\n"),
    ]

    static func clean(_ raw: String, removeFillers: Bool) -> String {
        var text = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        if removeFillers {
            let r = NSRange(text.startIndex..., in: text)
            text = fillerPattern.stringByReplacingMatches(in: text, range: r, withTemplate: "")
        }

        for (regex, replacement) in commandPatterns {
            let r = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: r, withTemplate: replacement)
        }

        text = PersonalDictionary.apply(to: text)

        // Tidy punctuation spacing left behind by removals.
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([,.!?;:]){2,}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return capitalizeSentences(text)
    }

    private static func capitalizeSentences(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
            }
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { capitalizeNext = true }
            else if ch.isLetter || ch.isNumber { capitalizeNext = false }
        }
        return out
    }
}

/// `~/Library/Application Support/LocalFlow/dictionary.json`
/// {"replacements": {"wisper": "Wispr", "jay son": "JSON"}}
enum PersonalDictionary {
    private static var cache: [(NSRegularExpression, String)] = []
    private static var loadedAt: Date?

    static func ensureFileExists() {
        let url = Settings.dictionaryURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let sample = """
        {
          "_comment": "Spoken form (left) is replaced by the written form (right). Case-insensitive, whole words.",
          "replacements": {
            "wisper flow": "Wispr Flow",
            "local flow": "LocalFlow"
          }
        }
        """
        try? sample.data(using: .utf8)?.write(to: url)
    }

    static func reload() {
        cache = []
        loadedAt = Date()
        guard let data = try? Data(contentsOf: Settings.dictionaryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["replacements"] as? [String: String] else { return }
        for (spoken, written) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?i)(?<![\\w])" + NSRegularExpression.escapedPattern(for: spoken) + "(?![\\w])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                cache.append((re, NSRegularExpression.escapedTemplate(for: written)))
            }
        }
    }

    static func apply(to text: String) -> String {
        if let t = loadedAt, Date().timeIntervalSince(t) > 5 { reload() }
        if loadedAt == nil { reload() }
        var out = text
        for (re, template) in cache {
            let r = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: r, withTemplate: template)
        }
        return out
    }
}

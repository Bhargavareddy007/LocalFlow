import Foundation

enum Hotkey: String, CaseIterable {
    case fn, rightOption, rightCommand, controlOption

    var title: String {
        switch self {
        case .fn: return "fn (Globe) key"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .controlOption: return "⌃ Control + ⌥ Option"
        }
    }

    var shortName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .controlOption: return "⌃⌥"
        }
    }
}

enum Engine: String, CaseIterable {
    case parakeet, whisper

    var title: String {
        switch self {
        case .parakeet: return "Parakeet v3 — fastest (English + 24 European languages)"
        case .whisper: return "Whisper large-v3-turbo — all languages (Telugu, Hindi, …)"
        }
    }
}

struct Language {
    let code: String
    let name: String
    static let all: [Language] = [
        .init(code: "auto", name: "Auto-detect"),
        .init(code: "en", name: "English"),
        .init(code: "te", name: "Telugu"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "el", name: "Greek"),
        .init(code: "de", name: "German"),
        .init(code: "fr", name: "French"),
        .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "ta", name: "Tamil"),
        .init(code: "kn", name: "Kannada"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
    ]
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let supportDir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let modelsDir: URL = {
        let url = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let dictionaryURL = supportDir.appendingPathComponent("dictionary.json")
    static let historyURL = supportDir.appendingPathComponent("history.json")

    var hotkey: Hotkey {
        get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    var engine: Engine {
        get { Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .parakeet }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }
    var language: String {
        get { d.string(forKey: "language") ?? "en" }
        set { d.set(newValue, forKey: "language") }
    }
    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }
    var playSounds: Bool {
        get { d.object(forKey: "playSounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSounds") }
    }
    var smartSpacing: Bool {
        get { d.object(forKey: "smartSpacing") as? Bool ?? true }
        set { d.set(newValue, forKey: "smartSpacing") }
    }
    /// Gate for the "polish wording" feature (menu entry + model download).
    /// On by default; hide with: defaults write com.bhargava.localflow polishFeature -bool false
    var polishFeature: Bool { d.object(forKey: "polishFeature") as? Bool ?? true }
    var polishEnabled: Bool {
        get { polishFeature && (d.object(forKey: "polishEnabled") as? Bool ?? true) }
        set { d.set(newValue, forKey: "polishEnabled") }
    }
    /// Off by default: dictated text is never written to the log unless the user turns this on.
    var verboseLog: Bool {
        get { d.bool(forKey: "verboseLog") }
        set { d.set(newValue, forKey: "verboseLog") }
    }
    var tapToLock: Bool {
        get { d.object(forKey: "tapToLock") as? Bool ?? true }
        set { d.set(newValue, forKey: "tapToLock") }
    }

    /// The polishing language model: the default file if present, otherwise the largest .gguf in the models folders.
    func polishModelPath() -> String? {
        var dirs = [Settings.modelsDir]
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("models")) }
        for dir in dirs {
            let p = dir.appendingPathComponent(ModelInfo.polish.fileName).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        var best: (String, Int)? = nil
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in files where f.hasSuffix(".gguf") {
                let path = dir.appendingPathComponent(f).path
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                if best == nil || size > best!.1 { best = (path, size) }
            }
        }
        return best?.0
    }

    /// First model file matching the engine, in the user's models folder or bundled inside the app.
    func modelPath(for engine: Engine) -> String? {
        var dirs = [Settings.modelsDir]
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("models")) }
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let candidates = files.filter { $0.hasSuffix(".bin") && !$0.hasSuffix(".part") }.sorted()
            let match: String?
            switch engine {
            case .parakeet:
                match = candidates.first { $0.contains("parakeet") }
            case .whisper:
                match = candidates.first { !$0.contains("parakeet") && !$0.contains("vad") && !$0.contains("silero") }
            }
            if let m = match { return dir.appendingPathComponent(m).path }
        }
        return nil
    }
}

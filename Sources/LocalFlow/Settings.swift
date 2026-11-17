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
        var url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalFlow", isDirectory: true)
        #if DEBUG
        // Tests run against a scratch folder instead of the real models and dictionary.
        if let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SUPPORT_DIR"] { url = URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let modelsDir: URL = {
        let url = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let recordingsDir: URL = {
        let url = supportDir.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let dictionaryURL = supportDir.appendingPathComponent("dictionary.json")
    /// Only used to delete the history file older versions kept (see History.deleteLegacyFile).
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
        get { d.string(forKey: "language") ?? "auto" }
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
    /// Off until the user turns it on in the menu, even when the polish model is already downloaded.
    var polishEnabled: Bool {
        get { polishFeature && d.bool(forKey: "polishEnabled") }
        set { d.set(newValue, forKey: "polishEnabled") }
    }
    /// Writes dictated text to the log. Lives only in memory: it can be switched on from the menu and nowhere
    /// else, ends when the app quits, and the menu-bar icon turns orange while it's on. Not a preference,
    /// so another process can't turn it on with `defaults write`.
    var verboseLog = false
    /// Troubleshooting switches that other processes could flip with `defaults write`: they exist only in
    /// debug builds, and release builds ignore them.
    /// Debug: keeps the last 30 recordings as WAV files in recordingsDir.
    var saveRecordings: Bool {
        #if DEBUG
        return d.bool(forKey: "saveRecordings")
        #else
        return false
        #endif
    }
    /// Debug: `kill -USR1` toggles hands-free dictation (for testing).
    var signalToggle: Bool {
        #if DEBUG
        return d.bool(forKey: "signalToggle")
        #else
        return false
        #endif
    }
    var tapToLock: Bool {
        get { d.object(forKey: "tapToLock") as? Bool ?? true }
        set { d.set(newValue, forKey: "tapToLock") }
    }

    /// The polishing language model: only the pinned file name.
    func polishModelPath() -> String? { pinnedPath(ModelInfo.polish) }

    /// The engine's model: only the pinned file name. Other files in the folder are never loaded.
    func modelPath(for engine: Engine) -> String? { pinnedPath(ModelInfo.info(for: engine)) }

    /// The pinned file in the user's models folder or bundled inside the app. Its size and SHA-256 are
    /// checked again just before it's loaded (ModelManager.verifyBeforeLoad).
    private func pinnedPath(_ info: ModelInfo) -> String? {
        var dirs = [Settings.modelsDir]
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("models")) }
        for dir in dirs {
            let p = dir.appendingPathComponent(info.fileName).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }
}

import AVFoundation
import Foundation

/// `LocalFlow --transcribe file.wav [parakeet|whisper] [lang]` — offline test of the engines.
enum CLI {
    /// `LocalFlow --verify-model parakeet|whisper|polish /path/file` — runs the download validator on a file.
    static func runVerify(kind: String, path: String) -> Never {
        let info: ModelInfo
        switch kind {
        case "parakeet": info = .parakeet
        case "whisper": info = .whisper
        default: info = .polish
        }
        do {
            try ModelManager.validate(file: URL(fileURLWithPath: path), response: nil, against: info)
            print("OK: \(path) matches \(info.fileName)")
            exit(0)
        } catch {
            print("REJECTED: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func runPolish(text: String) -> Never {
        EngineLoader.quietLogs()
        EngineLoader.loadBackends()
        var p = PolisherLoader.load()
        guard p != nil else { print("no polish model"); exit(1) }
        _ = p!.polish("this is a short warm up sentence for the model")
        let t0 = Date()
        let out = p!.polish(text)
        print("polished in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        print("in : \(text)")
        print("out: \(out ?? "(skipped — kept original)")")
        p = nil
        exit(0)
    }

    static func run(arguments: [String]) -> Never {
        let path = arguments[0]
        let engineKind = arguments.count > 1 ? (Engine(rawValue: arguments[1]) ?? .parakeet) : .parakeet
        let lang = arguments.count > 2 ? arguments[2] : "en"

        guard let samples = loadAudio(path) else {
            print("could not read \(path)")
            exit(1)
        }
        EngineLoader.quietLogs()
        var engine: SpeechEngine? = EngineLoader.load(engineKind)
        guard engine != nil else {
            print("engine \(engineKind.rawValue) failed to load")
            exit(1)
        }
        _ = engine!.transcribe([Float](repeating: 0, count: 16_000), language: lang) // warm-up
        let t0 = Date()
        let raw = engine!.transcribe(samples, language: lang)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let cleaned = TextCleaner.clean(raw, removeFillers: true)
        print("audio: \(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate)) s, transcribed in \(ms) ms")
        print("raw:     \(raw)")
        print("cleaned: \(cleaned.replacingOccurrences(of: "\n", with: "⏎"))")
        engine = nil // free Metal buffers before the process exits
        exit(0)
    }

    static func loadAudio(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: inBuf)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var delivered = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

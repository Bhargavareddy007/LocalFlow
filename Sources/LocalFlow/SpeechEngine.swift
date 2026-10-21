import CWhisper
import Foundation

protocol SpeechEngine: AnyObject {
    var kind: Engine { get }
    func transcribe(_ samples: [Float], language: String) -> String
}

/// NVIDIA Parakeet TDT 0.6B v3 via whisper.cpp's libparakeet. Very fast, punctuated output.
final class ParakeetEngine: SpeechEngine {
    let kind: Engine = .parakeet
    private var ctx: OpaquePointer?

    init?(modelPath: String) {
        var params = parakeet_context_default_params()
        params.use_gpu = true
        guard let c = parakeet_init_from_file_with_params(modelPath, params) else { return nil }
        ctx = c
    }

    deinit { if let c = ctx { parakeet_free(c) } }

    func transcribe(_ samples: [Float], language: String) -> String {
        guard let ctx = ctx else { return "" }
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.no_context = true
        let rc = samples.withUnsafeBufferPointer { buf in
            parakeet_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else {
            Log.info("parakeet: parakeet_full failed rc=\(rc)")
            return ""
        }
        var text = ""
        let n = parakeet_full_n_segments(ctx)
        for i in 0..<n {
            if let c = parakeet_full_get_segment_text(ctx, i) { text += String(cString: c) }
        }
        return text
    }
}

/// OpenAI Whisper (ggml) via libwhisper. Slower than Parakeet but covers ~100 languages.
final class WhisperEngine: SpeechEngine {
    let kind: Engine = .whisper
    private var ctx: OpaquePointer?

    init?(modelPath: String) {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelPath, params) else { return nil }
        ctx = c
    }

    deinit { if let c = ctx { whisper_free(c) } }

    func transcribe(_ samples: [Float], language: String) -> String {
        guard let ctx = ctx else { return "" }
        // whisper needs at least ~1 s of audio; pad with silence.
        var audio = samples
        let minSamples = Int(AudioRecorder.sampleRate * 1.2)
        if audio.count < minSamples { audio.append(contentsOf: [Float](repeating: 0, count: minSamples - audio.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.single_segment = false
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature_inc = 0.2

        let lang = language.isEmpty ? "auto" : language
        let rc: Int32 = lang.withCString { cLang in
            params.language = cLang
            return audio.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        guard rc == 0 else {
            Log.info("whisper: whisper_full failed rc=\(rc)")
            return ""
        }
        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
        }
        return text
    }
}

enum EngineLoader {
    /// Silence the very chatty ggml / whisper loggers.
    static func quietLogs() {
        let cb: ggml_log_callback = { _, _, _ in }
        whisper_log_set(cb, nil)
        ggml_log_set(cb, nil)
    }

    private static var backendsLoaded = false

    /// Homebrew's ggml ships Metal / CPU / BLAS as plug-ins; load them once.
    static func loadBackends() {
        if backendsLoaded { return }
        backendsLoaded = true
        var dirs: [String] = []
        if let fw = Bundle.main.privateFrameworksPath { dirs.append(fw) }
        dirs += ["/opt/homebrew/opt/ggml/libexec", "/opt/homebrew/lib/ggml"]
        for dir in dirs where FileManager.default.fileExists(atPath: dir) {
            ggml_backend_load_all_from_path(dir)
            if ggml_backend_dev_count() > 0 {
                Log.info("ggml: \(ggml_backend_dev_count()) backend device(s) from \(dir)")
                return
            }
        }
        ggml_backend_load_all()
        Log.info("ggml: \(ggml_backend_dev_count()) backend device(s) (default search)")
    }

    static func load(_ engine: Engine) -> SpeechEngine? {
        loadBackends()
        guard let path = Settings.shared.modelPath(for: engine) else {
            Log.info("engine: no model file for \(engine.rawValue) in \(Settings.modelsDir.path)")
            return nil
        }
        let t0 = Date()
        let result: SpeechEngine?
        switch engine {
        case .parakeet: result = ParakeetEngine(modelPath: path)
        case .whisper: result = WhisperEngine(modelPath: path)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("engine: \(engine.rawValue) \(result == nil ? "FAILED" : "loaded") from \(path) in \(ms) ms")
        return result
    }
}

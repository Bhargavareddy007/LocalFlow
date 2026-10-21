import CryptoKit
import Foundation

struct ModelInfo {
    let engine: Engine?          // nil = the polishing language model
    let fileName: String
    let url: URL
    let sizeMB: Int
    let bytes: Int               // exact size on Hugging Face
    let sha256: String           // pinned content hash

    static let parakeet = ModelInfo(
        engine: .parakeet,
        fileName: "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        url: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")!,
        sizeMB: 669, bytes: 668_757_119,
        sha256: "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e")
    static let whisper = ModelInfo(
        engine: .whisper,
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        sizeMB: 574, bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")

    static let polish = ModelInfo(
        engine: nil,
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        sizeMB: 1117, bytes: 1_117_320_736,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")

    static func info(for engine: Engine) -> ModelInfo { engine == .parakeet ? parakeet : whisper }
}

/// Downloads model files into the models folder. This is the only network access the app ever makes,
/// and only when a model is missing.
final class ModelManager: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()

    /// (model, fraction 0...1) on the main thread.
    var onProgress: ((ModelInfo, Double) -> Void)?
    /// (model, error) on the main thread; nil error = success.
    var onFinish: ((ModelInfo, Error?) -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var active: [Int: ModelInfo] = [:]
    private var moved: Set<Int> = []
    private var failures: [Int: String] = [:]
    private let lock = NSLock()

    func isDownloading(_ info: ModelInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.values.contains { $0.fileName == info.fileName }
    }

    func download(_ engine: Engine) { download(model: ModelInfo.info(for: engine)) }

    func download(model info: ModelInfo) {
        guard !isDownloading(info) else { return }
        let task = session.downloadTask(with: info.url)
        lock.lock(); active[task.taskIdentifier] = info; lock.unlock()
        Log.info("model: downloading \(info.fileName) (\(info.sizeMB) MB)")
        task.resume()
    }

    /// HTTP 200, exact size, known file header, and the pinned SHA-256. Anything else is rejected.
    static func validate(file: URL, response: URLResponse?, against info: ModelInfo) throws {
        func fail(_ msg: String) -> Error {
            NSError(domain: "LocalFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw fail("server answered HTTP \(http.statusCode)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size == info.bytes else { throw fail("file size \(size) does not match expected \(info.bytes)") }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw fail("cannot read download") }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4)
        let magic = String(decoding: head, as: UTF8.self)
        guard magic == "lmgg" || magic == "GGUF" else { throw fail("not a model file") }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256 else { throw fail("checksum mismatch") }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let info = active[downloadTask.taskIdentifier]; lock.unlock()
        guard let info = info else { return }
        let expected = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(info.sizeMB) * 1_000_000
        let fraction = min(1, Double(totalBytesWritten) / expected)
        DispatchQueue.main.async { self.onProgress?(info, fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let info = active[downloadTask.taskIdentifier]; lock.unlock()
        guard let info = info else { return }
        let dest = Settings.modelsDir.appendingPathComponent(info.fileName)
        do {
            try ModelManager.validate(file: location, response: downloadTask.response, against: info)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            lock.lock(); moved.insert(downloadTask.taskIdentifier); lock.unlock()
            Log.info("model: saved and verified \(dest.path)")
        } catch {
            lock.lock(); failures[downloadTask.taskIdentifier] = error.localizedDescription; lock.unlock()
            Log.info("model: rejected \(info.fileName): \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let info = active.removeValue(forKey: task.taskIdentifier)
        let ok = moved.remove(task.taskIdentifier) != nil
        let failure = failures.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let info = info else { return }
        var finalError = error
        if error == nil, !ok {
            finalError = NSError(domain: "LocalFlow", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: failure ?? "Download did not complete"])
        }
        if let e = finalError { Log.info("model: \(info.fileName) failed: \(e.localizedDescription)") }
        DispatchQueue.main.async { self.onFinish?(info, finalError) }
    }
}

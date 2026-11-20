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
        url: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")!,
        sizeMB: 669, bytes: 668_757_119,
        sha256: "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e")
    static let whisper = ModelInfo(
        engine: .whisper,
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
        sizeMB: 574, bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")

    static let polish = ModelInfo(
        engine: nil,
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        sizeMB: 1117, bytes: 1_117_320_736,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")

    static func info(for engine: Engine) -> ModelInfo { engine == .parakeet ? parakeet : whisper }
}

/// A model file's bytes in memory, checked against the pinned size and SHA-256 (ModelManager.readVerified).
/// Engines copy what they need while loading; the memory is released when this goes away.
final class VerifiedModel {
    let bytes: UnsafeMutableRawPointer
    let count: Int

    init(count: Int) {
        self.count = count
        bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
    }

    deinit { bytes.deallocate() }
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

    /// The app in the disk image carries the default speech model, so a new install has nothing to download.
    /// It's copied into the models folder (an APFS clone: instant, no extra disk) and from then on treated
    /// like a downloaded copy: checked before every load, and kept when the app is later updated from the
    /// small zip, which has no model inside.
    static func installBundled(_ info: ModelInfo) {
        let fm = FileManager.default
        let dest = Settings.modelsDir.appendingPathComponent(info.fileName)
        guard let res = Bundle.main.resourceURL else { return }
        let src = res.appendingPathComponent("models").appendingPathComponent(info.fileName)
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dest.path) else { return }
        let partial = dest.appendingPathExtension("partial")
        do {
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: src, to: partial)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            try fm.moveItem(at: partial, to: dest)
            Log.info("model: \(info.fileName) copied from the app bundle")
        } catch {
            try? fm.removeItem(at: partial)
            Log.info("model: couldn't copy the bundled \(info.fileName) (\(error.localizedDescription)); it loads from the bundle")
        }
    }

    /// Reads a model file into memory once and checks those bytes (size, header, SHA-256). The engines load
    /// from the returned bytes, never from the file, so nothing on disk can change between the check and the
    /// load: the folder is writable by any process of the user, and the model parsers are C/C++ code.
    /// A file that fails is renamed to `.rejected`, so the app downloads a fresh copy instead of loading it.
    /// Used for the speech models.
    static func readVerified(_ path: String, _ info: ModelInfo) -> VerifiedModel? {
        checked(path, info, "read and verified") { try readAndCheck(path, info) }
    }

    /// The polish model takes a different route, because a 1.1 GB copy in memory would stay in the app's
    /// footprint for as long as the model is loaded. The loader maps the file it's given, and a mapping sees
    /// later writes to that file, so it never gets the pinned file itself: it gets a private APFS clone
    /// (no extra disk or memory) whose name is deleted as soon as it's opened. Writes to the pinned file
    /// don't reach the clone. The clone is hashed through that descriptor and the same open file goes to the
    /// loader. What remains: a process of the same user that opens the clone in the moment between its
    /// creation and the delete.
    static func openVerified(_ path: String, _ info: ModelInfo) -> UnsafeMutablePointer<FILE>? {
        checked(path, info, "cloned and verified") {
            let fd = try openPrivateClone(path, info)
            do {
                try hashCheck(fd, info)
                guard lseek(fd, 0, SEEK_SET) == 0, let f = fdopen(fd, "rb") else { throw fail("cannot reopen") }
                return f
            } catch {
                close(fd)
                throw error
            }
        }
    }

    private static let clonePrefix = ".loading-"

    /// Clones the pinned file under a random name in the same folder, opens the clone and deletes its name
    /// at once. The caller owns the descriptor.
    private static func openPrivateClone(_ path: String, _ info: ModelInfo) throws -> Int32 {
        let src = try openChecked(path, info)
        defer { close(src) }
        let dir = (path as NSString).deletingLastPathComponent
        // Left behind only if the app stopped between creating a clone and deleting its name.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(clonePrefix) {
            unlink((dir as NSString).appendingPathComponent(name))
        }
        let clone = (dir as NSString).appendingPathComponent(clonePrefix + UUID().uuidString)
        guard fclonefileat(src, AT_FDCWD, clone, 0) == 0 else { throw notTheFile("cannot clone (errno \(errno))") }
        let fd = open(clone, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let openErrno = errno
        unlink(clone)
        guard fd >= 0 else { throw notTheFile("cannot open the clone (errno \(openErrno))") }
        var st = stat()
        // No links left: nothing linked another name to the clone before its own was deleted.
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 0 else {
            close(fd)
            throw notTheFile("the clone was linked or replaced before it was opened")
        }
        guard Int(st.st_size) == info.bytes else {
            close(fd)
            throw fail("file size \(st.st_size) does not match expected \(info.bytes)")
        }
        return fd
    }

    /// Runs a check; a file that fails is renamed to `.rejected`, so the app downloads a fresh copy.
    private static func checked<T>(_ path: String, _ info: ModelInfo, _ verb: String, _ body: () throws -> T) -> T? {
        let t0 = Date()
        do {
            let result = try body()
            Log.info("model: \(info.fileName) \(verb) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return result
        } catch let error as NSError where error.code == notTheFileCode {
            Log.info("model: \(path) not loaded (\(error.localizedDescription))")
            return nil
        } catch {
            Log.info("model: \(path) failed verification (\(error.localizedDescription)); not loaded")
            let rejected = path + ".rejected"
            try? FileManager.default.removeItem(atPath: rejected)
            try? FileManager.default.moveItem(atPath: path, toPath: rejected)
            return nil
        }
    }

    private static func fail(_ msg: String) -> Error {
        NSError(domain: "LocalFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// A failure that says nothing about the pinned file, so it isn't rejected (and downloaded again).
    private static let notTheFileCode = 4
    private static func notTheFile(_ msg: String) -> Error {
        NSError(domain: "LocalFlow", code: notTheFileCode, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Opens the pinned file for reading. O_NOFOLLOW: a symbolic link, which could point anywhere, is refused
    /// rather than followed. The caller owns the descriptor.
    private static func openChecked(_ path: String, _ info: ModelInfo) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail(errno == ELOOP ? "not a regular file" : "cannot open (errno \(errno))") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw fail("not a regular file") }
        guard Int(st.st_size) == info.bytes else {
            close(fd)
            throw fail("file size \(st.st_size) does not match expected \(info.bytes)")
        }
        return fd
    }

    /// Header and SHA-256 of an open file, read through the descriptor.
    private static func hashCheck(_ fd: Int32, _ info: ModelInfo) throws {
        let chunk = 8 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 64)
        defer { buf.deallocate() }
        var hasher = SHA256()
        var total = 0
        while true {
            let n = read(fd, buf, chunk)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let part = UnsafeRawBufferPointer(start: buf, count: n)
            if total == 0 {
                let magic = String(decoding: part.prefix(4), as: UTF8.self)
                guard magic == "lmgg" || magic == "GGUF" else { throw fail("not a model file") }
            }
            hasher.update(bufferPointer: part)
            total += n
        }
        guard total == info.bytes else { throw fail("file changed while it was being read") }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256 else { throw fail("checksum mismatch") }
    }

    private static func readAndCheck(_ path: String, _ info: ModelInfo) throws -> VerifiedModel {
        let fd = try openChecked(path, info)
        defer { close(fd) }

        let model = VerifiedModel(count: info.bytes)
        var done = 0
        while done < info.bytes {
            let n = read(fd, model.bytes + done, min(info.bytes - done, 64 << 20))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            done += n
        }
        var extra: UInt8 = 0
        guard done == info.bytes, read(fd, &extra, 1) == 0 else { throw fail("file changed while it was being read") }
        let all = UnsafeRawBufferPointer(start: model.bytes, count: info.bytes)
        let magic = String(decoding: all.prefix(4), as: UTF8.self)
        guard magic == "lmgg" || magic == "GGUF" else { throw fail("not a model file") }
        let digest = SHA256.hash(data: all).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256 else { throw fail("checksum mismatch") }
        return model
    }

    /// Hugging Face answers with a redirect to its CDN (us.aws.cdn.hf.co at the time of writing): follow it
    /// only over HTTPS and only to Hugging Face hosts. The file is checked against the pinned hash either way.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = request.url?.scheme == "https" && (host == "huggingface.co" || host.hasSuffix(".hf.co"))
        if !allowed { Log.info("model: redirect to \(host.isEmpty ? "?" : host) refused") }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let info = active[downloadTask.taskIdentifier]; lock.unlock()
        guard let info = info else { return }
        // The exact size is pinned, so anything bigger is wrong: stop now rather than fill the disk first.
        if totalBytesWritten > Int64(info.bytes) {
            lock.lock(); failures[downloadTask.taskIdentifier] = "download is larger than the expected \(info.bytes) bytes"; lock.unlock()
            downloadTask.cancel()
            return
        }
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
        if let failure = failure, !ok {
            // Our own reason (rejected file, oversized download) beats the generic "cancelled".
            finalError = NSError(domain: "LocalFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: failure])
        } else if error == nil, !ok {
            finalError = NSError(domain: "LocalFlow", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: failure ?? "Download did not complete"])
        }
        if let e = finalError { Log.info("model: \(info.fileName) failed: \(e.localizedDescription)") }
        DispatchQueue.main.async { self.onFinish?(info, finalError) }
    }
}

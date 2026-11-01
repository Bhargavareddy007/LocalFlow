import AVFoundation
import Foundation

/// Captures the default input device and accumulates 16 kHz mono Float32 PCM.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    func start() throws {
        if isRecording { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        // A fresh engine per recording binds to the current default input. A long-lived engine keeps
        // the old device's format after an input switch (e.g. AirPods connecting), and installTap
        // then raises an Objective-C exception that Swift cannot catch, crashing the app.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "LocalFlow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        guard inFormat.sampleRate == input.inputFormat(forBus: 0).sampleRate else {
            throw NSError(domain: "LocalFlow", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Input device is changing, try again"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        lock.lock(); let out = samples; samples = []; lock.unlock()
        return out
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        let ptr = UnsafeBufferPointer(start: channel[0], count: n)
        var sum: Float = 0
        for v in ptr { sum += v * v }
        let rms = (sum / Float(max(n, 1))).squareRoot()

        lock.lock(); samples.append(contentsOf: ptr); lock.unlock()
        DispatchQueue.main.async { [onLevel] in onLevel?(rms) }
    }
}

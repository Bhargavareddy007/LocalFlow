import AVFoundation
import Foundation

/// Captures the default input device and accumulates 16 kHz mono Float32 PCM.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    /// Recordings whose speech level is below this are whispers or stray presses: the engines
    /// return nothing or invent text. Measured on AirPods: soft voice ≈ -30 dB, whispers -48…-63 dB.
    static let minSpeechLevel: Float = -45

    var onLevel: ((Float) -> Void)?
    /// Called on the main queue once the device delivers real audio. Bluetooth mics (AirPods)
    /// send pure digital silence for up to ~0.6 s while they wake up.
    var onReady: (() -> Void)?
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var heardAudio = false
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
        heardAudio = false
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

    /// Peak, RMS and speech level (90th percentile of 20 ms frames, so pauses don't drag it down)
    /// of a recording, in dBFS.
    static func levels(_ samples: [Float]) -> (peak: Float, rms: Float, speech: Float) {
        var peak: Float = 0, sum: Float = 0
        for v in samples { peak = max(peak, abs(v)); sum += v * v }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        let frame = Int(sampleRate / 50)
        var frames: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var s: Float = 0
            for v in samples[i..<(i + frame)] { s += v * v }
            frames.append((s / Float(frame)).squareRoot())
            i += frame
        }
        frames.sort()
        let speech = frames.isEmpty ? rms : frames[(frames.count - 1) * 9 / 10]
        func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-6)) }
        return (db(peak), db(rms), db(speech))
    }

    /// Writes 16 kHz mono samples to a Float32 WAV file.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
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
        if !heardAudio && sum > 0 {
            heardAudio = true
            DispatchQueue.main.async { [onReady] in onReady?() }
        }
    }
}

import AppKit

/// The floating pill at the bottom of the screen: live waveform while recording,
/// a pulsing label while transcribing.
final class OverlayPanel: NSPanel {
    enum Mode { case recording, locked, transcribing, loading, message }

    private let pill = PillView()
    private var timer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 46),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = pill
    }

    func show(_ mode: Mode, message: String? = nil) {
        pill.mode = mode
        pill.message = message
        let width: CGFloat = (mode == .message || mode == .loading || mode == .locked) ? 290 : 200
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen = screen {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - width / 2, y: frame.minY + 28)
            setFrame(NSRect(origin: origin, size: NSSize(width: width, height: 46)), display: true)
        }
        orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.pill.tick()
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        pill.reset()
    }

    func push(level: Float) { pill.push(level: level) }
}

final class PillView: NSView {
    var mode: OverlayPanel.Mode = .recording
    var message: String?
    private var bars: [CGFloat] = Array(repeating: 0.08, count: 24)
    private var phase: CGFloat = 0

    override var isFlipped: Bool { false }

    func push(level: Float) {
        // Map RMS (~0.005 quiet … 0.2 loud) onto 0…1 with a soft curve.
        let v = min(1, max(0.06, CGFloat(level) * 9))
        bars.removeFirst()
        bars.append(v)
    }

    func reset() {
        bars = Array(repeating: 0.08, count: bars.count)
        phase = 0
    }

    func tick() {
        phase += 0.12
        if mode != .recording && mode != .locked {
            // idle shimmer so the pill still looks alive
            bars.removeFirst()
            bars.append(0.08 + 0.05 * abs(sin(phase)))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        switch mode {
        case .recording:
            drawWave(in: rect)
        case .locked:
            var left = rect
            left.size.width = 180
            drawWave(in: left)
            drawLockDot(in: rect)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
            ]
            let label = "tap fn to stop"
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.maxX - size.width - 30, y: rect.midY - size.height / 2), withAttributes: attrs)
        case .transcribing:
            drawLabel("Transcribing", in: rect, dots: true)
        case .loading:
            drawLabel(message ?? "Loading model", in: rect, dots: true)
        case .message:
            drawLabel(message ?? "", in: rect, dots: false)
        }
    }

    private func drawWave(in rect: NSRect) {
        let count = bars.count
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let total = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = rect.midX - total / 2
        let maxH = rect.height - 18
        let accent = NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1)
        for (i, v) in bars.enumerated() {
            let h = max(3, v * maxH)
            let y = rect.midY - h / 2
            let alpha = 0.45 + 0.55 * CGFloat(i) / CGFloat(count)
            accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                         xRadius: 1.5, yRadius: 1.5).fill()
            x += barWidth + gap
        }
    }

    private func drawLockDot(in rect: NSRect) {
        let d: CGFloat = 7
        NSColor(calibratedRed: 1, green: 0.3, blue: 0.3, alpha: 0.6 + 0.4 * abs(sin(phase))).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - d - 12, y: rect.midY - d / 2, width: d, height: d)).fill()
    }

    private func drawLabel(_ text: String, in rect: NSRect, dots: Bool) {
        let n = dots ? Int(phase * 2) % 4 : 0
        let s = text + String(repeating: ".", count: n)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
        ]
        let size = (text + "...").size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        s.draw(at: origin, withAttributes: attrs)
    }
}

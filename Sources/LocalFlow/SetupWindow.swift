import AppKit
import AVFoundation
import ServiceManagement

/// First-run window: speech model, microphone, accessibility, start at login. Reopened from the menu any time.
/// Always dark, on a painted gradient background, whatever the system appearance.
final class SetupWindowController: NSWindowController {
    private let modelRow = StepRow(symbol: "waveform", colors: [Palette.violet, Palette.indigo], title: "Voice recognition")
    private let micRow = StepRow(symbol: "mic.fill", colors: [Palette.amber, Palette.orange], title: "Microphone")
    private let axRow = StepRow(symbol: "accessibility", colors: [Palette.sky, Palette.blue], title: "Accessibility")
    private let progress = NSProgressIndicator()
    private let loginBox = NSButton(checkboxWithTitle: "Start LocalFlow when I log in", target: nil, action: nil)
    private let footer = NSStackView()
    private let doneButton = GradientButton(title: "Done", symbol: "checkmark")
    private lazy var card = Card(rows: [modelRow, micRow, axRow])
    private var timer: Timer?
    private var wasTrusted = AXIsProcessTrusted()
    /// The voice recognition row is a step only when it needs doing (a download); otherwise it isn't shown.
    private var showModelRow = true

    var onDownloadRequested: (() -> Void)?
    var modelReady: () -> Bool = { false }
    var enginePreparing: () -> Bool = { false }
    var downloadFraction: () -> Double? = { nil }
    var hotkeyName: () -> String = { "fn" }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LocalFlow Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window = window else { return }
        let background = BackdropView()
        window.contentView = background

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.shadow = {
            let s = NSShadow()
            s.shadowColor = Palette.violet.withAlphaComponent(0.55)
            s.shadowBlurRadius = 24
            return s
        }()
        let title = TitleView(plain: "Welcome to ", gradient: "LocalFlow", size: 32,
                              colors: [Palette.cyan, Palette.periwinkle, Palette.violet])
        let subtitle = label("Private, on-device voice typing for your Mac.", size: 15, alpha: 0.78)
        let header = NSStackView(views: [icon, title, subtitle])
        header.orientation = .vertical
        header.spacing = 8
        header.setCustomSpacing(18, after: icon)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        modelRow.addAccessory(progress)

        modelRow.button.target = self; modelRow.button.action = #selector(downloadTapped)
        micRow.button.target = self; micRow.button.action = #selector(micTapped)
        axRow.button.target = self; axRow.button.action = #selector(axTapped)
        loginBox.target = self; loginBox.action = #selector(loginTapped)
        loginBox.attributedTitle = NSAttributedString(string: "  Start LocalFlow when I log in", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
        doneButton.target = self; doneButton.action = #selector(doneTapped)
        doneButton.keyEquivalent = "\r"

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7
        let bottom = NSStackView(views: [footer, NSView(), doneButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY

        let stack = NSStackView(views: [header, card, loginBox, bottom])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.setCustomSpacing(32, after: header)
        stack.setCustomSpacing(26, after: loginBox)
        stack.edgeInsets = NSEdgeInsets(top: 52, left: 40, bottom: 30, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            card.widthAnchor.constraint(equalToConstant: 520),
            loginBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            bottom.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
    }

    func show() {
        showModelRow = !modelReady()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        fitWindow()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Sizes the window to its content, keeping its top edge where it is.
    private func fitWindow() {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func refresh() {
        // Voice recognition: shown only while it has to be downloaded, then until the window closes.
        if modelRow.isHidden == showModelRow {
            modelRow.isHidden = !showModelRow
            card.lines.first?.isHidden = !showModelRow
            fitWindow()
        }
        progress.isHidden = true
        if modelReady() && enginePreparing() {
            modelRow.set(detail: "Getting ready… (the first time takes about 30 s)", done: nil)
        } else if modelReady() {
            modelRow.set(detail: "Ready to use, works offline", done: "Ready")
        } else if let f = downloadFraction() {
            modelRow.set(detail: "Downloading once… \(Int(f * 100))%", done: nil)
            progress.isHidden = false
            progress.doubleValue = f
        } else {
            modelRow.set(detail: "\(ModelInfo.parakeet.sizeMB) MB, downloaded once", done: nil,
                         button: "Download", symbol: "arrow.down.circle")
        }

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micRow.set(detail: "Listens only while you hold \(hotkeyName())", done: "Allowed")
        case .denied, .restricted:
            micRow.set(detail: "Turned off. Turn on LocalFlow in System Settings", done: nil,
                       button: "Open Settings", symbol: "arrow.up.forward.square")
        default:
            micRow.set(detail: "Listens only while you hold \(hotkeyName())", done: nil, button: "Allow", symbol: "mic")
        }

        // Accessibility
        let trusted = AXIsProcessTrusted()
        if trusted {
            axRow.set(detail: "Lets LocalFlow type where your cursor is", done: "On")
        } else {
            axRow.set(detail: "Turn on LocalFlow in the list that opens", done: nil,
                      button: "Open Settings", symbol: "arrow.up.forward.square")
        }
        // Switched on in System Settings: come back to the front to show the result.
        if trusted, !wasTrusted, window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        wasTrusted = trusted

        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let allDone = modelReady() && !enginePreparing()
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && trusted
        footer.setViews(allDone ? readyFooter() : privacyFooter(), in: .leading)
    }

    private func privacyFooter() -> [NSView] {
        [symbol("lock", tint: NSColor.white.withAlphaComponent(0.55), size: 13),
         label("Your speech stays on this Mac. Always.", size: 13, alpha: 0.6)]
    }

    private func readyFooter() -> [NSView] {
        [symbol("checkmark.circle.fill", tint: Palette.green, size: 15),
         label("All set. Hold", size: 13.5, alpha: 0.92, weight: .medium),
         Keycap(hotkeyName()),
         label("and speak.", size: 13.5, alpha: 0.92, weight: .medium)]
    }

    @objc private func downloadTapped() { onDownloadRequested?(); refresh() }

    @objc private func micTapped() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func axTapped() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func loginTapped() {
        do {
            if loginBox.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
        // Turned off earlier in System Settings › General › Login Items: only the user can turn it back on there.
        if loginBox.state == .on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    @objc private func doneTapped() {
        timer?.invalidate()
        timer = nil
        window?.close()
    }
}

// MARK: - Look

private enum Palette {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let night = rgb(0x121831), dusk = rgb(0x1B1D42), plum = rgb(0x271C42)
    static let cyan = rgb(0x6FE3FF), periwinkle = rgb(0x8FA8FF), violet = rgb(0xA77BFF), indigo = rgb(0x5B5CF0)
    static let amber = rgb(0xFFC15A), orange = rgb(0xF2742B), sky = rgb(0x5CC0FF), blue = rgb(0x2F6BFF)
    static let peach = rgb(0xFFB27A), magenta = rgb(0xC0507A), green = rgb(0x5ED37A), mint = rgb(0xA6F0B6)
}

private func label(_ text: String, size: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = NSColor.white.withAlphaComponent(alpha)
    return l
}

private func symbol(_ name: String, tint: NSColor, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImageView {
    let v = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!)
    v.symbolConfiguration = .init(pointSize: size, weight: weight)
    v.contentTintColor = tint
    return v
}

/// Night-sky gradient with soft glows and two light ribbons.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        NSGradient(colors: [Palette.night, Palette.dusk, Palette.plum])!.draw(in: b, angle: -90)

        func glow(_ color: NSColor, _ x: CGFloat, _ yFromTop: CGFloat, _ radius: CGFloat) {
            let c = NSPoint(x: x, y: b.maxY - yFromTop)
            NSGradient(colors: [color, color.withAlphaComponent(0)])!
                .draw(fromCenter: c, radius: 0, toCenter: c, radius: radius, options: [])
        }
        glow(Palette.blue.withAlphaComponent(0.30), b.minX + 40, 250, 280)
        glow(Palette.violet.withAlphaComponent(0.28), b.maxX - 60, 200, 300)
        glow(Palette.peach.withAlphaComponent(0.20), b.maxX - 20, 140, 170)
        glow(Palette.magenta.withAlphaComponent(0.16), b.maxX - 100, b.height - 60, 240)

        // Right ribbon, behind the header: a soft band rising to the top right corner, lit along its upper edge.
        let ribbon = NSBezierPath()
        ribbon.move(to: NSPoint(x: b.width * 0.52, y: b.maxY - 245))
        ribbon.curve(to: NSPoint(x: b.maxX, y: b.maxY - 95),
                     controlPoint1: NSPoint(x: b.width * 0.72, y: b.maxY - 225),
                     controlPoint2: NSPoint(x: b.width * 0.86, y: b.maxY - 110))
        let band = ribbon.copy() as! NSBezierPath
        band.line(to: NSPoint(x: b.maxX, y: b.maxY - 215))
        band.curve(to: NSPoint(x: b.width * 0.52, y: b.maxY - 245),
                   controlPoint1: NSPoint(x: b.width * 0.86, y: b.maxY - 215),
                   controlPoint2: NSPoint(x: b.width * 0.70, y: b.maxY - 245))
        band.close()
        NSGradient(colors: [Palette.violet.withAlphaComponent(0), Palette.violet.withAlphaComponent(0.16),
                            Palette.peach.withAlphaComponent(0.20)])!.draw(in: band, angle: 15)
        stroke(ribbon, in: ctx, width: 1.5, colors: [Palette.violet.withAlphaComponent(0), Palette.peach.withAlphaComponent(0.5)])

        // Left ribbon: a faint blue line sweeping in from the left edge, ending before the card.
        let left = NSBezierPath()
        left.move(to: NSPoint(x: b.minX, y: b.maxY - 175))
        left.curve(to: NSPoint(x: b.width * 0.36, y: b.maxY - 250),
                   controlPoint1: NSPoint(x: b.width * 0.14, y: b.maxY - 190),
                   controlPoint2: NSPoint(x: b.width * 0.26, y: b.maxY - 245))
        stroke(left, in: ctx, width: 1.2, colors: [Palette.sky.withAlphaComponent(0.4), Palette.sky.withAlphaComponent(0)])
    }

    private func stroke(_ path: NSBezierPath, in ctx: CGContext, width: CGFloat, colors: [NSColor]) {
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        NSGradient(colors: colors)!.draw(in: path.bounds.insetBy(dx: -2, dy: -2), angle: 0)
        ctx.restoreGState()
    }
}

/// "Welcome to" in white, then the app name filled with a gradient.
private final class TitleView: NSView {
    private let plain: NSAttributedString
    private let fancy: NSAttributedString
    private let colors: [NSColor]

    init(plain: String, gradient: String, size: CGFloat, colors: [NSColor]) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        self.plain = NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: NSColor.white])
        self.fancy = NSAttributedString(string: gradient, attributes: [.font: font, .foregroundColor: NSColor.white])
        self.colors = colors
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(plain.size().width + fancy.size().width) + 2, height: ceil(plain.size().height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        plain.draw(at: NSPoint(x: 1, y: 1))
        let origin = NSPoint(x: 1 + plain.size().width, y: 1)
        let rect = NSRect(origin: origin, size: fancy.size())
        // The letters are drawn first, then the gradient only where they are.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        fancy.draw(at: origin)
        ctx.setBlendMode(.sourceIn)
        NSGradient(colors: colors)!.draw(in: rect, angle: 0)
        ctx.endTransparencyLayer()
    }
}

/// One setup step: a gradient badge, a title with a line of detail, and a status pill or a button.
private final class StepRow: NSView {
    let button = GlassButton()
    private let detail = label("", size: 13, alpha: 0.62)
    private let pill = StatusPill()
    private let texts: NSStackView

    init(symbol name: String, colors: [NSColor], title: String) {
        let badge = GradientView(colors: colors, angle: -60)
        badge.layer?.cornerRadius = 11
        let glyph = symbol(name, tint: .white, size: 19)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyph)

        detail.lineBreakMode = .byTruncatingTail
        texts = NSStackView(views: [label(title, size: 16, alpha: 1, weight: .semibold), detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3

        let row = NSStackView(views: [badge, texts, NSView(), pill, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 80),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 44),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            texts.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A view shown under the detail line (the download progress bar).
    func addAccessory(_ view: NSView) {
        texts.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: 240).isActive = true
    }

    /// `done` shows a green pill with that word; otherwise `button`, if given, shows that button.
    func set(detail text: String, done: String?, button title: String? = nil, symbol: String? = nil) {
        detail.stringValue = text
        pill.text = done ?? ""
        pill.isHidden = done == nil
        button.isHidden = done != nil || title == nil
        if let title = title { button.set(title: title, symbol: symbol) }
    }
}

/// A view filled with a linear gradient.
private final class GradientView: NSView {
    init(colors: [NSColor], angle: CGFloat) {
        super.init(frame: .zero)
        let g = CAGradientLayer()
        g.colors = colors.map(\.cgColor)
        let r = angle * .pi / 180
        g.startPoint = CGPoint(x: 0.5 - cos(r) / 2, y: 0.5 - sin(r) / 2)
        g.endPoint = CGPoint(x: 0.5 + cos(r) / 2, y: 0.5 + sin(r) / 2)
        layer = g
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Green "✓ Ready" capsule.
private final class StatusPill: NSView {
    private let word = label("", size: 13.5, alpha: 1, weight: .medium)
    var text: String {
        get { word.stringValue }
        set { word.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.backgroundColor = Palette.green.withAlphaComponent(0.14).cgColor
        layer?.borderColor = Palette.green.withAlphaComponent(0.30).cgColor
        word.textColor = Palette.mint
        let row = NSStackView(views: [symbol("checkmark.circle.fill", tint: Palette.green, size: 15), word])
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Translucent outlined button with a symbol.
private final class GlassButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .white
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, symbol: String?) {
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 30, height: 36)
    }
}

/// The glowing blue-violet Done button.
private final class GradientButton: NSButton {
    private let fill = CAGradientLayer()

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        fill.colors = [Palette.blue.cgColor, Palette.indigo.cgColor, Palette.violet.cgColor]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = 22
        fill.borderWidth = 1
        fill.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.insertSublayer(fill, at: 0)
        layer?.shadowColor = Palette.blue.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 14
        layer?.shadowOffset = .zero
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .white
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .bold))
        attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill.frame = bounds
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 44) }
}

/// A rounded, translucent group of rows with hairlines between them.
private final class Card: NSView {
    /// The hairlines; `lines[i]` sits above `rows[i + 1]`.
    private(set) var lines: [NSView] = []

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                line.widthAnchor.constraint(equalToConstant: 480).isActive = true
                lines.append(line)
                views.append(line)
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The dictation key drawn as a small keycap.
private final class Keycap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        let l = label(text, size: 12.5, alpha: 1, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

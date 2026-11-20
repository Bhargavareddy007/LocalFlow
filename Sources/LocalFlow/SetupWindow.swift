import AppKit
import AVFoundation
import ServiceManagement

/// First-run window: speech model, microphone, accessibility, start at login. Reopened from the menu any time.
final class SetupWindowController: NSWindowController {
    private let modelRow = StepRow(symbol: "waveform", tint: .systemIndigo, title: "Speech model")
    private let micRow = StepRow(symbol: "mic.fill", tint: .systemOrange, title: "Microphone")
    private let axRow = StepRow(symbol: "accessibility", tint: .systemBlue, title: "Accessibility")
    private let progress = NSProgressIndicator()
    private let loginBox = NSButton(checkboxWithTitle: "Start LocalFlow when I log in", target: nil, action: nil)
    private let footer = NSStackView()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var timer: Timer?
    private var wasTrusted = AXIsProcessTrusted()

    var onDownloadRequested: (() -> Void)?
    var modelReady: () -> Bool = { false }
    var enginePreparing: () -> Bool = { false }
    var downloadFraction: () -> Double? = { nil }
    var hotkeyName: () -> String = { "fn" }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LocalFlow Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window = window else { return }
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Welcome to LocalFlow")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Voice typing that never leaves this Mac.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, title, subtitle])
        header.orientation = .vertical
        header.spacing = 6
        header.setCustomSpacing(14, after: icon)

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
        doneButton.target = self; doneButton.action = #selector(doneTapped)
        doneButton.keyEquivalent = "\r"
        doneButton.controlSize = .large

        let card = Card(rows: [modelRow, micRow, axRow])

        footer.orientation = .horizontal
        footer.spacing = 6
        let bottom = NSStackView(views: [footer, NSView(), doneButton])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [header, card, loginBox, bottom])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(26, after: header)
        stack.setCustomSpacing(22, after: loginBox)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 32, bottom: 26, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
            card.widthAnchor.constraint(equalToConstant: 476),
            loginBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            bottom.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
    }

    func show() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        if let window = window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        // Speech model
        progress.isHidden = true
        if modelReady() && enginePreparing() {
            modelRow.set(detail: "Getting ready… (the first time takes about 30 s)", done: nil)
        } else if modelReady() {
            modelRow.set(detail: "Runs on this Mac, no internet needed", done: "Ready")
        } else if let f = downloadFraction() {
            modelRow.set(detail: "Downloading… \(Int(f * 100))%", done: nil)
            progress.isHidden = false
            progress.doubleValue = f
        } else {
            modelRow.set(detail: "\(ModelInfo.parakeet.sizeMB) MB, downloaded once", done: nil, button: "Download")
        }

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micRow.set(detail: "Listens only while you hold \(hotkeyName())", done: "Allowed")
        case .denied, .restricted:
            micRow.set(detail: "Turned off. Turn on LocalFlow in System Settings", done: nil, button: "Open Settings")
        default:
            micRow.set(detail: "Listens only while you hold \(hotkeyName())", done: nil, button: "Allow")
        }

        // Accessibility
        let trusted = AXIsProcessTrusted()
        if trusted {
            axRow.set(detail: "Lets LocalFlow type where your cursor is", done: "On")
        } else {
            axRow.set(detail: "Turn on LocalFlow in the list that opens", done: nil, button: "Open Settings")
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
        footer.setViews(allDone ? readyFooter() : [secondary("Finish the steps above to start dictating.")], in: .leading)
    }

    private func readyFooter() -> [NSView] {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
        check.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        check.contentTintColor = .systemGreen
        let hold = NSTextField(labelWithString: "All set. Hold")
        let rest = NSTextField(labelWithString: "and speak, then let go.")
        for l in [hold, rest] { l.font = .systemFont(ofSize: 13, weight: .medium) }
        return [check, hold, Keycap(hotkeyName()), rest]
    }

    private func secondary(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
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

/// One setup step: a tinted symbol, a title with a line of detail, and either a checkmark or a button.
private final class StepRow: NSView {
    let button = NSButton(title: "", target: nil, action: nil)
    private let detail = NSTextField(labelWithString: "")
    private let doneLabel = NSTextField(labelWithString: "")
    private let doneIcon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
    private let texts: NSStackView

    init(symbol: String, tint: NSColor, title: String) {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.backgroundColor = tint.cgColor
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        glyph.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyph)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        doneIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        doneIcon.contentTintColor = .systemGreen
        doneLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        doneLabel.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded

        let row = NSStackView(views: [badge, texts, NSView(), doneLabel, doneIcon, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.setCustomSpacing(5, after: doneLabel)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 62),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            texts.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A view shown under the detail line (the download progress bar).
    func addAccessory(_ view: NSView) {
        texts.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }

    /// `done` shows a checkmark with that word; otherwise `button`, if given, shows that button.
    func set(detail text: String, done: String?, button title: String? = nil) {
        detail.stringValue = text
        doneLabel.stringValue = done ?? ""
        doneLabel.isHidden = done == nil
        doneIcon.isHidden = done == nil
        button.isHidden = done != nil || title == nil
        if let title = title { button.title = title }
    }
}

/// A rounded group of rows with hairlines between them, like a System Settings section.
private final class Card: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                views.append(line)
                line.widthAnchor.constraint(equalToConstant: 420).isActive = true
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor(white: 1, alpha: dark ? 0.06 : 0.75).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.08).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// The dictation key drawn as a small keycap.
private final class Keycap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.1 : 0.05).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.25).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

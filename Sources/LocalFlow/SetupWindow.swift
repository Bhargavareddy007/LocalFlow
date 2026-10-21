import AppKit
import AVFoundation

/// First-run window: model download, microphone, accessibility. Reopened from the menu any time.
final class SetupWindowController: NSWindowController {
    private let modelStatus = NSTextField(labelWithString: "")
    private let modelButton = NSButton(title: "Download", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton(title: "Allow", target: nil, action: nil)
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var timer: Timer?

    var onDownloadRequested: (() -> Void)?
    var modelReady: () -> Bool = { false }
    var enginePreparing: () -> Bool = { false }
    var downloadFraction: () -> Double? = { nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LocalFlow Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Welcome to LocalFlow")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Three quick steps, then hold the fn key and talk. Your voice is processed on this Mac only.")
        subtitle.textColor = .secondaryLabelColor

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small

        modelButton.target = self; modelButton.action = #selector(downloadTapped)
        micButton.target = self; micButton.action = #selector(micTapped)
        axButton.target = self; axButton.action = #selector(axTapped)
        doneButton.target = self; doneButton.action = #selector(doneTapped)
        doneButton.keyEquivalent = "\r"

        let modelRow = row("1. Speech model", modelStatus, modelButton)
        let micRow = row("2. Microphone", micStatus, micButton)
        let axRow = row("3. Accessibility", axStatus, axButton)
        let axHint = NSTextField(wrappingLabelWithString:
            "In the list that opens, turn on LocalFlow. This lets the app see the fn key and type into other apps.")
        axHint.font = .systemFont(ofSize: 11)
        axHint.textColor = .secondaryLabelColor

        footer.font = .systemFont(ofSize: 13, weight: .medium)

        let bottom = NSStackView(views: [footer, NSView(), doneButton])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [title, subtitle, separator(), modelRow, progress, separator(), micRow, separator(), axRow, axHint, separator(), bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            progress.widthAnchor.constraint(equalToConstant: 412),
            subtitle.widthAnchor.constraint(equalToConstant: 412),
            axHint.widthAnchor.constraint(equalToConstant: 412),
            bottom.widthAnchor.constraint(equalToConstant: 412),
        ])
        for r in [modelRow, micRow, axRow] { r.widthAnchor.constraint(equalToConstant: 412).isActive = true }
    }

    private func row(_ name: String, _ status: NSTextField, _ button: NSButton) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [label, status, NSView(), button])
        s.orientation = .horizontal
        return s
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 412).isActive = true
        return b
    }

    func show() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        // Model
        if modelReady() && enginePreparing() {
            modelStatus.stringValue = "Preparing engine… (first time takes about 30 s)"
            modelButton.isHidden = true
            progress.isHidden = true
        } else if modelReady() {
            modelStatus.stringValue = "Ready ✓"
            modelButton.isHidden = true
            progress.isHidden = true
        } else if let f = downloadFraction() {
            modelStatus.stringValue = "Downloading… \(Int(f * 100))%"
            modelButton.isHidden = true
            progress.isHidden = false
            progress.doubleValue = f
        } else {
            modelStatus.stringValue = "Not downloaded (\(ModelInfo.parakeet.sizeMB) MB, one time)"
            modelButton.isHidden = false
            progress.isHidden = true
        }
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus.stringValue = "Allowed ✓"; micButton.isHidden = true
        case .denied, .restricted:
            micStatus.stringValue = "Blocked — enable in System Settings"; micButton.title = "Open System Settings"; micButton.isHidden = false
        default:
            micStatus.stringValue = "Not yet allowed"; micButton.title = "Allow"; micButton.isHidden = false
        }
        // Accessibility
        if AXIsProcessTrusted() {
            axStatus.stringValue = "Enabled ✓"; axButton.isHidden = true
        } else {
            axStatus.stringValue = "Not yet enabled"; axButton.isHidden = false
        }
        let allDone = modelReady() && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
        footer.stringValue = allDone ? "All set. Hold fn and speak, release to type." : "Finish the steps above."
        footer.textColor = allDone ? .systemGreen : .secondaryLabelColor
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

    @objc private func doneTapped() {
        timer?.invalidate()
        timer = nil
        window?.close()
    }
}

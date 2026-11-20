import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, transcribing }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let hotkeys = HotkeyManager()
    private let recorder = AudioRecorder()
    private let overlay = OverlayPanel()
    private let workQueue = DispatchQueue(label: "localflow.engine", qos: .userInitiated)

    /// Owned by workQueue: read and written there only. UI reads `engineReady` instead.
    private var engine: SpeechEngine?
    private var engineReady = false
    private var engineLoading = false
    private var target: FocusSnapshot?
    /// Owned by workQueue like `engine`; UI reads `polisherReady`.
    private var polisherReady = false
    private var state: State = .idle
    private var pressTime: Date?
    private var locked = false
    private var micReady = false
    private var ignoreNextRelease = false
    private var lastShortTap: Date?
    private var lockTimer: Timer?
    private var accessibilityTimer: Timer?
    private var hideTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private lazy var setup = SetupWindowController()
    private var downloadFractions: [String: Double] = [:]   // keyed by model file name
    private var polisher: Polisher?
    private var polishLoading = false

    private var startSound: NSSound? = { let s = NSSound(named: "Pop"); s?.volume = 0.35; return s }()
    private var stopSound: NSSound? = { let s = NSSound(named: "Tink"); s?.volume = 0.25; return s }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runningFromDownload() {
            askToMoveToApplications()
            return
        }
        // Two copies (say one in Downloads, one in Applications) would both record and paste every dictation.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0 != NSRunningApplication.current }) {
            Log.info("another LocalFlow is already running (pid \(other.processIdentifier)); quitting")
            exit(0)
        }
        Log.rotateIfNeeded()
        if !UserDefaults.standard.bool(forKey: "logPurged1") {
            // Versions before 0.1.1 wrote dictated text into the log; remove any such log once.
            Log.clear()
            UserDefaults.standard.set(true, forKey: "logPurged1")
        }
        // No dictation record outlives a session: delete the pre-0.2.0 history file, and if dictated text
        // was being logged for troubleshooting when the app last quit, switch that off and wipe the log.
        History.deleteLegacyFile()
        // 0.2.1 kept the text-logging switch in the preferences; it's memory-only now.
        if UserDefaults.standard.bool(forKey: "verboseLog") { Log.clear() }
        UserDefaults.standard.removeObject(forKey: "verboseLog")
        #if !DEBUG
        // 0.2.1 and earlier could keep recordings of dictations; release builds never save any now.
        try? FileManager.default.removeItem(at: Settings.supportDir.appendingPathComponent("recordings"))
        #endif
        Log.info("LocalFlow starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        PersonalDictionary.ensureFileExists()
        PersonalDictionary.reload()
        EngineLoader.quietLogs()

        // A fresh install (no speech model yet) starts at login, so dictation still works after a restart;
        // the setup window shows this with a checkbox to turn it off. Updates keep what the user chose.
        let freshInstall = Settings.shared.modelPath(for: .parakeet) == nil && Settings.shared.modelPath(for: .whisper) == nil
        if freshInstall, !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            do { try SMAppService.mainApp.register() } catch { Log.info("launch at login failed: \(error)") }
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
        }

        setupStatusItem()
        setupHotkeys()
        setupDownloads()
        requestMicrophone()
        ensureAccessibility()

        if Settings.shared.modelPath(for: Settings.shared.engine) != nil {
            loadEngine(Settings.shared.engine)
        } else if Settings.shared.modelPath(for: .parakeet) != nil {
            Settings.shared.engine = .parakeet
            loadEngine(.parakeet)
        } else {
            Settings.shared.engine = .parakeet
            ModelManager.shared.download(.parakeet)
        }
        let needsSetup = Settings.shared.modelPath(for: Settings.shared.engine) == nil
            || !AXIsProcessTrusted()
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        if needsSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSetup() }
        }

        recorder.onLevel = { [weak self] level in self?.overlay.push(level: level) }
        recorder.onReady = { [weak self] in self?.micBecameReady() }
        if Settings.shared.signalToggle { setupSignalToggle() }
    }

    /// Opened straight from the disk image, or from Downloads without being moved (macOS then runs it from
    /// a hidden read-only copy). Permissions and "Launch at login" would belong to a copy that goes away.
    private func runningFromDownload() -> Bool {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return readOnly || url.path.contains("/AppTranslocation/")
    }

    private func askToMoveToApplications() {
        Log.info("running from \(Bundle.main.bundlePath); asked to move to Applications")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move LocalFlow to Applications first"
        alert.informativeText = "Drag LocalFlow into your Applications folder, then open it from there."
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
        NSApp.terminate(nil)
    }

    /// `kill -USR1 $(pgrep -x LocalFlow)` toggles hands-free dictation — handy for
    /// Raycast / Keyboard Maestro / Stream Deck and for testing. Off unless Settings.signalToggle is set,
    /// since any process of the same user could otherwise turn the mic on.
    private func setupSignalToggle() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            switch self.state {
            case .idle:
                self.pressTime = nil
                self.startRecording()
                self.enterHandsFree()
            case .recording:
                self.stopAndTranscribe()
            case .transcribing:
                break
            }
        }
        src.resume()
        signalSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        if recorder.isRecording { _ = recorder.stop() }
        workQueue.sync { self.engine = nil; self.polisher = nil } // release Metal buffers cleanly
        // "Until quit": dictated text logged for troubleshooting doesn't stay on disk after the app quits.
        // (After a crash, the same cleanup runs at the next launch.)
        if Settings.shared.verboseLog {
            Settings.shared.verboseLog = false
            Log.clear()
        }
    }

    // MARK: - Setup window & model downloads

    private func setupDownloads() {
        setup.modelReady = { Settings.shared.modelPath(for: Settings.shared.engine) != nil }
        setup.enginePreparing = { [weak self] in self?.engineLoading ?? false }
        setup.downloadFraction = { [weak self] in self?.downloadFractions[ModelInfo.info(for: Settings.shared.engine).fileName] }
        setup.onDownloadRequested = { ModelManager.shared.download(Settings.shared.engine) }
        ModelManager.shared.onProgress = { [weak self] info, f in
            self?.downloadFractions[info.fileName] = f
        }
        ModelManager.shared.onFinish = { [weak self] info, error in
            guard let self = self else { return }
            self.downloadFractions[info.fileName] = nil
            if let error = error {
                self.flash("Model download failed: \(error.localizedDescription)", seconds: 4)
                return
            }
            if let engine = info.engine {
                if engine == Settings.shared.engine { self.loadEngine(engine) }
            } else {
                self.loadPolisher()
            }
            self.setup.refresh()
        }
    }

    @objc private func showSetup() { setup.show() }

    @objc private func downloadPolishModel() {
        // "Enable polish wording — download model": the click is the opt-in, so polish is on once it arrives.
        Settings.shared.polishEnabled = true
        ModelManager.shared.download(model: ModelInfo.polish)
        flash("Downloading polish model (\(ModelInfo.polish.sizeMB) MB)…", seconds: 2.5)
    }

    @objc private func togglePolish() {
        Settings.shared.polishEnabled.toggle()
        if Settings.shared.polishEnabled, !polisherReady { loadPolisher() }
    }

    private func loadPolisher() {
        guard Settings.shared.polishFeature, Settings.shared.polishEnabled, Settings.shared.polishModelPath() != nil, !polishLoading else { return }
        polishLoading = true
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let p = PolisherLoader.load()
            _ = p?.polish("this is a short warm up sentence for the model")
            self.polisher = p
            DispatchQueue.main.async {
                self.polisherReady = p != nil
                self.polishLoading = false
            }
        }
    }

    @objc private func downloadWhisper() {
        ModelManager.shared.download(.whisper)
        flash("Downloading Whisper model (\(ModelInfo.whisper.sizeMB) MB)…", seconds: 2.5)
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        var tint: NSColor? = nil
        switch state {
        case .idle:
            name = engineReady ? "waveform" : "waveform.slash"
            if Settings.shared.verboseLog { tint = .systemOrange }  // dictated text is being logged
        case .recording: name = "waveform.circle.fill"; tint = .systemRed
        case .transcribing: name = "ellipsis.circle.fill"; tint = .systemBlue
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        let status: String
        if let f = downloadFractions[ModelInfo.info(for: s.engine).fileName] { status = "Downloading \(s.engine.rawValue) model… \(Int(f * 100))%" }
        else if engineLoading { status = "Loading \(s.engine.rawValue) model…" }
        else if !engineReady { status = "No model yet — open Setup to download it" }
        else if !hotkeys.isRunning { status = "Waiting for Accessibility permission" }
        else { status = "Hold \(s.hotkey.shortName) to dictate · \(s.engine.rawValue) ready" }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Hotkey
        let hotkeyMenu = NSMenu()
        for hk in Hotkey.allCases {
            let item = NSMenuItem(title: hk.title, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            item.representedObject = hk.rawValue
            item.state = hk == s.hotkey ? .on : .off
            item.target = self
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Dictation key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // Engine
        let engineMenu = NSMenu()
        for e in Engine.allCases {
            let item = NSMenuItem(title: e.title, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            item.representedObject = e.rawValue
            item.state = e == s.engine ? .on : .off
            item.target = self
            item.isEnabled = s.modelPath(for: e) != nil
            engineMenu.addItem(item)
        }
        if s.modelPath(for: .whisper) == nil {
            engineMenu.addItem(.separator())
            let dl: NSMenuItem
            if let f = downloadFractions[ModelInfo.whisper.fileName] {
                dl = NSMenuItem(title: "Downloading Whisper model… \(Int(f * 100))%", action: nil, keyEquivalent: "")
                dl.isEnabled = false
            } else {
                dl = NSMenuItem(title: "Download Whisper model (\(ModelInfo.whisper.sizeMB) MB)…", action: #selector(downloadWhisper), keyEquivalent: "")
                dl.target = self
            }
            engineMenu.addItem(dl)
        }
        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // Language (Whisper only)
        let langMenu = NSMenu()
        for lang in Language.all {
            let item = NSMenuItem(title: lang.name, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.state = lang.code == s.language ? .on : .off
            item.target = self
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language (Whisper engine)", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        if !s.polishFeature {
            // parked feature: no menu entry
        } else if s.polishModelPath() != nil {
            let title = polishLoading ? "Polish wording (local AI) — loading…" : "Polish wording (local AI)"
            addToggle(title, s.polishEnabled, #selector(togglePolish))
        } else if let f = downloadFractions[ModelInfo.polish.fileName] {
            let item = NSMenuItem(title: "Downloading polish model… \(Int(f * 100))%", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            addAction("Enable polish wording — download model (\(ModelInfo.polish.sizeMB) MB)…", #selector(downloadPolishModel))
        }
        addToggle("Remove filler words (um, uh)", s.removeFillers, #selector(toggleFillers))
        addToggle("Smart spacing before inserted text", s.smartSpacing, #selector(toggleSpacing))
        addToggle("Double-tap key for hands-free mode", s.tapToLock, #selector(toggleTapToLock))
        addToggle("Sounds", s.playSounds, #selector(toggleSounds))
        addToggle("Write dictated text to the log (until quit, for troubleshooting)", s.verboseLog, #selector(toggleVerboseLog))
        addToggle("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin))
        menu.addItem(.separator())

        // Only the last dictation, for two minutes, in case the paste didn't land.
        if let last = History.shared.last {
            var preview = last.replacingOccurrences(of: "\n", with: " ")
            if preview.count > 50 { preview = String(preview.prefix(50)) + "…" }
            let item = NSMenuItem(title: "Copy last dictation: \u{201C}\(preview)\u{201D}", action: #selector(copyLast), keyEquivalent: "")
            item.target = self
            item.toolTip = last
            menu.addItem(item)
        } else {
            let none = NSMenuItem(title: "Copy last dictation (kept for 2 minutes)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        addAction("Setup & permissions…", #selector(showSetup))
        addAction("Edit personal dictionary…", #selector(openDictionary))
        addAction("Open models folder…", #selector(openModels))
        addAction("Open log…", #selector(openLog))
        menu.addItem(.separator())
        addAction("Accessibility permission…", #selector(openAccessibilitySettings))
        addAction("Microphone permission…", #selector(openMicrophoneSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addToggle(_ title: String, _ on: Bool, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Menu actions

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let hk = Hotkey(rawValue: raw) else { return }
        Settings.shared.hotkey = hk
        Log.info("hotkey set to \(hk.rawValue)")
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = Engine(rawValue: raw) else { return }
        guard e != Settings.shared.engine || !engineReady else { return }
        Settings.shared.engine = e
        if Settings.shared.modelPath(for: e) != nil { loadEngine(e) } else { ModelManager.shared.download(e); showSetup() }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.shared.language = code
    }

    @objc private func toggleFillers() { Settings.shared.removeFillers.toggle() }
    @objc private func toggleSpacing() { Settings.shared.smartSpacing.toggle() }
    @objc private func toggleTapToLock() { Settings.shared.tapToLock.toggle() }
    @objc private func toggleSounds() { Settings.shared.playSounds.toggle() }
    /// Turning it off also deletes the log, which may hold dictated text from while it was on.
    @objc private func toggleVerboseLog() {
        Settings.shared.verboseLog.toggle()
        if !Settings.shared.verboseLog { Log.clear() }
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
    }

    @objc private func copyLast() {
        guard let text = History.shared.last else { return }
        TextInserter.copyOnly(text)
    }

    @objc private func openDictionary() {
        PersonalDictionary.ensureFileExists()
        NSWorkspace.shared.open(Settings.dictionaryURL)
    }

    @objc private func openModels() { NSWorkspace.shared.open(Settings.modelsDir) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: - Permissions

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Log.info("microphone: authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("microphone: \(granted ? "granted" : "denied")")
            }
        default:
            Log.info("microphone: denied — open System Settings > Privacy & Security > Microphone")
        }
    }

    private func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            Log.info("accessibility: trusted")
            hotkeys.start()
            return
        }
        Log.info("accessibility: not trusted yet, waiting for the user to enable it")
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if AXIsProcessTrusted() {
                Log.info("accessibility: granted")
                t.invalidate()
                self.accessibilityTimer = nil
                self.hotkeys.start()
            }
        }
    }

    // MARK: - Engine

    private func loadEngine(_ kind: Engine) {
        engineLoading = true
        engineReady = false
        updateIcon()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.engine = nil
            let loaded = EngineLoader.load(kind)
            // Warm up Metal pipelines so the first real dictation is fast.
            _ = loaded?.transcribe([Float](repeating: 0, count: Int(AudioRecorder.sampleRate)), language: Settings.shared.language)
            self.engine = loaded   // assigned on the same queue that runs transcriptions: no race
            DispatchQueue.main.async {
                self.engineReady = loaded != nil
                self.engineLoading = false
                self.updateIcon()
                if loaded == nil, Settings.shared.modelPath(for: kind) == nil {
                    // Missing, or it failed the check before loading and was set aside.
                    self.flash("The \(kind.rawValue) model needs downloading again", seconds: 3)
                    ModelManager.shared.download(kind)
                    self.showSetup()
                } else if loaded == nil {
                    self.flash("The \(kind.rawValue) model could not be loaded", seconds: 3)
                }
                if !self.polisherReady { self.loadPolisher() }
            }
        }
    }

    // MARK: - Hotkey → recording

    private func setupHotkeys() {
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onInterrupt = { [weak self] in self?.hotkeyInterrupted() }
    }

    /// The key was part of a shortcut: drop the recording, and with it any half-finished tap or
    /// pending release, so the shortcut can't start hands-free mode or swallow the next release.
    private func hotkeyInterrupted() {
        lastShortTap = nil
        ignoreNextRelease = false
        cancelRecording()
    }

    private func hotkeyPressed() {
        switch state {
        case .recording:
            if locked {
                ignoreNextRelease = true
                stopAndTranscribe()
            }
        case .transcribing:
            break
        case .idle:
            pressTime = Date()
            // Double-tap (a short tap followed by another press within 0.5 s) = hands-free mode.
            if Settings.shared.tapToLock, let t = lastShortTap, Date().timeIntervalSince(t) < 0.5 {
                lastShortTap = nil
                ignoreNextRelease = true
                startRecording()
                enterHandsFree()
                return
            }
            startRecording()
        }
    }

    private func hotkeyReleased() {
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard state == .recording else { return }
        if let t = pressTime, Date().timeIntervalSince(t) < 0.35 {
            // A single short tap: remember it for a possible double-tap, record nothing.
            lastShortTap = Date()
            cancelRecording()
            return
        }
        stopAndTranscribe()
    }

    private func enterHandsFree() {
        guard state == .recording else { return }
        locked = true
        overlay.show(.locked)
    }

    private func startRecording() {
        hideTimer?.invalidate()
        let focus = FocusSnapshot.capture()
        if focus.isSecureField {
            flash("Password field — dictation is off here", seconds: 2)
            return
        }
        do {
            try recorder.start()
        } catch {
            Log.info("recorder: \(error.localizedDescription)")
            flash("Microphone unavailable — check permission", seconds: 2.5)
            return
        }
        state = .recording
        locked = false
        micReady = false
        target = focus
        updateIcon()
        overlay.show(engineLoading ? .loading : .recording, message: "Loading model")
        // Bluetooth mics take up to ~0.6 s to wake; say so if audio hasn't arrived by now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, self.state == .recording, !self.micReady, !self.engineLoading else { return }
            self.overlay.show(.loading, message: "Mic starting")
        }
        // Safety cap for every mode: a missed key release can never leave the mic open indefinitely.
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            self?.capReached()
        }
    }

    /// Three minutes is almost always a mic left on by accident (e.g. a stray double-tap),
    /// so the recording is thrown away rather than typed into whatever has focus.
    private func capReached() {
        guard state == .recording else { return }
        Log.info("recording reached the 3-minute cap: discarded")
        cancelRecording()
        flash("Stopped after 3 minutes — nothing was typed", seconds: 3)
    }

    /// The start sound plays only once the mic delivers real audio, so it is the cue to start talking:
    /// words spoken while AirPods are still waking up would be lost.
    private func micBecameReady() {
        guard state == .recording, !micReady else { return }
        micReady = true
        if !engineLoading { overlay.show(locked ? .locked : .recording) }
        if Settings.shared.playSounds { startSound?.play() }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        lockTimer?.invalidate()
        locked = false
        state = .idle
        overlay.hide()
        updateIcon()
    }

    /// Debug builds only (Settings.saveRecordings): keeps the last 30 recordings as WAV files.
    private func saveRecording(_ samples: [Float]) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let dir = Settings.recordingsDir
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            do {
                try AudioRecorder.writeWAV(samples, to: dir.appendingPathComponent("rec-\(stamp).wav"))
            } catch {
                Log.info("recording save failed: \(error.localizedDescription)")
                return
            }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let old = files.filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .dropFirst(30)
            for url in old { try? fm.removeItem(at: url) }
        }
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        lockTimer?.invalidate()
        locked = false
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        if Settings.shared.playSounds { stopSound?.play() }

        guard seconds >= 0.4 else {
            state = .idle
            overlay.hide()
            updateIcon()
            return
        }

        let level = AudioRecorder.levels(samples)
        let levelNote = String(format: " (peak %.0f dB, rms %.0f dB, speech %.0f dB)", level.peak, level.rms, level.speech)

        guard level.speech >= AudioRecorder.minSpeechLevel else {
            Log.info("skipped \(String(format: "%.1f", seconds))s\(levelNote): too quiet")
            state = .idle
            updateIcon()
            flash("Too quiet — speak up a little", seconds: 1.5)
            return
        }

        state = .transcribing
        updateIcon()
        overlay.show(engineLoading ? .loading : .transcribing, message: "Loading model")

        let language = Settings.shared.language
        let removeFillers = Settings.shared.removeFillers
        let smartSpacing = Settings.shared.smartSpacing
        let usePolish = Settings.shared.polishEnabled
        let target = self.target

        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard let engine = self.engine else {
                DispatchQueue.main.async {
                    self.state = .idle
                    self.updateIcon()
                    self.flash("No speech model loaded — open Setup from the menu", seconds: 2.5)
                }
                return
            }
            let t0 = Date()
            let raw = engine.transcribe(samples, language: language)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var text = TextCleaner.clean(raw, removeFillers: removeFillers)
            var polishNote = ""
            if usePolish, let polisher = self.polisher, !text.isEmpty {
                DispatchQueue.main.async { self.overlay.show(.loading, message: "Polishing") }
                let t1 = Date()
                if let better = polisher.polish(text) {
                    polishNote = ", polished in \(Int(Date().timeIntervalSince(t1) * 1000)) ms"
                    text = better
                } else {
                    polishNote = ", polish skipped"
                }
            }
            DispatchQueue.main.async {
                self.state = .idle
                self.overlay.hide()
                self.updateIcon()
                let now = FocusSnapshot.capture()
                let summary = "transcribed \(String(format: "%.1f", seconds))s\(levelNote) with \(engine.kind.rawValue) in \(ms) ms\(polishNote)"
                // Never type into, or keep any record of, what was said with a password field focused —
                // checked before logging, so not even the troubleshooting log gets the text.
                if now.isSecureField {
                    Log.info("\(summary); focus is in a password field: dictation discarded")
                    self.flash("Password field — nothing was typed", seconds: 2.5)
                    return
                }
                if Settings.shared.saveRecordings { self.saveRecording(samples) }  // debug builds only
                // Read the switch now, not when recording stopped: if it was turned off (and the log wiped)
                // while this dictation was processing, its text must not be written back.
                let detail = Settings.shared.verboseLog ? ": \(text) [raw: \(raw)]" : " (\(text.count) chars)"
                Log.info("\(summary)\(detail)")
                if text.isEmpty {
                    self.flash("Didn't catch that", seconds: 1.2)
                    return
                }
                // Paste only into the app, window and field the user was in when they started talking.
                if let target = target, !target.stillCurrent(now) {
                    TextInserter.copyOnly(text)
                    self.flash("Copied — focus moved. Press ⌘V where you want it.", seconds: 3)
                } else {
                    TextInserter.insert(text, smartSpacing: smartSpacing)
                }
                History.shared.remember(text)
            }
        }
    }

    private func flash(_ message: String, seconds: Double) {
        overlay.show(.message, message: message)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .idle else { return }
            self.overlay.hide()
        }
    }
}

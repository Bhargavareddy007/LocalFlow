import AppKit
import Security

/// Opened from the disk image (or from Downloads without being moved), LocalFlow installs itself: it copies its
/// own bundle into Applications, checks that the copy carries the same valid signature as itself, opens the
/// copy and quits. The copy then ejects the disk image it came from.
enum Installer {
    /// Passed to the installed copy, with the disk image's volume, so it can eject it.
    static let ejectArgument = "--eject-installer-volume"

    /// Running from a read-only volume (the disk image) or from Gatekeeper's translocated copy (an app opened
    /// in Downloads without being moved). Permissions and the login item would belong to a copy that goes away.
    static func isDownloadCopy(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return readOnly || url.path.contains("/AppTranslocation/")
    }

    static func install() {
        let source = Bundle.main.bundleURL
        let volume = sourceVolume(of: source)
        Log.info("running from \(source.path); installing into Applications")
        guard let destDir = applicationsFolder() else { return fallBackToDragging("no writable Applications folder") }
        let dest = destDir.appendingPathComponent("LocalFlow.app")

        if let installed = Bundle(url: dest), isNewer(installed, than: Bundle.main), !confirmDowngrade(installed) {
            NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        quitInstalledCopies(at: dest)

        let progress = ProgressPanel(text: "Installing LocalFlow…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try copyVerified(from: source, to: dest) }
            DispatchQueue.main.async {
                progress.close()
                switch result {
                case .failure(let error):
                    fallBackToDragging(error.localizedDescription)
                case .success:
                    Log.info("installed \(dest.path)")
                    let config = NSWorkspace.OpenConfiguration()
                    config.createsNewApplicationInstance = true
                    if let volume = volume { config.arguments = [ejectArgument, volume.path] }
                    NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, error in
                        if let error = error { Log.info("couldn't open the installed copy: \(error)") }
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    /// Called by the installed copy: ejects the disk image it was installed from, once the installer has quit.
    /// Only a read-only volume that holds a LocalFlow with this app's bundle identifier is ejected.
    static func ejectInstallerVolume(arguments: [String]) {
        guard let i = arguments.firstIndex(of: ejectArgument), i + 1 < arguments.count else { return }
        let volume = URL(fileURLWithPath: arguments[i + 1])
        let components = volume.standardizedFileURL.pathComponents
        guard components.count == 3, components[1] == "Volumes",
              Bundle(url: volume.appendingPathComponent("LocalFlow.app"))?.bundleIdentifier == Bundle.main.bundleIdentifier,
              (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true else { return }
        DispatchQueue.global(qos: .utility).async {
            for attempt in 1...5 {
                Thread.sleep(forTimeInterval: Double(attempt))
                if (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil {
                    Log.info("ejected \(volume.path)")
                    return
                }
            }
            Log.info("couldn't eject \(volume.path)")
        }
    }

    // MARK: - Steps

    private static func applicationsFolder() -> URL? {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        // A standard (non-admin) account can't write to /Applications; ~/Applications works the same for one user.
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return FileManager.default.isWritableFile(atPath: user.path) ? user : nil
    }

    /// The disk image's volume, for a copy running from it directly or translocated from it.
    private static func sourceVolume(of bundle: URL) -> URL? {
        var path = bundle.path
        if path.contains("/AppTranslocation/") {
            // A translocated app runs from a read-only mount of its original folder; that mount names the folder.
            var fs = statfs()
            guard statfs(path, &fs) == 0 else { return nil }
            path = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + components[2], isDirectory: true)
    }

    private static func isNewer(_ a: Bundle, than b: Bundle) -> Bool {
        func build(_ x: Bundle) -> Int { Int(x.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
        return build(a) > build(b)
    }

    private static func confirmDowngrade(_ installed: Bundle) -> Bool {
        let theirs = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let ours = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A newer LocalFlow is already installed"
        alert.informativeText = "Applications has LocalFlow \(theirs). Replace it with this older version (\(ours))?"
        alert.addButton(withTitle: "Keep \(theirs)")
        alert.addButton(withTitle: "Replace")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// An installed LocalFlow that's running is replaced, so it's asked to quit first.
    private static func quitInstalledCopies(at dest: URL) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current && !isDownloadCopy($0.bundleURL) }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
    }

    /// Copies the bundle under a temporary name, checks the copy, then puts it in place (an older copy goes to
    /// the Trash). The copy is made without the quarantine attribute: the user has just opened this app through
    /// Gatekeeper, and the copy is opened only if its signature is valid and meets this app's own designated
    /// requirement (same identifier, same Developer ID team).
    private static func copyVerified(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".LocalFlow-installing.app")
        try? fm.removeItem(at: temp)
        do {
            try fm.copyItem(at: source, to: temp)
            removeQuarantine(temp)
            try checkSignature(of: temp)
            if fm.fileExists(atPath: dest.path) {
                do { try fm.trashItem(at: dest, resultingItemURL: nil) } catch { try fm.removeItem(at: dest) }
            }
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func removeQuarantine(_ root: URL) {
        removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = items?.nextObject() as? URL {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func checkSignature(of bundle: URL) throws {
        var running: SecCode?
        var me: SecStaticCode?
        var requirement: SecRequirement?
        var copy: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running = running,
              SecCodeCopyStaticCode(running, [], &me) == errSecSuccess, let me = me,
              SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &copy) == errSecSuccess, let copy = copy else {
            throw failure("couldn't read the signatures")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(copy, flags, requirement)
        guard status == errSecSuccess else { throw failure("the copy's signature didn't check out (\(status))") }
    }

    private static func failure(_ msg: String) -> Error {
        NSError(domain: "LocalFlow", code: 5, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func fallBackToDragging(_ reason: String) {
        Log.info("couldn't install automatically: \(reason)")
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
}

/// A small window with a spinner, shown while the app copies itself.
private final class ProgressPanel {
    private let panel: NSPanel

    init(text: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 96),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [icon, label, spinner])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            row.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor, constant: 8),
        ])
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }
}

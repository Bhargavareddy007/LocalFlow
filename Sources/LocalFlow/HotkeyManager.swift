import AppKit
import CoreGraphics

/// Watches the keyboard with a CGEvent tap and reports press / release of the
/// configured dictation key. Needs Accessibility permission.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when another key is pressed while the fn hotkey is held
    /// (e.g. fn+Delete). The recording is cancelled so shortcuts keep working.
    var onInterrupt: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isDown = false

    private static let fnKeyCode: Int64 = 63
    private static let rightOptionKeyCode: Int64 = 61
    private static let rightCommandKeyCode: Int64 = 54
    private static let rightOptionDeviceBit: UInt64 = 0x0000_0040   // NX_DEVICERALTKEYMASK
    private static let rightCommandDeviceBit: UInt64 = 0x0000_0010  // NX_DEVICERCMDKEYMASK

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.info("hotkey: event tap could not be created (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("hotkey: event tap running, key = \(Settings.shared.hotkey.rawValue)")
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hotkey = Settings.shared.hotkey

        switch hotkey {
        case .fn:
            if type == .flagsChanged && keyCode == Self.fnKeyCode {
                let down = flags.contains(.maskSecondaryFn)
                update(down: down)
                // Swallow the bare fn press so macOS does not open the emoji
                // picker / dictation / input-source switcher.
                return nil
            }
            if type == .keyDown && isDown && flags.contains(.maskSecondaryFn) {
                // fn + some other key: this is a shortcut, not dictation.
                isDown = false
                DispatchQueue.main.async { self.onInterrupt?() }
            }
        case .rightOption:
            // Device-specific bit for the RIGHT option key, so a held left option does not mask the release.
            if type == .flagsChanged && keyCode == Self.rightOptionKeyCode {
                update(down: flags.rawValue & Self.rightOptionDeviceBit != 0)
            }
        case .rightCommand:
            if type == .flagsChanged && keyCode == Self.rightCommandKeyCode {
                update(down: flags.rawValue & Self.rightCommandDeviceBit != 0)
            }
        case .controlOption:
            if type == .flagsChanged {
                let both = flags.contains(.maskControl) && flags.contains(.maskAlternate)
                update(down: both)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func update(down: Bool) {
        if down && !isDown {
            isDown = true
            DispatchQueue.main.async { self.onPress?() }
        } else if !down && isDown {
            isDown = false
            DispatchQueue.main.async { self.onRelease?() }
        }
    }
}

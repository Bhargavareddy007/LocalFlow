import AppKit
import ApplicationServices

/// Puts text into whatever app has keyboard focus: pasteboard + synthetic ⌘V,
/// then restores the previous pasteboard contents.
enum TextInserter {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func insert(_ text: String, smartSpacing: Bool) {
        var payload = text
        if smartSpacing, needsLeadingSpace() { payload = " " + payload }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(payload, forType: .string)
        let ourChange = pb.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Only restore if nobody else has written to the pasteboard meanwhile.
            if pb.changeCount == ourChange { restore(pb, saved) }
        }
    }

    /// Leaves the text on the clipboard without pasting (used when the user switched apps mid-dictation).
    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snap.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Looks at the character before the caret in the focused text field (via Accessibility).
    private static func needsLeadingSpace() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef = focusedRef else { return false }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let rangeRef = rangeRef, let value = valueRef as? String else { return false }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return false }
        let utf16 = Array(value.utf16)
        guard range.location > 0, range.location <= utf16.count else { return false }
        let prev = utf16[range.location - 1]
        guard let scalar = Unicode.Scalar(prev) else { return false }
        let ch = Character(scalar)
        if ch.isWhitespace || ch.isNewline { return false }
        if "([{\"'“‘/-—".contains(ch) { return false }
        return true
    }
}

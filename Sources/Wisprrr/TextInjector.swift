import AppKit
import ApplicationServices
@preconcurrency import UserNotifications

/// Inserts text into the focused field of whatever app is frontmost (spec §5):
/// AX insertion with retries, then a synthetic-paste fallback, and finally
/// clipboard + notification so text is never lost (spec §5.1, §17).
@MainActor
enum TextInjector {

    private static let maxAttempts = 5

    struct Result {
        let inserted: Bool
        /// true when the user has to paste manually from the clipboard
        let fellBackToClipboard: Bool
    }

    @discardableResult
    static func insert(_ text: String) async -> Result {
        guard !text.isEmpty else { return Result(inserted: true, fellBackToClipboard: false) }

        for attempt in 1...maxAttempts {
            if axInsert(text) { return Result(inserted: true, fellBackToClipboard: false) }
            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        if await pasteInsert(text) { return Result(inserted: true, fellBackToClipboard: false) }

        // Last resort: leave it on the clipboard and tell the user (spec §5.1).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify(title: "Wisprrr", body: "Failed to insert text — copied to clipboard.")
        return Result(inserted: false, fellBackToClipboard: true)
    }

    /// Replaces the current selection (inserts at cursor when selection is empty).
    private static func axInsert(_ text: String) -> Bool {
        guard let focused = ContextReader.focusedElement() else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
                focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Synthetic Cmd+V with pasteboard save/restore, for apps that reject AX writes.
    private static func pasteInsert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard postKeystroke(keyCode: 9, flags: .maskCommand) else { return false } // Cmd+V

        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(300))
        pasteboard.clearContents()
        for (type, data) in saved {
            pasteboard.setData(data, forType: type)
        }
        return true
    }

    /// Simulates the Enter key (spec §9 "press enter").
    static func pressEnter() {
        _ = postKeystroke(keyCode: 36, flags: [])
    }

    /// Best-effort undo of the last insertion by forwarding Cmd+Z to the app.
    /// Relies on the target app's own undo stack registering our edit.
    static func undoLastInsertion() {
        _ = postKeystroke(keyCode: 6, flags: .maskCommand) // Cmd+Z
    }

    @discardableResult
    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

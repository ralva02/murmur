import AppKit
import ApplicationServices
import WisprrrCore

/// Reads the active app and text near the cursor via the Accessibility API
/// (spec §6). Only invoked at the start of a dictation session; never reads
/// password fields; ignores placeholder text.
enum ContextReader {

    static func read(contextAwareness: Bool) -> ContextPayload {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier
        let category = AppCategory.categorize(bundleId: bundleId)

        var payload = ContextPayload(
            appBundleId: bundleId,
            appName: app?.localizedName,
            appCategory: category)

        guard let focused = focusedElement() else { return payload }

        if isSecureField(focused) {
            payload.isSecureField = true
            return payload   // spec §6.2: never read password fields
        }

        guard contextAwareness else { return payload }

        if let value = stringAttribute(focused, kAXValueAttribute), !value.isEmpty {
            payload.nearbyText = nearbySlice(of: value, element: focused)
            payload.properNouns = extractProperNouns(
                from: value, includeIdentifiers: category == .code || category == .terminal)
        }
        return payload
    }

    /// Reads the currently selected text in the focused element (Command Mode §8.1).
    static func selectedText() -> String? {
        guard let focused = focusedElement(), !isSecureField(focused) else { return nil }
        return stringAttribute(focused, kAXSelectedTextAttribute)
    }

    // MARK: - AX plumbing

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let element = value else { return nil }
        return (element as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if let subrole = subroleValue as? String, subrole == kAXSecureTextFieldSubrole as String {
            return true
        }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        if let role = roleValue as? String, role.lowercased().contains("secure") {
            return true
        }
        return false
    }

    /// Up to ~1500 chars around the insertion point.
    private static func nearbySlice(of value: String, element: AXUIElement) -> String {
        let cap = 1500
        guard value.count > cap else { return value }

        var location = value.count // default: end of document
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue((rv as! AXValue), .cfRange, &range) {
                location = min(range.location, value.count)
            }
        }
        let start = max(0, location - cap / 2)
        let end = min(value.count, start + cap)
        let s = value.index(value.startIndex, offsetBy: start)
        let e = value.index(value.startIndex, offsetBy: end)
        return String(value[s..<e])
    }

    /// Capitalized runs ("Anaïs Kowalczyk") plus, in code apps, camelCase and
    /// snake_case identifiers. Used to bias ASR and cleanup spelling.
    static func extractProperNouns(from text: String, includeIdentifiers: Bool) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        let properNounPattern = /\b\p{Lu}[\p{Ll}\p{M}'’-]+(?:\s+\p{Lu}[\p{Ll}\p{M}'’-]+)*\b/
        for match in text.matches(of: properNounPattern) {
            let candidate = String(match.output)
            // Single common sentence-starters are noise; keep multi-word or distinctive tokens.
            guard candidate.contains(" ") || candidate.count >= 4 else { continue }
            if seen.insert(candidate.lowercased()).inserted { found.append(candidate) }
        }

        if includeIdentifiers {
            let identifierPattern = /\b(?:[a-z]+(?:[A-Z][a-z0-9]*)+|[a-z0-9]+(?:_[a-z0-9]+)+)\b/
            for match in text.matches(of: identifierPattern) {
                let candidate = String(match.output)
                if seen.insert(candidate.lowercased()).inserted { found.append(candidate) }
            }
        }
        return Array(found.prefix(40))
    }
}

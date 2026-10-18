import AppKit
import ApplicationServices

/// Where the user was typing when they started talking: the app and its focused text element.
struct FocusSnapshot {
    let app: NSRunningApplication?
    let element: AXUIElement?

    var appName: String? { app?.localizedName }
}

/// Reads and restores keyboard focus through the Accessibility API.
@MainActor
enum FocusTracker {
    static func capture() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        if let pid = app?.processIdentifier {
            // Electron apps only expose their text fields once asked to; harmless elsewhere.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return FocusSnapshot(app: app, element: focusedElement())
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Brings back the app and text field from the snapshot, if focus moved while recording.
    /// Returns true when anything had to be changed.
    @discardableResult
    static func restore(_ snapshot: FocusSnapshot) -> Bool {
        var changed = false
        if let app = snapshot.app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            changed = true
        }
        if let element = snapshot.element, !isSame(focusedElement(), element) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            changed = true
        }
        return changed
    }

    static func isSame(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return false }
        return CFEqual(a, b)
    }

    /// Password fields: never paste into them.
    static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// The element's full text, when the app exposes it.
    static func value(_ element: AXUIElement) -> String? {
        string(element, kAXValueAttribute)
    }

    /// True when the element's text can be changed, so replacing the selection will work.
    static func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }
        let role = string(element, kAXRoleAttribute)
        return role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String)
    }

    /// Where the selected text is on screen, in AppKit coordinates, when the app reports it.
    static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return appKitRect(fromAccessibility: rect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Accessibility measures from the top-left of the main screen; AppKit from its bottom-left.
    nonisolated static func appKitRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Selects a range of the element's text (UTF-16 offsets, as NSString counts them).
    @discardableResult
    static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Role names for things that are clearly not a place to type: lists, tables, the desktop.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXWindow", "AXButton",
        "AXImage", "AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXGroup", "AXRow", "AXCell",
    ]

    /// True when the user is clearly not in a text field, so a dictation should go to the
    /// scratchpad instead of being pasted. Unknown cases count as a text field: the paste is
    /// attempted, and only a paste that no app reads falls back to the scratchpad.
    static func clearlyNotTyping(_ snapshot: FocusSnapshot) -> Bool {
        guard let element = snapshot.element else {
            return snapshot.app?.bundleIdentifier == "com.apple.finder"
        }
        if isEditable(element) { return false }
        guard let role = string(element, kAXRoleAttribute) else { return false }
        return nonTextRoles.contains(role)
    }

    /// The highlighted text in the element, when the app exposes it.
    static func selectedText(_ element: AXUIElement) -> String? {
        string(element, kAXSelectedTextAttribute)
    }

    /// Up to `limit` characters before the cursor, or nil when the app does not expose them.
    static func textBeforeCursor(_ element: AXUIElement?, limit: Int = 80) -> String? {
        guard let element, let full = value(element) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        let text = full as NSString
        let end = min(max(range.location, 0), text.length)
        let start = max(0, end - limit)
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

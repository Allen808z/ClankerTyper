import AppKit
import ApplicationServices

/// Reads the text the user has highlighted in the app in front.
@MainActor
enum SelectionReader {
    /// Tries Accessibility first; apps that do not expose their selection that way (many web
    /// views) get a Cmd+C, and the copied text is read from the clipboard.
    static func read(from focus: FocusSnapshot) async -> String? {
        if let element = focus.element, let selected = FocusTracker.selectedText(element), !selected.isEmpty {
            return selected
        }

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let previous = pasteboard.string(forType: .string)
        KeyStroke.post(keyCode: 8, flags: .maskCommand)  // Cmd+C ("C" on the US layout)

        let deadline = Date().addingTimeInterval(0.4)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        guard pasteboard.changeCount != before, let copied = pasteboard.string(forType: .string) else {
            return nil
        }
        // Leave the clipboard as it was; the rewritten text replaces it later only on success.
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
        return copied
    }
}

/// Posts keystrokes to the app in front, and waits for the user's own modifier keys to be up.
@MainActor
enum KeyStroke {
    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Shortcuts like Control+Option+G are pressed while Control and Option are held. A Cmd+C or
    /// Cmd+V sent at that moment would arrive as Control+Option+Cmd+C, so wait until they are up.
    static func waitForModifiersReleased(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl), !flags.contains(.maskAlternate), !flags.contains(.maskShift) {
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

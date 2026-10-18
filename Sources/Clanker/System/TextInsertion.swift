import AppKit
import ApplicationServices

/// Hands the clipboard text to whichever app asks for it, and records that someone asked.
/// An app reads the clipboard when it handles Cmd+V, so a request means the paste landed.
private final class PasteWitness: NSObject, NSPasteboardItemDataProvider {
    let text: String
    private(set) var wasRequested = false

    init(text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        wasRequested = true
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// Puts each transcription on the clipboard, where it stays, and pastes it where the user was
/// typing. It returns focus to that app and field first, never types into password fields, and
/// reports whether the paste actually landed.
@MainActor
enum TextInsertion {
    enum Outcome: Equatable {
        /// The focused app read the clipboard after Cmd+V.
        case pasted
        /// Cmd+V was sent but no app read the clipboard: the text is on the clipboard only.
        case notPasted
        /// The cursor was in a password field, so nothing was typed.
        case secureField
        /// macOS does not let Clanker send keystrokes yet.
        case notAllowed
    }

    /// How long to wait for the focused app to read the clipboard after Cmd+V.
    static let pasteConfirmWindow: TimeInterval = 1.0

    static func deliver(_ text: String, to focus: FocusSnapshot) async -> Outcome {
        guard !FocusTracker.isSecure(focus.element) else {
            putOnClipboard(text)
            return .secureField
        }
        guard CGPreflightPostEventAccess() else {
            putOnClipboard(text)
            _ = CGRequestPostEventAccess()
            return .notAllowed
        }

        if FocusTracker.restore(focus) {
            // Give the app a moment to come back to the front before the keystroke.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let pasteboard = NSPasteboard.general
        let witness = PasteWitness(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(witness, forTypes: [.string])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        postCommandV()

        let deadline = Date().addingTimeInterval(pasteConfirmWindow)
        while !witness.wasRequested, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let landed = witness.wasRequested

        // Swap the promise for the plain text so it stays on the clipboard after this.
        putOnClipboard(text)
        AppLog.write("paste \(landed ? "landed" : "not read by any app") in \(focus.appName ?? "unknown app")")
        return landed ? .pasted : .notPasted
    }

    static func putOnClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Cmd+V. Virtual key 9 is "V" on the US keyboard layout; other layouts may differ.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

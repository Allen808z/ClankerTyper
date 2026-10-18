import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted with `true` while a shortcut is being recorded, so the app's own shortcuts are
    /// paused and the pressed keys reach the recorder instead of triggering an action.
    static let shortcutRecording = Notification.Name("ClankerTyperShortcutRecording")
}

/// One action's shortcut in Settings: shows the combo, records a new one, or resets it.
struct ShortcutRecorderRow: View {
    let shortcut: HotKey.Shortcut
    @State private var combo: KeyCombo
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    init(shortcut: HotKey.Shortcut) {
        self.shortcut = shortcut
        _combo = State(initialValue: AppSettings.combo(for: shortcut))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(shortcut.title)
                Spacer()
                Button(recording ? "Press keys… (Esc cancels)" : combo.display) {
                    recording ? stopRecording() : startRecording()
                }
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(minWidth: 90)
                if combo != shortcut.defaultCombo, !recording {
                    Button("Reset") { save(shortcut.defaultCombo) }
                        .buttonStyle(.borderless)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        problem = nil
        recording = true
        NotificationCenter.default.post(name: .shortcutRecording, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape
                stopRecording()
                return nil
            }
            guard let candidate = KeyCombo.from(keyCode: event.keyCode, flags: event.modifierFlags,
                                                characters: event.charactersIgnoringModifiers) else {
                problem = "Use at least one of ⌃ Control, ⌥ Option or ⌘ Command."
                return nil
            }
            if let other = AppSettings.conflict(for: candidate, excluding: shortcut) {
                problem = "\(candidate.display) is already used for \(other.title)."
                return nil
            }
            // Try it: another app may already own this combo.
            if HotKey(id: 99, keyCode: candidate.keyCode, modifiers: candidate.carbonModifiers, action: {}) == nil {
                problem = "\(candidate.display) is taken by another app. Try a different one."
                return nil
            }
            save(candidate)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            NotificationCenter.default.post(name: .shortcutRecording, object: false)
        }
    }

    private func save(_ new: KeyCombo) {
        AppSettings.setCombo(new, for: shortcut)
        combo = AppSettings.combo(for: shortcut)
        problem = nil
    }
}

import AppKit
import Speech
import SwiftUI

/// Appends permission changes to ~/Library/Logs/ClankerTyper/permissions.log so a stuck state can be
/// diagnosed from what this process actually saw.
enum PermissionLog {
    static func record(_ states: [PermissionKind: Bool]) {
        let line = PermissionKind.allCases.map { "\($0.title)=\(states[$0] ?? false)" }.joined(separator: " ")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/ClankerTyper", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("permissions.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

/// Re-reads permission state whenever the app becomes active (after a trip to System Settings).
@MainActor
final class PermissionState: ObservableObject {
    @Published private(set) var granted: [PermissionKind: Bool] = [:]
    private var timer: Timer?

    /// Granting a permission happens in System Settings, which does not activate ClankerTyper, so
    /// polling is the only reliable way to notice the change while our windows are open.
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        var next: [PermissionKind: Bool] = [:]
        for kind in PermissionKind.allCases {
            next[kind] = Permissions.isGranted(kind)
        }
        if next != granted {
            PermissionLog.record(next)
        }
        granted = next
    }

    var allGranted: Bool {
        PermissionKind.required(transcribeOnly: AppSettings.transcribeOnly).allSatisfy { granted[$0] == true }
    }
}

/// One permission row, shared by onboarding and Settings.
struct PermissionRow: View {
    let kind: PermissionKind
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : Brand.muted)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Text(kind.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Allow", action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @ObservedObject var permissions: PermissionState
    @AppStorage(AppSettings.Key.transcribeOnly) private var transcribeOnly = true
    @AppStorage(AppSettings.Key.insertAtCursor) private var insertAtCursor = true
    @AppStorage(AppSettings.Key.dictationLanguages) private var languagesRaw = ""
    @AppStorage(AppSettings.Key.muteAudio) private var muteAudio = true
    @AppStorage(AppSettings.Key.removeFillers) private var removeFillers = true
    @AppStorage(AppSettings.Key.smartSpacing) private var smartSpacing = true
    @AppStorage(AppSettings.Key.learnCorrections) private var learnCorrections = true
    @AppStorage(AppSettings.Key.aiCleanup) private var aiCleanup = true
    @AppStorage(AppSettings.Key.writingEngine) private var writingEngine = AppSettings.writingEngine.rawValue
    @AppStorage(AppSettings.Key.ollamaModel) private var ollamaModel = "qwen2.5vl:7b"
    @AppStorage(AppSettings.Key.ollamaHost) private var ollamaHost = OllamaClient.defaultHost.absoluteString
    @AppStorage(AppSettings.Key.speakReplies) private var speakReplies = true
    @AppStorage(AppSettings.Key.showCompanion) private var showCompanion = true
    @AppStorage(AppSettings.Key.showInDock) private var showInDock = true
    @AppStorage(AppSettings.Key.selectionToolbar) private var selectionToolbar = true
    @AppStorage(AppSettings.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(AppSettings.Key.talkKey) private var talkKey = TalkKey.controlOption.rawValue
    @AppStorage(AppSettings.Key.playSounds) private var playSounds = true
    @AppStorage(AppSettings.Key.meetingOffers) private var meetingOffers = true
    @AppStorage(AppSettings.Key.keepMeetingAudio) private var keepMeetingAudio = true
    @State private var loginState = LoginItem.state

    var body: some View {
        Form {
            Section("Shortcuts") {
                Picker("Hold to talk", selection: $talkKey) {
                    ForEach(TalkKey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                Text("Double-tap it for hands-free; hold it with ⇧ Shift for command mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = TalkKey(rawValue: talkKey)?.setupNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(HotKey.Shortcut.allCases, id: \.self) { shortcut in
                    ShortcutRecorderRow(shortcut: shortcut)
                }
                LabeledContent("While talking", value: "“new line”, “new paragraph”, “scratch that”")
                Toggle("Play a sound when recording starts and stops", isOn: $playSounds)
            }

            Section("Languages") {
                ForEach(AppSettings.languageOptions, id: \.id) { option in
                    Toggle(isOn: languageBinding(option.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                            Text(privacyNote(for: option.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("With both on, each phrase is recognized in English and French and the more confident result is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictation") {
                Toggle("Type what I say into the app I'm using", isOn: $insertAtCursor)
                Toggle("Mute all sound while dictating", isOn: $muteAudio)
                Toggle("Remove filler words (um, uh, euh)", isOn: $removeFillers)
                Toggle("Fit spacing and capitals to the text around the cursor", isOn: $smartSpacing)
                Toggle("Learn from my corrections", isOn: $learnCorrections)
                Text("When you fix a pasted word that isn't everyday vocabulary, like a name or a brand, ClankerTyper remembers it. Ordinary words and accidental edits are not learned. Learned words appear in Dictionary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Correct grammar so each phrase makes sense", isOn: $aiCleanup)
                Text("Runs on this Mac before pasting. If the model is unavailable, slow, or changes your meaning, your words are pasted as heard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Everything you dictate also stays on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Writing tools") {
                Toggle("Show Fix grammar and Improve writing when I highlight text", isOn: $selectionToolbar)
                Text("Highlight text you can edit, however you select it, and the buttons appear just above it. They appear in apps that report their selection to macOS; the shortcuts work everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Highlight text in any app, then press \(AppSettings.combo(for: .fixGrammar).display) to fix its grammar or \(AppSettings.combo(for: .improveWriting).display) to improve the writing. The selection is replaced; ⌘Z in that app undoes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $writingEngine) {
                    ForEach(AppSettings.WritingEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                if writingEngine == AppSettings.WritingEngine.ollama.rawValue {
                    TextField("Ollama model", text: $ollamaModel)
                }
                Text(engineNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meetings") {
                Toggle("Offer to record when a call starts", isOn: $meetingOffers)
                Text("When Zoom, Teams, FaceTime, Webex, Slack, Discord or a Meet page uses the microphone, a small card offers to record. Nothing records without your click. Let everyone know you're recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep recordings after the notes are made", isOn: $keepMeetingAudio)
                Text("Records your microphone and the Mac's sound (the other people), so it needs Screen Recording. Transcripts and summaries are made on this Mac; each language's transcription model is downloaded from Apple once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Speech is recognized on this Mac only. A language that isn't installed on-device is skipped, never sent away.", systemImage: "waveform")
                Label("Grammar correction and writing tools use a model on this Mac: Apple's built-in model or Ollama at localhost.", systemImage: "cpu")
                Label("History, your dictionary and snippets are stored only in ~/Library/Application Support/ClankerTyper.", systemImage: "internaldrive")
                Label("No accounts, no analytics, no cloud services.", systemImage: "lock")
            }

            Section("Mode") {
                Toggle("Transcribe only: never look at my screen", isOn: $transcribeOnly)
                Text(transcribeOnly
                     ? "ClankerTyper only writes down what you say. Nothing is sent to a model unless grammar cleanup is on, and no screenshots are taken."
                     : "Ask mode: what you say is sent with screenshots to the model below, and the answer is shown in a card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !transcribeOnly {
            Section("Ask mode model") {
                TextField("Ollama vision model", text: $ollamaModel)
                TextField("Ollama address", text: $ollamaHost)
                Text("Ask mode sends your question and screenshots to a vision model in Ollama on this Mac. Only addresses on this Mac are accepted. Pull the model first with `ollama pull \(ollamaModel)`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            Section("App") {
                Toggle("Open ClankerTyper when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LoginItem.apply(enabled)
                        loginState = LoginItem.state
                    }
                if loginState == .needsApproval {
                    Text("Allow it in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if loginState == .notInstalled {
                    Text("Only the copy in Applications can open at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show ClankerTyper in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, visible in
                        NSApp.setActivationPolicy(visible ? .regular : .accessory)
                        // Switching policy can drop this window behind others; keep it in front.
                        NSApp.activate(ignoringOtherApps: true)
                    }
                Text("It is always in the menu bar at the top right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Companion") {
                Toggle("Show the blue companion", isOn: $showCompanion)
                Toggle("Speak replies aloud (ask mode)", isOn: $speakReplies)
            }

            Section("Permissions") {
                ForEach(PermissionKind.required(transcribeOnly: transcribeOnly)) { kind in
                    PermissionRow(kind: kind, granted: permissions.granted[kind] ?? false) {
                        Permissions.request(kind)
                    }
                }
                Button("Refresh status") { permissions.refresh() }
            }
        }
        .formStyle(.grouped)
    }

    /// Reads and writes one language in the stored list, keeping at least one selected.
    private func languageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { _ = languagesRaw; return AppSettings.dictationLanguages.contains(id) },
            set: { enabled in
                AppSettings.setLanguage(id, enabled: enabled)
                languagesRaw = AppSettings.dictationLanguages.joined(separator: ",")
            }
        )
    }

    /// Says whether speech in a language stays on this Mac.
    private func privacyNote(for id: String) -> String {
        guard SFSpeechRecognizer(locale: AppSettings.locale(for: id)) != nil else {
            return "This Mac can't recognize this language."
        }
        if Dictation.isOnDevice(id) {
            return "Recognized on this Mac. Audio is not sent anywhere."
        }
        return "Not installed on this Mac yet, so it is skipped. Add it under System Settings → Keyboard → Dictation."
    }

    private var engineNote: String {
        if writingEngine == AppSettings.WritingEngine.apple.rawValue {
            return AppleTextModel.isAvailable
                ? "Built into macOS. Nothing to install, and nothing leaves your Mac."
                : "Not available on this Mac. Turn on Apple Intelligence in System Settings, or choose Ollama."
        }
        return "Uses Ollama on this Mac (localhost only). Install Ollama and run `ollama pull \(ollamaModel)` first."
    }
}

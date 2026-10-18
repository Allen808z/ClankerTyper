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
    @State private var keyDraft = ""
    @State private var keyStatus = ""
    @AppStorage(AppSettings.Key.transcribeOnly) private var transcribeOnly = true
    @AppStorage(AppSettings.Key.insertAtCursor) private var insertAtCursor = true
    @AppStorage(AppSettings.Key.dictationLanguages) private var languagesRaw = ""
    @AppStorage(AppSettings.Key.muteAudio) private var muteAudio = true
    @AppStorage(AppSettings.Key.removeFillers) private var removeFillers = true
    @AppStorage(AppSettings.Key.smartSpacing) private var smartSpacing = true
    @AppStorage(AppSettings.Key.learnCorrections) private var learnCorrections = true
    @AppStorage(AppSettings.Key.aiCleanup) private var aiCleanup = false
    @AppStorage(AppSettings.Key.provider) private var provider = AppSettings.Provider.anthropic.rawValue
    @AppStorage(AppSettings.Key.ollamaModel) private var ollamaModel = "qwen2.5vl:7b"
    @AppStorage(AppSettings.Key.ollamaHost) private var ollamaHost = OllamaClient.defaultHost.absoluteString
    @AppStorage(AppSettings.Key.model) private var model = AppSettings.models[0].id
    @AppStorage(AppSettings.Key.speakReplies) private var speakReplies = true
    @AppStorage(AppSettings.Key.showCompanion) private var showCompanion = true
    @AppStorage(AppSettings.Key.showInDock) private var showInDock = true

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Dictate", value: "Hold ⌃ Control + ⌥ Option")
                LabeledContent("Hands-free", value: "Double-tap ⌃⌥, tap again to stop")
                LabeledContent("Paste last transcript", value: "⌃⌥V")
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
                Toggle("Clean up grammar with my local model", isOn: $aiCleanup)
                if aiCleanup {
                    TextField("Ollama model", text: $ollamaModel)
                    Text("Runs on this Mac through Ollama. Adds a moment before pasting. If the model is slow or changes your meaning, the original is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Everything you dictate also stays on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("Model") {
                Picker("Answers from", selection: $provider) {
                    ForEach(AppSettings.Provider.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                if AppSettings.Provider(rawValue: provider) == .ollama {
                    TextField("Model name", text: $ollamaModel)
                    TextField("Ollama address", text: $ollamaHost)
                    Text("Runs on this Mac through Ollama. Nothing is sent to the cloud. Pull the model first with `ollama pull \(ollamaModel)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("API key (sk-ant-…)", text: $keyDraft)
                    HStack {
                        Button("Save key") {
                            let ok = APIKeyStore.save(keyDraft)
                            keyDraft = ""
                            keyStatus = ok ? "Saved in your Keychain." : "Could not save the key."
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") {
                            APIKeyStore.delete()
                            keyStatus = "Key removed."
                        }
                        .disabled(!APIKeyStore.hasStoredKey)
                        Spacer()
                        Text(keyStatus.isEmpty ? keyStatusDefault : keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Claude model", selection: $model) {
                        ForEach(AppSettings.models, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }
            }
            }

            Section("App") {
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
        guard let recognizer = SFSpeechRecognizer(locale: AppSettings.locale(for: id)) else {
            return "This Mac can't recognize this language."
        }
        if recognizer.supportsOnDeviceRecognition {
            return "Recognized on this Mac. Audio is not sent anywhere."
        }
        return "Not on-device yet: audio goes to Apple's speech service. Add it under System Settings → Keyboard → Dictation for the on-device model."
    }

    private var keyStatusDefault: String {
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return "Using ANTHROPIC_API_KEY from the environment."
        }
        return APIKeyStore.hasStoredKey ? "A key is saved." : "No key yet."
    }
}

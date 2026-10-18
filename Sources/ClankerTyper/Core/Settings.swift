import AppKit
import Foundation

/// Preferences, kept in UserDefaults on this Mac.
enum AppSettings {
    static let defaults = UserDefaults.standard

    enum Key {
        static let transcribeOnly = "transcribeOnly"
        static let dictationLanguages = "dictationLanguages"
        static let muteAudio = "muteAudio"
        static let removeFillers = "removeFillers"
        static let smartSpacing = "smartSpacing"
        static let learnCorrections = "learnCorrections"
        static let aiCleanup = "aiCleanup"
        static let insertAtCursor = "insertAtCursor"
        static let writingEngine = "writingEngine"
        static let ollamaModel = "ollamaModel"
        static let ollamaHost = "ollamaHost"
        static let speakReplies = "speakReplies"
        static let showCompanion = "showCompanion"
        static let showInDock = "showInDock"
        static let selectionToolbar = "selectionToolbar"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingDone = "onboardingDone"
    }

    /// The on-device model that corrects grammar and powers the writing tools. Both run on this
    /// Mac; Apple's is built into macOS 26 and needs nothing installed.
    enum WritingEngine: String, CaseIterable, Identifiable {
        case apple
        case ollama

        var id: Self { self }
        var label: String {
            switch self {
            case .apple: return "Apple's built-in model"
            case .ollama: return "Ollama"
            }
        }
    }

    /// When on, speech is written down and never sent to a model, and the screen is never captured.
    static var transcribeOnly: Bool {
        get { defaults.object(forKey: Key.transcribeOnly) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.transcribeOnly) }
    }

    /// Speech recognition languages offered. With more than one selected, each phrase is
    /// recognized in all of them and the most confident result is kept.
    static let languageOptions: [(id: String, label: String)] = [
        ("en-US", "English"),
        ("fr-FR", "Français"),
    ]

    /// Stored as a comma-separated list. Defaults to the Mac's language when it is offered.
    static var dictationLanguages: [String] {
        get {
            let stored = (defaults.string(forKey: Key.dictationLanguages) ?? "")
                .split(separator: ",").map(String.init)
                .filter { id in languageOptions.contains { $0.id == id } }
            if !stored.isEmpty { return stored }
            let mac = Locale.current.language.languageCode?.identifier ?? "en"
            return [languageOptions.first { $0.id.hasPrefix(mac) }?.id ?? "en-US"]
        }
        set {
            // Never allow an empty list: there must be a language to recognize.
            let valid = newValue.filter { id in languageOptions.contains { $0.id == id } }
            defaults.set((valid.isEmpty ? ["en-US"] : valid).joined(separator: ","), forKey: Key.dictationLanguages)
        }
    }

    /// Turns one language on or off, keeping at least one selected.
    static func setLanguage(_ id: String, enabled: Bool) {
        var current = dictationLanguages
        if enabled, !current.contains(id) {
            current.append(id)
        } else if !enabled, current.count > 1 {
            current.removeAll { $0 == id }
        }
        dictationLanguages = current
    }

    static func locale(for id: String) -> Locale {
        Locale(identifier: id)
    }

    static var muteAudio: Bool {
        get { defaults.object(forKey: Key.muteAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.muteAudio) }
    }

    static var removeFillers: Bool {
        get { defaults.object(forKey: Key.removeFillers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.removeFillers) }
    }

    static var smartSpacing: Bool {
        get { defaults.object(forKey: Key.smartSpacing) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.smartSpacing) }
    }

    static var learnCorrections: Bool {
        get { defaults.object(forKey: Key.learnCorrections) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.learnCorrections) }
    }

    /// Grammar correction of dictation with the on-device model, so each phrase reads as a
    /// sensible sentence. The original is kept whenever the model is unavailable or goes off track.
    static var aiCleanup: Bool {
        get { defaults.object(forKey: Key.aiCleanup) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.aiCleanup) }
    }

    /// In transcribe-only mode, paste each transcription into the focused app.
    static var insertAtCursor: Bool {
        get { defaults.object(forKey: Key.insertAtCursor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.insertAtCursor) }
    }

    /// Apple's model when this Mac has it, otherwise Ollama.
    static var writingEngine: WritingEngine {
        get {
            if let stored = defaults.string(forKey: Key.writingEngine), let engine = WritingEngine(rawValue: stored) {
                return engine
            }
            return AppleTextModel.isAvailable ? .apple : .ollama
        }
        set { defaults.set(newValue.rawValue, forKey: Key.writingEngine) }
    }

    static var ollamaModel: String {
        get {
            let stored = defaults.string(forKey: Key.ollamaModel)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? "qwen2.5vl:7b" : stored
        }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }

    static var ollamaHost: String {
        get { defaults.string(forKey: Key.ollamaHost) ?? OllamaClient.defaultHost.absoluteString }
        set { defaults.set(newValue, forKey: Key.ollamaHost) }
    }

    static var speakReplies: Bool {
        get { defaults.object(forKey: Key.speakReplies) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.speakReplies) }
    }

    static var showCompanion: Bool {
        get { defaults.object(forKey: Key.showCompanion) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showCompanion) }
    }

    /// Show the app icon in the Dock while ClankerTyper runs. Off keeps it in the menu bar only.
    static var showInDock: Bool {
        get { defaults.object(forKey: Key.showInDock) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// Offer Fix grammar / Improve writing next to the pointer when text is selected.
    static var selectionToolbar: Bool {
        get { defaults.object(forKey: Key.selectionToolbar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.selectionToolbar) }
    }

    /// Open ClankerTyper automatically when the user logs in.
    static var launchAtLogin: Bool {
        get { defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    static var activationPolicy: NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    static var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }
}

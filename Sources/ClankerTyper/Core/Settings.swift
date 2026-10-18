import Foundation
import Security

/// Non-secret preferences, kept in UserDefaults.
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
        static let provider = "provider"
        static let ollamaModel = "ollamaModel"
        static let ollamaHost = "ollamaHost"
        static let model = "model"
        static let speakReplies = "speakReplies"
        static let showCompanion = "showCompanion"
        static let onboardingDone = "onboardingDone"
    }

    /// Models offered in Settings. IDs follow the Claude 5 family naming in this environment.
    static let models: [(id: String, label: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (balanced)"),
        ("claude-opus-5-5", "Claude Opus 5.5 (deepest)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest)"),
    ]

    /// Which backend answers: the Anthropic API (needs a key) or a local Ollama server.
    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case ollama

        var id: Self { self }
        var label: String {
            switch self {
            case .anthropic: return "Anthropic (cloud, API key)"
            case .ollama: return "Local model (Ollama)"
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

    /// Optional grammar cleanup through the local Ollama model. Off by default: it is slower and
    /// a model can change wording.
    static var aiCleanup: Bool {
        get { defaults.object(forKey: Key.aiCleanup) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.aiCleanup) }
    }

    /// In transcribe-only mode, paste each transcription into the focused app.
    static var insertAtCursor: Bool {
        get { defaults.object(forKey: Key.insertAtCursor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.insertAtCursor) }
    }

    static var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "qwen2.5vl:7b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }

    static var ollamaHost: String {
        get { defaults.string(forKey: Key.ollamaHost) ?? OllamaClient.defaultHost.absoluteString }
        set { defaults.set(newValue, forKey: Key.ollamaHost) }
    }

    static var model: String {
        get { defaults.string(forKey: Key.model) ?? models[0].id }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    static var speakReplies: Bool {
        get { defaults.object(forKey: Key.speakReplies) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.speakReplies) }
    }

    static var showCompanion: Bool {
        get { defaults.object(forKey: Key.showCompanion) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showCompanion) }
    }

    static var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }
}

/// The API key lives in the login Keychain, never in UserDefaults.
/// `ANTHROPIC_API_KEY` in the environment is accepted as a development fallback.
enum APIKeyStore {
    private static let service = "dev.local.clanker"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return keychainRead()
    }

    static var hasStoredKey: Bool { keychainRead() != nil }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        let data = Data(trimmed.utf8)
        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainRead() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

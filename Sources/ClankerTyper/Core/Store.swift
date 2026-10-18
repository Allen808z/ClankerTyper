import Foundation

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    /// What the recognizer heard, before cleanup.
    var rawText: String
    /// What was pasted or copied.
    var text: String
    var appName: String?
    var duration: TimeInterval
    var words: Int
    var outcome: String
}

/// A word the recognizer should expect: names, brands, jargon.
struct VocabularyWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// True when ClankerTyper learned it from a correction, false when the user added it.
    var learned: Bool
    var added: Date
}

/// Replaces a misheard word or phrase with the right one.
struct Replacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
    var learned: Bool
    var added: Date
}

/// A spoken trigger phrase that expands into stored text.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

/// A saved instruction for highlighted text or command mode, such as "Turn into bullet points".
struct CustomAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var instruction: String
}

/// Everything ClankerTyper keeps between launches, in one JSON file under Application Support.
@MainActor
final class ClankerTyperStore: ObservableObject {
    struct Contents: Codable {
        var history: [HistoryItem] = []
        var vocabulary: [VocabularyWord] = []
        var replacements: [Replacement] = []
        var snippets: [Snippet] = []
        var customActions: [CustomAction] = []
        var scratchpad: String = ""

        init(history: [HistoryItem] = [], vocabulary: [VocabularyWord] = [], replacements: [Replacement] = [],
             snippets: [Snippet] = [], customActions: [CustomAction] = [], scratchpad: String = "") {
            self.history = history
            self.vocabulary = vocabulary
            self.replacements = replacements
            self.snippets = snippets
            self.customActions = customActions
            self.scratchpad = scratchpad
        }

        /// Every field is optional on disk, so a file written by an older version, without the
        /// fields added since, still loads instead of being set aside as unreadable.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            history = try container.decodeIfPresent([HistoryItem].self, forKey: .history) ?? []
            vocabulary = try container.decodeIfPresent([VocabularyWord].self, forKey: .vocabulary) ?? []
            replacements = try container.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
            snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
            customActions = try container.decodeIfPresent([CustomAction].self, forKey: .customActions) ?? []
            scratchpad = try container.decodeIfPresent(String.self, forKey: .scratchpad) ?? ""
        }
    }

    static let historyLimit = 1000

    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var vocabulary: [VocabularyWord] = []
    @Published private(set) var replacements: [Replacement] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var customActions: [CustomAction] = []
    @Published var scratchpad: String = "" {
        didSet { if scratchpad != oldValue { save() } }
    }

    private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("store.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file) {
            if let contents = try? JSONDecoder.store.decode(Contents.self, from: data) {
                history = contents.history
                vocabulary = contents.vocabulary
                replacements = contents.replacements
                snippets = contents.snippets
                customActions = contents.customActions
                scratchpad = contents.scratchpad
            } else {
                // Keep an unreadable file instead of overwriting the user's data with an empty store.
                let backup = directory.appendingPathComponent("store-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: backup)
                AppLog.write("store.json could not be read; moved it to \(backup.lastPathComponent)")
            }
        }
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = support.appendingPathComponent("ClankerTyper", isDirectory: true)
        // The app was called Clanker before; bring its saved data along once.
        let previous = support.appendingPathComponent("Clanker", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: current.path), manager.fileExists(atPath: previous.path) {
            do {
                try manager.moveItem(at: previous, to: current)
                AppLog.write("moved saved data from Application Support/Clanker to ClankerTyper")
            } catch {
                AppLog.write("could not move saved data from Application Support/Clanker: \(error.localizedDescription)")
                return previous
            }
        }
        return current
    }

    // MARK: - History

    func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        save()
    }

    func deleteHistory(_ id: HistoryItem.ID) {
        history.removeAll { $0.id == id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    var lastTranscript: String? { history.first?.text }

    // MARK: - Stats

    var totalWords: Int { history.reduce(0) { $0 + $1.words } }

    /// Speaking speed over all dictations that lasted long enough to measure.
    var averageWordsPerMinute: Int {
        let timed = history.filter { $0.duration >= 1 }
        let minutes = timed.reduce(0) { $0 + $1.duration } / 60
        guard minutes > 0 else { return 0 }
        return Int((Double(timed.reduce(0) { $0 + $1.words }) / minutes).rounded())
    }

    var wordsThisWeek: Int {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return history.filter { $0.date >= start }.reduce(0) { $0 + $1.words }
    }

    var learnedCount: Int { replacements.filter(\.learned).count }

    // MARK: - Dictionary

    func addWord(_ word: String, learned: Bool = false) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !vocabulary.contains(where: { $0.word.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        vocabulary.insert(VocabularyWord(word: trimmed, learned: learned, added: Date()), at: 0)
        save()
    }

    func deleteWord(_ id: VocabularyWord.ID) {
        vocabulary.removeAll { $0.id == id }
        save()
    }

    func addReplacement(from: String, to: String, learned: Bool = false) {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        // A newer correction of the same word replaces the older one.
        replacements.removeAll { $0.from.caseInsensitiveCompare(from) == .orderedSame }
        replacements.insert(Replacement(from: from, to: to, learned: learned, added: Date()), at: 0)
        save()
    }

    func deleteReplacement(_ id: Replacement.ID) {
        replacements.removeAll { $0.id == id }
        save()
    }

    /// Remembers a correction: the misheard word is replaced from now on, and the right word
    /// is given to the recognizer as a hint. Returns false when it was already known.
    @discardableResult
    func learn(_ correction: TextProcessing.Correction) -> Bool {
        let known = replacements.contains {
            $0.from.caseInsensitiveCompare(correction.heard) == .orderedSame && $0.to == correction.corrected
        }
        guard !known else { return false }
        addReplacement(from: correction.heard, to: correction.corrected, learned: true)
        addWord(correction.corrected, learned: true)
        return true
    }

    /// Words handed to the recognizer as hints. Apple's recognizer accepts a short list.
    var recognitionHints: [String] {
        Array(vocabulary.map(\.word).prefix(100))
    }

    // MARK: - Snippets

    func addSnippet(trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        snippets.removeAll { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame }
        snippets.insert(Snippet(trigger: trigger, expansion: expansion), at: 0)
        save()
    }

    func deleteSnippet(_ id: Snippet.ID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    // MARK: - Custom actions

    func addCustomAction(name: String, instruction: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instruction.isEmpty else { return }
        customActions.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        customActions.append(CustomAction(name: name, instruction: instruction))
        save()
    }

    func deleteCustomAction(_ id: CustomAction.ID) {
        customActions.removeAll { $0.id == id }
        save()
    }

    // MARK: - Scratchpad

    /// Adds a dictation to the end of the scratchpad, on its own line.
    func appendToScratchpad(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scratchpad = scratchpad.isEmpty ? trimmed : scratchpad + "\n\n" + trimmed
    }

    // MARK: - Persistence

    private func save() {
        let contents = Contents(history: history, vocabulary: vocabulary, replacements: replacements, snippets: snippets,
                                customActions: customActions, scratchpad: scratchpad)
        do {
            let data = try JSONEncoder.store.encode(contents)
            try data.write(to: file, options: .atomic)
        } catch {
            AppLog.write("could not save store.json: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static let store: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let store: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

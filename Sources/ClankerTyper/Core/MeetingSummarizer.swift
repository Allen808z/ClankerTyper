import Foundation

/// Turns a meeting transcript into a summary, key points, decisions and action items with the
/// on-device model. Apple's model reads about 4,000 tokens at a time, so a long meeting is taken
/// in parts: notes for each part, then the notes are combined. Prompts, splitting and parsing are
/// pure and unit-tested.
struct MeetingSummarizer {
    enum SummaryError: LocalizedError, Equatable {
        case emptyTranscript
        case unreadable

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "Nothing was said in this recording, so there is nothing to summarize."
            case .unreadable: return "The model's summary could not be read. Try Summarize again."
            }
        }
    }

    /// Characters of transcript per request: comfortably inside the model's window with the
    /// instructions and the answer.
    static let chunkCharacters = 6000

    let model: TextModel

    init(model: TextModel = Rewriter().model) {
        self.model = model
    }

    func summarize(_ segments: [MeetingSegment], language: Rewriter.Language,
                   progress: (@MainActor (String) -> Void)? = nil) async throws -> MeetingSummary {
        let lines = segments.map { "[\(Meeting.clock($0.start))] \($0.speaker.label): \($0.text)" }
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }

        let chunks = Self.chunk(lines, limit: Self.chunkCharacters)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if chunks.count > 1 { await progress?("Summarizing part \(index + 1) of \(chunks.count)…") }
            notes.append(try await model.complete(
                instructions: Self.instructions(language: language, combining: false),
                prompt: chunk, timeout: 120
            ))
        }

        // Combine part notes until one answer is left.
        while notes.count > 1 {
            await progress?("Combining notes…")
            let groups = Self.chunk(notes, limit: Self.chunkCharacters)
            var combined: [String] = []
            for group in groups {
                combined.append(try await model.complete(
                    instructions: Self.instructions(language: language, combining: true),
                    prompt: group, timeout: 120
                ))
            }
            // Guard against a group that cannot shrink: stop rather than loop forever.
            if combined.count >= notes.count { notes = [combined.joined(separator: "\n\n")]; break }
            notes = combined
        }

        guard let summary = Self.parse(notes.first ?? "") else { throw SummaryError.unreadable }
        return summary
    }

    // MARK: - Prompts

    static func instructions(language: Rewriter.Language, combining: Bool) -> String {
        switch language {
        case .english:
            let source = combining
                ? "The user message contains notes taken on consecutive parts of one meeting. Merge them into notes for the whole meeting, removing repeats."
                : "The user message is a meeting transcript. Each line starts with a time and the speaker: \"You\" is the person using this app, \"Others\" are the other participants."
            return """
            You take notes on meetings. \(source) Write in English. Only include what was actually \
            said: never invent names, dates, numbers or tasks, and copy days and times exactly as \
            they were said. Decisions are only what was agreed, including fallback plans. Action \
            items list every task someone said they or another person will do, including tasks \
            for "You" (the user), each with who and when. Answer exactly in this format, with \
            "- None" under a heading that has nothing:
            SUMMARY:
            Two to four sentences.
            KEY POINTS:
            - point
            DECISIONS:
            - decision
            ACTION ITEMS:
            - who: task
            """
        case .french:
            let source = combining
                ? "Le message de l'utilisateur contient des notes prises sur des parties successives d'une même réunion. Fusionne-les en notes pour toute la réunion, sans répétitions."
                : "Le message de l'utilisateur est la transcription d'une réunion. Chaque ligne commence par une heure et l'intervenant : « You » est la personne qui utilise cette app, « Others » désigne les autres participants."
            return """
            Tu prends des notes de réunion. \(source) Écris en français. N'inclus que ce qui a \
            vraiment été dit : n'invente jamais de noms, de dates, de chiffres ni de tâches, et \
            recopie les jours et les heures exactement comme ils ont été dits. Les décisions sont \
            seulement ce qui a été convenu, y compris les plans de repli. Les actions listent \
            chaque tâche que quelqu'un a dit qu'il ferait ou qu'une autre personne ferait, y compris \
            celles de « You » (l'utilisateur), avec qui et quand. Réponds exactement dans ce format, \
            avec « - Aucun » sous un titre qui n'a rien :
            RÉSUMÉ :
            Deux à quatre phrases.
            POINTS CLÉS :
            - point
            DÉCISIONS :
            - décision
            ACTIONS :
            - qui : tâche
            """
        }
    }

    // MARK: - Splitting and parsing

    /// Groups lines into pieces of at most `limit` characters, never splitting a line.
    static func chunk(_ lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Reads the four sections in English or French, tolerating Markdown decoration.
    static func parse(_ text: String) -> MeetingSummary? {
        enum Section { case overview, keyPoints, decisions, actions }
        let headings: [(Section, [String])] = [
            (.overview, ["summary", "résumé", "resume"]),
            (.keyPoints, ["key points", "points clés", "points cles"]),
            (.decisions, ["decisions", "décisions"]),
            (.actions, ["action items", "actions", "actions à mener"]),
        ]
        var current: Section?
        var overview: [String] = []
        var keyPoints: [String] = [], decisions: [String] = [], actions: [String] = []
        var sawHeading = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A heading is the text before the first colon, once Markdown marks are removed:
            // "SUMMARY:", "## Key points", "**RÉSUMÉ :** Réunion sur…".
            let decorations = CharacterSet(charactersIn: "#*_ :\u{00A0}")
            let beforeColon = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            let candidate = beforeColon.trimmingCharacters(in: decorations).lowercased()
            if let match = headings.first(where: { $0.1.contains(candidate) }) {
                current = match.0
                sawHeading = true
                // Text after the colon on the heading line ("SUMMARY: We met…").
                if let colon = line.firstIndex(of: ":") {
                    let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: decorations)
                    if !rest.isEmpty, !isNone(rest) {
                        switch match.0 {
                        case .overview: overview.append(rest)
                        case .keyPoints: keyPoints.append(rest)
                        case .decisions: decisions.append(rest)
                        case .actions: actions.append(rest)
                        }
                    }
                }
                continue
            }
            let item = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•*[] ")).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, !isNone(item) else { continue }
            switch current {
            case .overview?: overview.append(line)
            case .keyPoints?: keyPoints.append(item)
            case .decisions?: decisions.append(item)
            case .actions?: actions.append(item)
            case nil: overview.append(line)
            }
        }
        guard sawHeading, !(overview.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actions.isEmpty) else { return nil }
        return MeetingSummary(
            overview: overview.joined(separator: " "),
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actions.map { ActionItem(text: $0) }
        )
    }

    /// "None", or an action with nobody's task: "You: None", "Sam : aucune".
    private static func isNone(_ item: String) -> Bool {
        let empties: Set<String> = ["none", "aucun", "aucune", "n/a", "nothing", "rien", "-"]
        func empty(_ text: Substring) -> Bool {
            empties.contains(text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
        }
        if empty(Substring(item)) { return true }
        if let colon = item.firstIndex(of: ":") { return empty(item[item.index(after: colon)...]) }
        return false
    }
}

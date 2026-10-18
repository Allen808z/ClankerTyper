import Foundation

/// Pure text rules applied between recognition and pasting, plus the rules for learning from
/// the user's corrections. No I/O here, so every rule is unit-tested.
enum TextProcessing {
    // MARK: - Filler words

    /// Hesitation sounds that carry no meaning, per language. Real words are deliberately left out
    /// ("like", "so", "ben", "bah") because removing them can change the sentence.
    static let fillers: [String: Set<String>] = [
        "en": ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm", "mhm"],
        "fr": ["euh", "euhh", "heu", "hum", "hmm", "mm"],
    ]

    static func fillerWords(for languages: [String]) -> Set<String> {
        languages.reduce(into: Set<String>()) { set, id in
            let code = String(id.prefix(2)).lowercased()
            set.formUnion(fillers[code] ?? [])
        }
    }

    /// Drops filler words and immediately repeated words ("the the"). Sentence-ending
    /// punctuation on a dropped filler moves to the previous word; the result keeps the
    /// original's leading capital.
    static func removeFillers(_ text: String, fillers: Set<String>) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return text }

        var kept: [String] = []
        for token in tokens {
            let (core, trailing) = splitTrailingPunctuation(token)
            let lower = core.lowercased()
            if fillers.contains(lower) {
                if trailing.contains(where: { ".!?".contains($0) }), let last = kept.last {
                    let (lastCore, lastTrailing) = splitTrailingPunctuation(last)
                    if lastTrailing.isEmpty || lastTrailing.allSatisfy({ $0 == "," }) {
                        kept[kept.count - 1] = lastCore + String(trailing.filter { ".!?".contains($0) })
                    }
                }
                continue
            }
            if let last = kept.last {
                let (lastCore, lastTrailing) = splitTrailingPunctuation(last)
                if lastTrailing.isEmpty, !lower.isEmpty, lastCore.lowercased() == lower {
                    // "the the" -> "the", keeping the second token's punctuation.
                    kept[kept.count - 1] = lastCore + trailing
                    continue
                }
            }
            kept.append(token)
        }

        var result = kept.joined(separator: " ")
        if let first = text.first, first.isUppercase, let firstKept = result.first, firstKept.isLowercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        return result
    }

    private static func splitTrailingPunctuation(_ token: String) -> (core: String, trailing: String) {
        var core = token
        var trailing = ""
        while let last = core.last, ",.!?;:…".contains(last) {
            trailing = String(last) + trailing
            core.removeLast()
        }
        return (core, trailing)
    }

    // MARK: - Replacements and snippets

    /// Replaces whole words or phrases, ignoring case. A phrase never matches inside a longer word.
    static func replacingWholeWords(_ text: String, from: String, to: String) -> String {
        let phrase = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to)
        )
    }

    static func applyReplacements(_ text: String, _ pairs: [(from: String, to: String)]) -> String {
        // Longer phrases first, so "new york city" wins over "new york".
        pairs.sorted { $0.from.count > $1.from.count }
            .reduce(text) { replacingWholeWords($0, from: $1.from, to: $1.to) }
    }

    /// Snippets expand a spoken trigger phrase into stored text. The recognizer often adds a full
    /// stop after a short phrase, so a dictation that is only the trigger becomes only the expansion.
    static func applySnippets(_ text: String, _ snippets: [(trigger: String, expansion: String)]) -> String {
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        for snippet in snippets where bare.compare(snippet.trigger, options: .caseInsensitive) == .orderedSame {
            return snippet.expansion
        }
        return applyReplacements(text, snippets.map { ($0.trigger, $0.expansion) })
    }

    // MARK: - Smart spacing and capitals

    /// Fits dictated text to what is already before the cursor: adds a leading space when the
    /// text would otherwise touch the previous word, capitalizes at the start of a sentence, and
    /// lowercases the first word mid-sentence when it is an ordinary word.
    /// - Parameters:
    ///   - before: text before the insertion point, or nil when it is not readable.
    ///   - isOrdinaryLowercaseWord: true when the word is a normal dictionary word in lowercase
    ///     (so "The" may become "the", but "Paris" and "I" stay as they are).
    static func fitToContext(_ text: String, before: String?, isOrdinaryLowercaseWord: (String) -> Bool) -> String {
        guard let before, !text.isEmpty else { return text }

        let lastChar = before.last
        let lastVisible = before.last(where: { !$0.isWhitespace })
        let atSentenceStart = lastVisible == nil || ".!?\n".contains(lastVisible!) || before.last == "\n"

        var body = text
        if atSentenceStart {
            body = body.prefix(1).uppercased() + body.dropFirst()
        } else {
            let firstWord = String(body.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            let lowered = firstWord.lowercased()
            if !firstWord.isEmpty, firstWord != lowered, firstWord.dropFirst() == lowered.dropFirst(),
               isOrdinaryLowercaseWord(lowered) {
                body = lowered + body.dropFirst(firstWord.count)
            }
        }

        let opensAnything = lastChar.map { "([{\"'“‘/-".contains($0) } ?? true
        let needsSpace = lastChar.map { !$0.isWhitespace } ?? false
            && !opensAnything
            && (body.first.map { $0.isLetter || $0.isNumber } ?? false)
        return (needsSpace ? " " : "") + body
    }

    // MARK: - Learning from corrections

    struct Correction: Equatable {
        let heard: String
        let corrected: String
    }

    /// Finds word-for-word corrections the user made inside text that Clanker pasted.
    /// `before` is the field's text just after pasting, `after` is the text once the user is done.
    /// Edits outside the pasted words, and rewrites of more than three words, are ignored.
    static func corrections(before: String, after: String, inserted: String) -> [Correction] {
        guard before != after, !inserted.isEmpty,
              let insertedRange = before.range(of: inserted, options: .backwards) else { return [] }

        let old = Array(before)
        let new = Array(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        // Grow the changed span out to whole words. The prefix and suffix are shared by both
        // texts, so the same growth applies to both.
        var start = prefix
        while start > 0, isWordCharacter(old[start - 1]) { start -= 1 }
        var oldEnd = old.count - suffix
        var newEnd = new.count - suffix
        while oldEnd < old.count, isWordCharacter(old[oldEnd]) { oldEnd += 1; newEnd += 1 }

        let insertedStart = before.distance(from: before.startIndex, to: insertedRange.lowerBound)
        let insertedEnd = before.distance(from: before.startIndex, to: insertedRange.upperBound)
        guard start >= insertedStart, oldEnd <= insertedEnd, oldEnd > start else { return [] }

        let oldWords = words(in: String(old[start..<oldEnd]))
        let newWords = words(in: String(new[start..<max(start, newEnd)]))
        guard oldWords.count == newWords.count, (1...3).contains(oldWords.count) else { return [] }

        return zip(oldWords, newWords)
            .filter { $0 != $1 }
            .map { Correction(heard: $0, corrected: $1) }
    }

    /// Decides whether a correction is worth remembering. Clanker learns words that are not part
    /// of everyday language (names, brands, jargon). It skips:
    /// - corrections to an ordinary word, which are usually a one-off choice, not a mishearing;
    /// - an ordinary word with one letter removed, which leaves a non-word ("hello" -> "helo"):
    ///   that is an accidental edit and does not mean anything.
    /// A real word swapped for an unusual one ("clinker" -> "Clanker") is learned: that is the
    /// recognizer mishearing a name.
    static func shouldLearn(_ correction: Correction, isOrdinaryWord: (String) -> Bool) -> Bool {
        let heard = correction.heard
        let corrected = correction.corrected
        guard corrected != heard,
              corrected.count >= 2,
              corrected.contains(where: \.isLetter),
              !corrected.contains(where: \.isWhitespace) else { return false }

        if isOrdinaryWord(corrected) { return false }
        let removedOneLetter = corrected.count == heard.count - 1
            && editDistance(heard.lowercased(), corrected.lowercased()) == 1
        if isOrdinaryWord(heard), removedOneLetter {
            return false
        }
        return true
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    static func wordCount(_ text: String) -> Int {
        words(in: text).count
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }

    /// Words with surrounding punctuation removed.
    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-"))) }
            .filter { !$0.isEmpty }
    }
}

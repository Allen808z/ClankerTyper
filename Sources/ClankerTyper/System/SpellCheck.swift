import AppKit

/// Asks the macOS spell checker whether a word is ordinary vocabulary in any of the user's
/// dictation languages. Used to decide what is worth learning, and whether a first word may be
/// lowercased mid-sentence.
@MainActor
enum SpellCheck {
    static func isOrdinaryWord(_ word: String, languages: [String]) -> Bool {
        let checker = NSSpellChecker.shared
        let codes = languages.map { String($0.prefix(2)) }
        return codes.contains { code in
            checker.checkSpelling(of: word, startingAt: 0, language: code, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}

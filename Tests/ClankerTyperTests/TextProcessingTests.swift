import Testing
@testable import ClankerTyper

/// A tiny stand-in for the system spell checker, so the learning rules are tested exactly.
private let ordinary: Set<String> = ["hello", "the", "meeting", "there", "their", "store", "clinker", "so", "we", "go"]
private func isOrdinary(_ word: String) -> Bool { ordinary.contains(word.lowercased()) }

@Suite("Filler words")
struct FillerTests {
    let fillers = TextProcessing.fillerWords(for: ["en-US", "fr-FR"])

    @Test func removesEnglishAndFrenchFillers() {
        #expect(TextProcessing.removeFillers("So um we should uh go.", fillers: fillers) == "So we should go.")
        #expect(TextProcessing.removeFillers("Je pense euh que oui.", fillers: fillers) == "Je pense que oui.")
    }

    @Test func keepsCapitalWhenLeadingFillerIsRemoved() {
        #expect(TextProcessing.removeFillers("Um, so we go.", fillers: fillers) == "So we go.")
    }

    @Test func movesSentenceEndFromDroppedFiller() {
        #expect(TextProcessing.removeFillers("That works uh. Next", fillers: fillers) == "That works. Next")
    }

    @Test func collapsesRepeatedWords() {
        #expect(TextProcessing.removeFillers("I went to the the store", fillers: fillers) == "I went to the store")
    }

    @Test func leavesRealWordsAlone() {
        #expect(TextProcessing.removeFillers("I like it, so we go", fillers: fillers) == "I like it, so we go")
    }
}

@Suite("Replacements and snippets")
struct ReplacementTests {
    @Test func replacesWholeWordsIgnoringCase() {
        #expect(TextProcessing.replacingWholeWords("Meet clinker today", from: "clinker", to: "ClankerTyper") == "Meet ClankerTyper today")
    }

    @Test func doesNotReplaceInsideLongerWords() {
        #expect(TextProcessing.replacingWholeWords("clinkers", from: "clinker", to: "ClankerTyper") == "clinkers")
    }

    @Test func longerPhraseWins() {
        let pairs: [(from: String, to: String)] = [("new york", "NY"), ("new york city", "NYC")]
        #expect(TextProcessing.applyReplacements("I love new york city", pairs) == "I love NYC")
    }

    @Test func snippetAloneBecomesExpansion() {
        let snippets: [(trigger: String, expansion: String)] = [("my email", "allan@example.com")]
        #expect(TextProcessing.applySnippets("My email.", snippets) == "allan@example.com")
        #expect(TextProcessing.applySnippets("Send it to my email please", snippets) == "Send it to allan@example.com please")
    }
}

@Suite("Smart spacing and capitals")
struct SmartSpacingTests {
    @Test func addsSpaceAfterPreviousWord() {
        #expect(TextProcessing.fitToContext("The meeting moved.", before: "Hello.", isOrdinaryLowercaseWord: isOrdinary) == " The meeting moved.")
    }

    @Test func lowercasesOrdinaryWordMidSentence() {
        #expect(TextProcessing.fitToContext("The meeting moved.", before: "I think", isOrdinaryLowercaseWord: isOrdinary) == " the meeting moved.")
    }

    @Test func keepsNamesCapitalizedMidSentence() {
        #expect(TextProcessing.fitToContext("Paris is nice.", before: "I think", isOrdinaryLowercaseWord: isOrdinary) == " Paris is nice.")
    }

    @Test func capitalizesAtSentenceStart() {
        #expect(TextProcessing.fitToContext("hello there", before: "", isOrdinaryLowercaseWord: isOrdinary) == "Hello there")
        #expect(TextProcessing.fitToContext("hello there", before: "Done. ", isOrdinaryLowercaseWord: isOrdinary) == "Hello there")
    }

    @Test func noSpaceAfterOpeningBracketOrWhenUnknown() {
        #expect(TextProcessing.fitToContext("Hello", before: "(", isOrdinaryLowercaseWord: isOrdinary) == "hello")
        #expect(TextProcessing.fitToContext("Hello", before: nil, isOrdinaryLowercaseWord: isOrdinary) == "Hello")
    }
}

@Suite("Finding corrections")
struct CorrectionFindingTests {
    @Test func findsSingleWordCorrection() {
        let found = TextProcessing.corrections(
            before: "Notes: ask clinker about the launch",
            after: "Notes: ask ClankerTyper about the launch",
            inserted: "ask clinker about the launch"
        )
        #expect(found == [.init(heard: "clinker", corrected: "ClankerTyper")])
    }

    @Test func ignoresEditsOutsideThePastedText() {
        let found = TextProcessing.corrections(
            before: "Draft one. ask clinker",
            after: "Draft two. ask clinker",
            inserted: "ask clinker"
        )
        #expect(found.isEmpty)
    }

    @Test func ignoresLargeRewrites() {
        let found = TextProcessing.corrections(
            before: "we should meet on monday at noon",
            after: "let's talk",
            inserted: "we should meet on monday at noon"
        )
        #expect(found.isEmpty)
    }
}

@Suite("What gets learned")
struct LearningRuleTests {
    @Test func learnsUnusualWords() {
        #expect(TextProcessing.shouldLearn(.init(heard: "clinker", corrected: "ClankerTyper"), isOrdinaryWord: isOrdinary))
        #expect(TextProcessing.shouldLearn(.init(heard: "Alan", corrected: "Allan"), isOrdinaryWord: isOrdinary))
    }

    @Test func skipsOrdinaryWordChoices() {
        #expect(!TextProcessing.shouldLearn(.init(heard: "there", corrected: "their"), isOrdinaryWord: isOrdinary))
    }

    @Test func skipsRemovingALetterFromARealWord() {
        // "hello" -> "helo" leaves a word that means nothing: an accidental edit, not a name.
        #expect(!TextProcessing.shouldLearn(.init(heard: "hello", corrected: "helo"), isOrdinaryWord: isOrdinary))
    }

    @Test func skipsJunk() {
        #expect(!TextProcessing.shouldLearn(.init(heard: "store", corrected: "x"), isOrdinaryWord: isOrdinary))
        #expect(!TextProcessing.shouldLearn(.init(heard: "store", corrected: "123"), isOrdinaryWord: isOrdinary))
    }

    @Test func editDistanceCounts() {
        #expect(TextProcessing.editDistance("hello", "helo") == 1)
        #expect(TextProcessing.editDistance("clinker", "clanker") == 1)
        #expect(TextProcessing.editDistance("", "abc") == 3)
    }
}

@Suite("Spoken commands")
struct VoiceCommandTests {
    @Test func scratchThatRemovesThePreviousPhrase() {
        #expect(TextProcessing.applyVoiceCommands("I went to the store. Scratch that. I went home.") == "I went home.")
    }

    @Test func scratchThatAtTheEndRemovesThatPhrase() {
        #expect(TextProcessing.applyVoiceCommands("Call me tomorrow. Send it now scratch that.") == "Call me tomorrow.")
    }

    @Test func newLineAndParagraph() {
        #expect(TextProcessing.applyVoiceCommands("Hello. New line. Thanks for the update.") == "Hello.\nThanks for the update.")
        #expect(TextProcessing.applyVoiceCommands("First point new paragraph second point") == "First point\n\nSecond point")
    }

    @Test func keepsTheCommaTheUserSaid() {
        #expect(TextProcessing.applyVoiceCommands("Dear Anna, new line thanks for the update") == "Dear Anna,\nThanks for the update")
    }

    @Test func frenchCommands() {
        #expect(TextProcessing.applyVoiceCommands("Bonjour nouvelle ligne merci pour tout") == "Bonjour\nMerci pour tout")
        #expect(TextProcessing.applyVoiceCommands("On se voit lundi. Efface ça. On se voit mardi.") == "On se voit mardi.")
        #expect(TextProcessing.applyVoiceCommands("Premier point. À la ligne. Deuxième point.") == "Premier point.\nDeuxième point.")
    }

    @Test func wordsInsideOtherWordsAreNotCommands() {
        #expect(TextProcessing.applyVoiceCommands("The newline character is escaped.") == "The newline character is escaped.")
    }
}

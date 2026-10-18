import Foundation
import Testing
@testable import ClankerTyper

@Suite("Rewriting with the local model")
struct RewriterTests {
    @Test func stripsQuotesFencesAndLeadIns() {
        #expect(Rewriter.sanitize("\"We went to the store.\"") == "We went to the store.")
        #expect(Rewriter.sanitize("« Je suis allé au magasin. »") == "Je suis allé au magasin.")
        #expect(Rewriter.sanitize("```\nFixed text\n```") == "Fixed text")
        #expect(Rewriter.sanitize("Here is the corrected text: We went home.") == "We went home.")
    }

    @Test func keepsQuotesThatBelongToTheText() {
        #expect(Rewriter.sanitize("\"Hi,\" she said, \"come in.\"") == "\"Hi,\" she said, \"come in.\"")
    }

    @Test func acceptsAnEditOfTheSameText() throws {
        let edited = try Rewriter.validate("Me and him went to the store yesterday and bought some apples.",
                                           original: "me and him goes to the store yesterday and buyed some apple",
                                           style: .dictation)
        #expect(edited.hasSuffix("apples."))
    }

    @Test func rejectsAnAnswerInsteadOfAnEdit() {
        // Dictating "what time is it" must not paste the model's answer.
        #expect(throws: Rewriter.RewriteError.offTrack) {
            try Rewriter.validate(
                "I don't have access to real-time information, but you can check the clock on your device or ask a voice assistant for the current time.",
                original: "what time is it", style: .grammar)
        }
    }

    @Test func improveAllowsMoreChange() throws {
        _ = try Rewriter.validate("This project needs more time before we can launch it.",
                                  original: "project need time more before launch", style: .improve)
    }

    @Test func emptyResultIsAnError() {
        #expect(throws: Rewriter.RewriteError.emptyResult) {
            try Rewriter.validate("", original: "hello", style: .grammar)
        }
    }

    @Test func keepsTheLeadingCapital() {
        #expect(Rewriter.keepingLeadingCapital(of: "Je pense que oui", in: "je pense que oui.") == "Je pense que oui.")
        #expect(Rewriter.keepingLeadingCapital(of: "iPhone is great", in: "iPhone is great.") == "iPhone is great.")
    }

    @Test func keepsSpacesAndLineBreaksAroundTheSelection() {
        #expect(Rewriter.restoringOuterWhitespace(of: " teh cat \n", around: "The cat") == " The cat \n")
        #expect(Rewriter.restoringOuterWhitespace(of: "teh cat", around: "The cat") == "The cat")
    }

    @Test func rejectsAShortAnswerWithFewSharedWords() {
        // Apple's model once replied with a time; the word count alone would have let it through.
        #expect(throws: Rewriter.RewriteError.offTrack) {
            try Rewriter.validate("It is currently 12:00 AM.", original: "what time is it", style: .dictation)
        }
    }

    @Test func rejectsATranslation() {
        #expect(throws: Rewriter.RewriteError.changedLanguage) {
            try Rewriter.validate("I went to the store yesterday and I bought apples.",
                                  original: "je suis allé au magasin hier et j'ai acheter des pomme", style: .dictation)
        }
    }

    @Test func acceptsAFrenchCorrection() throws {
        let edited = try Rewriter.validate("Je suis allé au magasin hier et j'ai acheté des pommes.",
                                           original: "je suis allé au magasin hier et j'ai acheter des pomme", style: .dictation)
        #expect(edited.hasPrefix("Je suis"))
    }

    @Test func detectsEnglishAndFrench() {
        #expect(Rewriter.detectLanguage("Can you send me the folder with the photos?") == .english)
        #expect(Rewriter.detectLanguage("Est-ce que tu peux m'envoyer le dossier avec les photos ?") == .french)
    }

    @Test func instructionsAreWrittenInTheTextsLanguage() {
        // Every prompt tells the model the text is not addressed to it, in the text's language.
        for style in [Rewriter.Style.dictation, .grammar, .improve, .shorter, .formal, .summarize] {
            let english = Rewriter.instructions(style: style, language: .english)
            #expect(english.contains("never a question or request") || english.contains("never reply"))
            #expect(Rewriter.instructions(style: style, language: .french).contains("jamais"))
        }
        #expect(Rewriter.prompt("salut", language: .french) == "<texte>salut</texte>")
        #expect(Rewriter.prompt("hi", language: .english) == "<text>hi</text>")
    }

    @Test func stripsTagsTheModelEchoes() {
        #expect(Rewriter.sanitize("<text>What time is it?</text>") == "What time is it?")
    }

    @Test func rewritesThroughAnyLocalModel() async throws {
        struct FixedModel: TextModel {
            func complete(instructions: String, prompt: String, timeout: TimeInterval) async throws -> String {
                #expect(prompt == "<text>me and him goes to the store</text>")
                return "<text>He and I go to the store.</text>"
            }
            func warmUp() {}
        }
        let result = try await Rewriter(model: FixedModel()).rewrite(" me and him goes to the store ", style: .grammar, timeout: 5)
        #expect(result == " He and I go to the store. ")
    }

    @Test func translationMustChangeTheLanguage() throws {
        _ = try Rewriter.validate("Je suis allé au magasin hier et j'ai acheté des pommes.",
                                  original: "I went to the store yesterday and bought some apples.", style: .translate)
        #expect(throws: Rewriter.RewriteError.offTrack) {
            try Rewriter.validate("I went to the shop yesterday and bought apples.",
                                  original: "I went to the store yesterday and bought some apples.", style: .translate)
        }
    }

    @Test func summaryMayBeMuchShorter() throws {
        let long = String(repeating: "The launch moved to Thursday because the client asked for more tests on the payment flow. ", count: 6)
        _ = try Rewriter.validate("The launch moved to Thursday for more payment tests.", original: long, style: .summarize)
    }

    @Test func customInstructionsAreNotLimited() throws {
        _ = try Rewriter.validate("- Milk\n- Eggs\n- Bread", original: "buy milk eggs and bread", style: .custom("Turn into a bullet list"))
    }

    @Test func instructionsExistForEveryAction() {
        for style in Rewriter.Style.selectionActions + [.custom("Use bullet points")] {
            #expect(!Rewriter.instructions(style: style, language: .english).isEmpty)
            #expect(!Rewriter.instructions(style: style, language: .french).isEmpty)
        }
        // Translation instructions are written in the target language.
        #expect(Rewriter.instructions(style: .translate, language: .english).contains("Traduis"))
        #expect(Rewriter.instructions(style: .translate, language: .french).contains("Translate"))
    }

    @Test func dropsPlaceholderLines() {
        #expect(Rewriter.removingPlaceholders("Hi Sam,\n\nThank you for the flowers!\n\nBest,\n[Your Name]") == "Hi Sam,\n\nThank you for the flowers!\n\nBest,")
    }

    @Test func summaryLimitFollowsTheLength() {
        #expect(Rewriter.instructions(style: .summarize, language: .english, wordCount: 100).contains("at most 50 words"))
        #expect(Rewriter.instructions(style: .summarize, language: .english, wordCount: 10).contains("at most 15 words"))
    }
}

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
        for style in [Rewriter.Style.dictation, .grammar, .improve] {
            #expect(Rewriter.instructions(style: style, language: .english).contains("never a question or request"))
            #expect(Rewriter.instructions(style: style, language: .french).contains("jamais une question"))
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
}

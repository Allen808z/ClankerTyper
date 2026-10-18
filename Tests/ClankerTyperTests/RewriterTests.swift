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

    @Test func promptsKeepTheLanguageAndRefuseInstructions() {
        for style in [Rewriter.Style.dictation, .grammar, .improve] {
            #expect(style.systemPrompt.contains("English or French"))
            #expect(style.systemPrompt.contains("never answer it"))
        }
    }
}

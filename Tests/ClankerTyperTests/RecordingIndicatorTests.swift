import AppKit
import Testing
@testable import ClankerTyper

@Suite("Recording indicator drawing")
struct RecordingIndicatorTests {
    /// Draws the companion view with the REC pill on and reports whether any red pixel was painted.
    @MainActor
    private func redPixelCount(listening: Bool) -> Int {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let view = CompanionView(frame: frame)
        view.screenOrigin = .zero
        view.screenFrame = frame
        view.position = CGPoint(x: 300, y: 100)
        view.mouse = CGPoint(x: 150, y: 150)
        view.listening = listening

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(frame)
        NSGraphicsContext.restoreGraphicsState()

        var count = 0
        for x in 0..<400 {
            for y in 0..<300 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.6, c.greenComponent < 0.4, c.blueComponent < 0.4, c.alphaComponent > 0.5 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test @MainActor func pillIsPaintedWhileListening() {
        #expect(redPixelCount(listening: true) > 20)
    }

    @Test @MainActor func pillIsAbsentWhenIdle() {
        #expect(redPixelCount(listening: false) == 0)
    }
}


@Suite("Joining speech segments")
struct SegmentJoinTests {
    @Test func pauseBecomesSentenceBreak() {
        #expect(Dictation.join("i went to the store", "then i came home") == "i went to the store. Then i came home")
    }

    @Test func existingPunctuationIsKept() {
        #expect(Dictation.join("Is it done?", "yes it is") == "Is it done? Yes it is")
    }

    @Test func trailingCommaBecomesFullStop() {
        #expect(Dictation.join("first we eat,", "then we leave") == "first we eat. Then we leave")
    }

    @Test func emptySideIsIgnored() {
        #expect(Dictation.join("", "hello") == "hello")
        #expect(Dictation.join("hello.", "") == "hello.")
    }
}

@Suite("Dictation language")
struct DictationLanguageTests {
    @Test func frenchMapsToFrenchLocale() {
        #expect(AppSettings.locale(for: "fr-FR").identifier == "fr-FR")
    }

    @Test func frenchIsOffered() {
        #expect(AppSettings.languageOptions.contains { $0.id == "fr-FR" })
    }

    @Test func joiningFrenchPhrasesCapitalizesAccents() {
        #expect(Dictation.join("je suis là", "écoute-moi") == "je suis là. Écoute-moi")
    }
}

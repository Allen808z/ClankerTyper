import AVFoundation
import Foundation

/// Reads replies aloud with the system voice. Stops immediately when the user talks again.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Transcribes meeting recordings on this Mac with the speech engine macOS 26 provides for long
/// audio (SpeechAnalyzer). Each language needs Apple's on-device model, downloaded once; audio is
/// never sent anywhere.
enum MeetingTranscriber {
    enum TranscriptionError: LocalizedError, Equatable {
        case needsMacOS26
        case unsupported(String)
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .needsMacOS26:
                return "Meeting transcription needs macOS 26."
            case .unsupported(let id):
                return "\(Dictation.displayName(id)) can't be transcribed on this Mac."
            case .notInstalled(let id):
                return "The \(Dictation.displayName(id)) transcription model isn't on this Mac yet. Download it from the meeting, then try again."
            }
        }
    }

    /// True when this language's on-device model is ready to use.
    static func isInstalled(_ id: String) async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let wanted = Locale(identifier: id).identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Downloads Apple's on-device model for the language. Only the model is downloaded; no
    /// audio or text leaves the Mac.
    static func install(_ id: String) async throws {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsMacOS26 }
        let transcriber = try await makeTranscriber(id)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            AppLog.write("downloading the \(id) transcription model")
            try await request.downloadAndInstall()
        }
    }

    /// The recording's speech as timed segments for one speaker.
    static func transcribe(_ file: URL, speaker: MeetingSegment.Speaker, language id: String) async throws -> [MeetingSegment] {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsMacOS26 }
        guard await isInstalled(id) else { throw TranscriptionError.notInstalled(id) }
        let transcriber = try await makeTranscriber(id)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)

        async let collected: [MeetingSegment] = {
            var segments: [MeetingSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(MeetingSegment(
                    speaker: speaker,
                    start: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                    end: result.range.end.seconds.isFinite ? result.range.end.seconds : 0,
                    text: text
                ))
            }
            return segments
        }()

        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private static func makeTranscriber(_ id: String) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw TranscriptionError.unsupported(id)
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                 attributeOptions: [.audioTimeRange])
    }
}

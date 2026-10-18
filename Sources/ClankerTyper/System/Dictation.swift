import AVFoundation
import Foundation
import Speech

/// Hands audio from the microphone thread to the current recognition requests (one per
/// language), and measures how quiet and how loud the microphone has been. The lock keeps the
/// audio thread and the main actor apart.
final class RequestBox: @unchecked Sendable {
    /// Below this RMS level the microphone counts as quiet.
    static let quietLevel: Float = 0.01
    /// Audio that arrives while no request is attached (a phrase is being handed over) is kept
    /// here, up to this many buffers, so the start of the next phrase is not lost.
    private static let pendingLimit = 300

    private let lock = NSLock()
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var pending: [AVAudioPCMBuffer] = []
    private var quietSeconds: TimeInterval = 0
    private var peakLevel: Float = 0

    func set(_ requests: [SFSpeechAudioBufferRecognitionRequest]) {
        lock.lock()
        defer { lock.unlock() }
        self.requests = requests
        guard !requests.isEmpty else { return }
        for buffer in pending {
            requests.forEach { $0.append(buffer) }
        }
        pending.removeAll()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

        lock.lock()
        defer { lock.unlock() }
        quietSeconds = level < Self.quietLevel ? quietSeconds + seconds : 0
        peakLevel = max(peakLevel, level)
        if !requests.isEmpty {
            requests.forEach { $0.append(buffer) }
        } else if pending.count < Self.pendingLimit {
            pending.append(buffer)
        }
    }

    /// How long the microphone has been quiet, in seconds.
    func quiet() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return quietSeconds
    }

    /// The loudest level heard since the recording started.
    func peak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return peakLevel
    }

    func reset() {
        lock.lock()
        requests = []
        pending = []
        quietSeconds = 0
        peakLevel = 0
        lock.unlock()
    }

    /// Ends the current requests so the recognizers finalize their text.
    func endAudio() {
        lock.lock()
        let current = requests
        requests = []
        quietSeconds = 0
        lock.unlock()
        current.forEach { $0.endAudio() }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += channel[i] * channel[i]
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

/// Streams microphone audio into Apple's speech recognizer while the user is dictating.
/// Each phrase is finalized at a pause, so its full text is kept, and recognition then carries
/// on. With several languages, each phrase is recognized in all of them and the most confident
/// result wins. Recognition is always on-device: a language whose on-device model is not installed
/// is skipped, so the voice is never sent to Apple's speech servers.
@MainActor
final class Dictation {
    enum DictationError: LocalizedError {
        case recognizerUnavailable
        case notOnDevice(languages: [String])
        case noMicrophone
        case audioEngine(String)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is not available for your language right now."
            case .notOnDevice(let languages):
                let names = languages.map { Dictation.displayName($0) }.joined(separator: " and ")
                return "\(names) isn't installed for on-device recognition, and ClankerTyper never sends your voice off this Mac. Add it in System Settings → Keyboard → Dictation, then try again."
            case .noMicrophone:
                return "No microphone found. Plug one in or pick one in System Settings → Sound."
            case .audioEngine(let message):
                return "The microphone could not start: \(message)"
            }
        }
    }

    /// Called with the running transcript as it changes.
    var onPartial: ((String) -> Void)?

    /// Selected languages left out of the current recording because they are not on-device.
    private(set) var skippedLanguages: [String] = []

    /// True when this Mac can recognize the language without sending audio anywhere.
    static func isOnDevice(_ id: String) -> Bool {
        SFSpeechRecognizer(locale: AppSettings.locale(for: id))?.supportsOnDeviceRecognition ?? false
    }

    nonisolated static func displayName(_ id: String) -> String {
        AppSettings.languageOptions.first { $0.id == id }?.label ?? id
    }

    /// A pause this long ends the current phrase.
    static let pauseLength: TimeInterval = 0.7
    /// If the recognizers have not finalized a phrase this long after a pause, keep what they have.
    static let finalizeTimeout: TimeInterval = 3
    /// After the user stops, keep listening until the recognizer has been quiet this long, so the
    /// last words are not cut off.
    static let settleQuiet: TimeInterval = 0.9
    static let settleLimit: TimeInterval = 3

    /// One recognizer per selected language, each with its result for the current phrase.
    private struct Lane {
        let language: String
        let recognizer: SFSpeechRecognizer
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence: Float = 0
        var done = false
    }

    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var lanes: [Lane] = []
    /// The lane whose partial text is shown live: the language of the last phrase.
    private var leading = 0
    private var hints: [String] = []
    /// Text from phrases that have been finalized.
    private var committed = ""
    private var generation = 0
    private var lastChange = Date()
    private var stopping = false
    private var finalReceived = false
    /// Set while a phrase is being finalized after a pause.
    private var closingSince: Date?
    private var monitor: Task<Void, Never>?
    private(set) var isRunning = false

    /// Everything heard so far, with a full stop at each pause and a capital after it.
    var transcript: String {
        Self.join(committed, currentText)
    }

    /// True when the microphone stayed silent the whole time (muted or wrong device).
    var heardNothing: Bool { box.peak() < RequestBox.quietLevel }

    private var currentText: String {
        guard lanes.indices.contains(leading) else { return "" }
        let shown = lanes[leading].text
        return shown.isEmpty ? (lanes.first { !$0.text.isEmpty }?.text ?? "") : shown
    }

    /// - Parameters:
    ///   - languages: locale identifiers to recognize, for example ["en-US", "fr-FR"].
    ///   - hints: words the recognizer should expect (names, jargon).
    func start(languages: [String], hints: [String]) throws {
        guard AVCaptureDevice.default(for: .audio) != nil else { throw DictationError.noMicrophone }

        skippedLanguages = []
        lanes = languages.compactMap { id in
            guard let recognizer = SFSpeechRecognizer(locale: AppSettings.locale(for: id)), recognizer.isAvailable else {
                return nil
            }
            guard recognizer.supportsOnDeviceRecognition else {
                skippedLanguages.append(id)
                return nil
            }
            return Lane(language: id, recognizer: recognizer)
        }
        guard !lanes.isEmpty else {
            if !skippedLanguages.isEmpty { throw DictationError.notOnDevice(languages: skippedLanguages) }
            throw DictationError.recognizerUnavailable
        }
        for lane in lanes {
            AppLog.write("recognizing \(lane.language) on this Mac")
        }

        self.hints = hints
        leading = 0
        committed = ""
        generation = 0
        stopping = false
        finalReceived = false
        closingSince = nil
        lastChange = Date()
        box.reset()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let box = self.box
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.audioEngine(error.localizedDescription)
        }

        isRunning = true
        startPhrase()
        monitor = Task { @MainActor [weak self] in
            while let self, self.isRunning, !self.stopping {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.checkPause()
            }
        }
    }

    /// Stops the microphone, waits for the last phrase to settle, and returns the full text.
    func stop() async -> String {
        guard isRunning else { return transcript }
        stopping = true
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.endAudio()

        let deadline = Date().addingTimeInterval(Self.settleLimit)
        while !finalReceived, Date() < deadline {
            let quiet = Date().timeIntervalSince(lastChange) >= Self.settleQuiet
            if quiet, !transcript.isEmpty, lanes.count == 1 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !finalReceived { finishPhrase() }
        let result = transcript
        teardown()
        return result
    }

    /// Stops without keeping anything (used when the shortcut turns out to be another command).
    func cancel() {
        guard isRunning else { return }
        stopping = true
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.endAudio()
        committed = ""
        teardown()
    }

    /// Ends the current phrase when the microphone has been quiet long enough after some speech.
    private func checkPause() {
        if let closingSince {
            // The recognizers normally finalize within a moment; if not, keep the best partial.
            if Date().timeIntervalSince(closingSince) > Self.finalizeTimeout {
                AppLog.write("phrase \(generation) did not finalize; keeping its partial text")
                finishPhrase()
            }
            return
        }
        guard !currentText.isEmpty, box.quiet() >= Self.pauseLength else { return }
        AppLog.write("pause detected after \(currentText.count) characters; finalizing phrase \(generation)")
        closingSince = Date()
        box.endAudio()
    }

    /// Begins a new phrase: one recognition request per language, all fed the same audio.
    private func startPhrase() {
        generation += 1
        let phrase = generation
        var requests: [SFSpeechAudioBufferRecognitionRequest] = []
        for index in lanes.indices {
            lanes[index].task?.cancel()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Adds commas, full stops and question marks inside a phrase.
            request.addsPunctuation = true
            request.contextualStrings = hints
            // Never fall back to Apple's servers.
            request.requiresOnDeviceRecognition = true
            lanes[index].text = ""
            lanes[index].confidence = 0
            lanes[index].done = false
            lanes[index].task = lanes[index].recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let segments = result?.bestTranscription.segments ?? []
                let confidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                let failed = error != nil
                Task { @MainActor in
                    self?.receive(phrase: phrase, lane: index, text: text, isFinal: isFinal,
                                  confidence: confidence, failed: failed)
                }
            }
            requests.append(request)
        }
        closingSince = nil
        box.set(requests)
    }

    private func receive(phrase: Int, lane: Int, text: String?, isFinal: Bool, confidence: Float, failed: Bool) {
        guard isRunning, phrase == generation, lanes.indices.contains(lane) else { return }

        if let text, text != lanes[lane].text {
            lanes[lane].text = text
            lastChange = Date()
            onPartial?(transcript)
        }
        if isFinal {
            lanes[lane].confidence = confidence
        }
        guard isFinal || failed else { return }
        lanes[lane].done = true

        // A phrase is finished once every language has given its final answer.
        if lanes.allSatisfy(\.done) {
            finishPhrase()
        }
    }

    /// Keeps the most confident language's text for this phrase and starts the next one.
    private func finishPhrase() {
        let candidates = lanes.indices.filter { !lanes[$0].text.isEmpty }
        if let best = candidates.max(by: { lanes[$0].confidence < lanes[$1].confidence
                                           || (lanes[$0].confidence == lanes[$1].confidence && $1 == leading) }) {
            if lanes.count > 1 {
                AppLog.write("phrase \(generation): kept \(lanes[best].language) (confidence \(String(format: "%.2f", lanes[best].confidence)))")
            }
            committed = Self.join(committed, lanes[best].text)
            leading = best
        }
        AppLog.write("phrase \(generation) kept: \(committed.count) characters")
        for index in lanes.indices { lanes[index].text = "" }

        if stopping {
            finalReceived = true
        } else {
            startPhrase()
        }
    }

    private func teardown() {
        monitor?.cancel()
        monitor = nil
        for index in lanes.indices {
            lanes[index].task?.cancel()
            lanes[index].task = nil
        }
        box.set([])
        isRunning = false
    }

    /// Joins two pieces of text. A pause is a sentence break: a full stop is added after the
    /// earlier piece if it has none, and the next piece starts with a capital letter.
    nonisolated static func join(_ earlier: String, _ later: String) -> String {
        let left = earlier.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = later.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        var head = left
        if let last = head.last, ",;:-".contains(last) {
            head.removeLast()
            head = head.trimmingCharacters(in: .whitespaces)
        }
        if let last = head.last, !".!?".contains(last) {
            head += "."
        }
        let capitalized = right.prefix(1).uppercased() + right.dropFirst()
        return head + " " + capitalized
    }
}

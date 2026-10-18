import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes one stream of audio to a file, from whichever thread delivers it, and tracks how loud
/// and how recent that audio is.
final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private let started: Date
    private(set) var firstSoundOffset: TimeInterval?
    private var lastLoud = Date()
    private(set) var failure: String?
    private var buffers = 0

    /// Above this RMS level the stream counts as someone talking.
    static let loudLevel: Float = 0.01

    init(url: URL, started: Date) {
        self.url = url
        self.started = started
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                firstSoundOffset = Date().timeIntervalSince(started)
            }
            try file?.write(from: buffer)
        } catch {
            failure = error.localizedDescription
        }
        if Self.rms(buffer) >= Self.loudLevel { lastLoud = Date() }
    }

    /// Seconds since this stream last had speech-level sound.
    func quietFor() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastLoud)
    }

    func close() {
        lock.lock()
        file = nil  // AVAudioFile finishes writing when released
        lock.unlock()
    }

    var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }

    var hasAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstSoundOffset != nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

/// Records a meeting as two files: the microphone (the user) and the Mac's sound output (the
/// other participants), through ScreenCaptureKit with ClankerTyper's own sounds left out.
/// On speakers the microphone also hears the call; those echoes are removed from the transcript
/// (`Meeting.removingEchoes`). Apple's voice-processing echo cancellation was tried and dropped:
/// on some Macs it fails to start or delivers no audio, and leaves the microphone unusable.
@MainActor
final class MeetingRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case screenRecordingNeeded
        case microphone(String)
        case systemAudio(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingNeeded:
                return "To hear the other people in the call, allow ClankerTyper under Screen Recording in System Settings → Privacy & Security, then restart it."
            case .microphone(let message):
                return "The microphone could not start: \(message)"
            case .systemAudio(let message):
                return "The call audio could not be recorded: \(message)"
            }
        }
    }

    struct Result {
        let micOffset: TimeInterval
        let systemOffset: TimeInterval
        let duration: TimeInterval
        let hasMic: Bool
        let hasSystem: Bool
    }

    private var engine = AVAudioEngine()
    private var stream: SCStream?
    private var micWriter: AudioFileWriter?
    private var systemWriter: AudioFileWriter?
    private let audioQueue = DispatchQueue(label: "ClankerTyper.meeting-audio")
    private var started = Date()
    private(set) var isRecording = false

    /// Seconds since either side last spoke.
    var quietFor: TimeInterval {
        min(micWriter?.quietFor() ?? .infinity, systemWriter?.quietFor() ?? .infinity)
    }

    var elapsed: TimeInterval { isRecording ? Date().timeIntervalSince(started) : 0 }

    /// - Parameter appBundleID: the call app; when given and running, only its sound is
    ///   recorded, so music or a video playing elsewhere stays out of the transcript.
    func start(micURL: URL, systemURL: URL, appBundleID: String? = nil) async throws {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecorderError.screenRecordingNeeded
        }
        started = Date()
        let micWriter = AudioFileWriter(url: micURL, started: started)
        let systemWriter = AudioFileWriter(url: systemURL, started: started)
        self.micWriter = micWriter
        self.systemWriter = systemWriter

        try startMicrophone(writer: micWriter)
        do {
            try await startSystemAudio(writer: systemWriter, appBundleID: appBundleID)
        } catch {
            stopMicrophone()
            throw RecorderError.systemAudio(error.localizedDescription)
        }
        isRecording = true
        AppLog.write("meeting recording started")
    }

    func stop() async -> Result {
        let duration = Date().timeIntervalSince(started)
        stopMicrophone()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        micWriter?.close()
        systemWriter?.close()
        isRecording = false
        let result = Result(
            micOffset: micWriter?.firstSoundOffset ?? 0,
            systemOffset: systemWriter?.firstSoundOffset ?? 0,
            duration: duration,
            hasMic: micWriter?.hasAudio ?? false,
            hasSystem: systemWriter?.hasAudio ?? false
        )
        if let failure = micWriter?.failure ?? systemWriter?.failure {
            AppLog.write("meeting audio write problem: \(failure)")
        }
        AppLog.write("meeting audio buffers: mic \(micWriter?.bufferCount ?? 0), system \(systemWriter?.bufferCount ?? 0)")
        AppLog.write("meeting recording stopped after \(Int(duration)) s")
        return result
    }

    // MARK: - Microphone

    private func startMicrophone(writer: AudioFileWriter) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        AppLog.write("meeting microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.microphone(error.localizedDescription)
        }
    }

    private func stopMicrophone() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
    }

    // MARK: - The Mac's sound output

    private func startSystemAudio(writer: AudioFileWriter, appBundleID: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.systemAudio("no display found") }
        let filter: SCContentFilter
        if let appBundleID, let app = content.applications.first(where: { $0.bundleIdentifier == appBundleID }) {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            AppLog.write("meeting audio: recording only \(app.applicationName)")
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            AppLog.write("meeting audio: recording all of the Mac's sound")
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Audio only: keep the unused video as small and rare as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SystemAudioOutput(writer: writer)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        systemOutput = output
    }

    /// Kept alive for as long as the stream runs.
    private var systemOutput: SystemAudioOutput?
}

/// Receives the Mac's sound from ScreenCaptureKit and writes it to the file.
private final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AudioFileWriter

    init(writer: AudioFileWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        writer.write(buffer)
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var streamDescription = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

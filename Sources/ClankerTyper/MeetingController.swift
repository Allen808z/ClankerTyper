import AppKit
import SwiftUI

extension AppSettings {
    /// Offer to record when a call starts.
    static var meetingOffers: Bool {
        get { defaults.object(forKey: Key.meetingOffers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.meetingOffers) }
    }

    /// Language meetings are transcribed in. Defaults to the first dictation language.
    static var meetingLanguage: String {
        get {
            let stored = defaults.string(forKey: Key.meetingLanguage) ?? ""
            return languageOptions.contains { $0.id == stored } ? stored : (dictationLanguages.first ?? "en-US")
        }
        set { defaults.set(newValue, forKey: Key.meetingLanguage) }
    }

    /// Keep the two recordings after transcribing. Off deletes them once the summary is ready.
    static var keepMeetingAudio: Bool {
        get { defaults.object(forKey: Key.keepMeetingAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.keepMeetingAudio) }
    }
}

/// Records meetings and turns them into transcripts and summaries, all on this Mac.
/// Flow: a call starts → offer (or the user starts it) → record both sides → stop (button, the
/// call app quits, or five quiet minutes) → transcribe → summarize → saved in Meetings.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case offer(app: String)
        case recording(app: String?)
        case processing(String)
        case done(Meeting.ID)
        case failed(String, Meeting.ID?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Language model downloads in progress, by locale identifier.
    @Published private(set) var downloading: Set<String> = []

    let store: MeetingStore
    var onOpenMeeting: ((Meeting.ID) -> Void)?
    /// Asked before recording, so ClankerTyper's own dictation is not mistaken for a call.
    var isDictating: (() -> Bool)?

    private let recorder = MeetingRecorder()
    private let watcher = CallWatcher()
    private lazy var panel = MeetingPanelController(controller: self)
    private var activeID: Meeting.ID?
    private var callAppBundleID: String?
    private var offer: (app: String, bundleID: String?)?
    private var ticker: Timer?
    private var hideTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    /// Stop on its own after this long with nobody talking on either side.
    static let quietLimit: TimeInterval = 5 * 60

    init(store: MeetingStore) {
        self.store = store
        watcher.isOwnMicrophoneActive = { [weak self] in
            (self?.recorder.isRecording ?? false) || (self?.isDictating?() ?? false)
        }
        watcher.onCallStarted = { [weak self] app, bundleID in self?.offerToRecord(app: app, bundleID: bundleID) }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.recorder.isRecording, let id = self.callAppBundleID,
                      app?.bundleIdentifier == id else { return }
                AppLog.write("the call app quit; stopping the meeting recording")
                self.stop()
            }
        }
    }

    var isRecording: Bool { recorder.isRecording }

    /// Follows the "offer to record" setting.
    func applySettings() {
        AppSettings.meetingOffers ? watcher.start() : watcher.stop()
    }

    // MARK: - Offer

    private func offerToRecord(app: String, bundleID: String?) {
        guard AppSettings.meetingOffers, !recorder.isRecording else { return }
        if case .processing = phase { return }
        offer = (app, bundleID)
        phase = .offer(app: app)
        panel.show()
        scheduleHide(after: 30)
    }

    func acceptOffer() {
        let chosen = offer
        offer = nil
        Task { await start(app: chosen?.app, bundleID: chosen?.bundleID) }
    }

    func dismiss() {
        hideTask?.cancel()
        offer = nil
        if !recorder.isRecording { phase = .idle }
        panel.hide()
    }

    // MARK: - Recording

    func start(app: String? = nil, bundleID: String? = nil) async {
        guard !recorder.isRecording else { return }
        hideTask?.cancel()
        let title = app.map { "\($0) call" } ?? "Meeting"
        let meeting = store.create(title: title, language: AppSettings.meetingLanguage, appName: app)
        do {
            try await recorder.start(micURL: store.audioURL(for: meeting.id, speaker: .me),
                                     systemURL: store.audioURL(for: meeting.id, speaker: .others),
                                     appBundleID: bundleID)
        } catch {
            store.delete(meeting.id)
            phase = .failed(error.localizedDescription, nil)
            panel.show()
            scheduleHide(after: 15)
            return
        }
        activeID = meeting.id
        callAppBundleID = bundleID
        phase = .recording(app: app)
        elapsed = 0
        panel.show()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        elapsed = recorder.elapsed
        if recorder.quietFor > Self.quietLimit {
            AppLog.write("five quiet minutes; stopping the meeting recording")
            stop()
        }
    }

    func stop() {
        guard recorder.isRecording, let id = activeID else { return }
        ticker?.invalidate()
        ticker = nil
        activeID = nil
        callAppBundleID = nil
        phase = .processing("Transcribing…")
        Task {
            let result = await recorder.stop()
            guard var meeting = store.meeting(id) else { return }
            meeting.duration = result.duration
            meeting.micOffset = result.micOffset
            meeting.systemOffset = result.systemOffset
            meeting.status = .transcribing
            store.update(meeting)
            await process(id)
        }
    }

    // MARK: - Transcribe and summarize

    /// Transcribes both recordings, lines them up, and summarizes. Also used for "Transcribe again".
    func process(_ id: Meeting.ID) async {
        guard var meeting = store.meeting(id) else { return }
        phase = .processing("Transcribing…")
        panel.show()
        meeting.status = .transcribing
        meeting.failure = nil
        store.update(meeting)

        guard await MeetingTranscriber.isInstalled(meeting.language) else {
            fail(id, MeetingTranscriber.TranscriptionError.notInstalled(meeting.language).localizedDescription)
            return
        }
        do {
            var mine: [MeetingSegment] = []
            var theirs: [MeetingSegment] = []
            let micURL = store.audioURL(for: id, speaker: .me)
            let systemURL = store.audioURL(for: id, speaker: .others)
            if FileManager.default.fileExists(atPath: micURL.path) {
                mine = try await MeetingTranscriber.transcribe(micURL, speaker: .me, language: meeting.language)
                    .map { Self.shifted($0, by: meeting.micOffset) }
            }
            if FileManager.default.fileExists(atPath: systemURL.path) {
                theirs = try await MeetingTranscriber.transcribe(systemURL, speaker: .others, language: meeting.language)
                    .map { Self.shifted($0, by: meeting.systemOffset) }
            }
            let languages = [meeting.language]
            meeting.segments = Meeting.joinFragments(
                Meeting.merge(Meeting.removingEchoes(mine, heard: theirs), theirs),
                isOrdinaryLowercaseWord: { SpellCheck.isOrdinaryWord($0, languages: languages) }
            )
        } catch {
            fail(id, error.localizedDescription)
            return
        }

        guard !meeting.segments.isEmpty else {
            meeting.status = .ready
            meeting.failure = "No speech was heard in this recording."
            store.update(meeting)
            finish(id)
            return
        }
        meeting.status = .summarizing
        store.update(meeting)
        await summarize(&meeting)
        store.update(meeting)
        if !AppSettings.keepMeetingAudio, meeting.status == .ready { store.deleteAudio(id) }
        finish(id)
    }

    /// "Summarize again" from the meeting page.
    func resummarize(_ id: Meeting.ID) async {
        guard var meeting = store.meeting(id), !meeting.segments.isEmpty else { return }
        meeting.status = .summarizing
        store.update(meeting)
        phase = .processing("Summarizing…")
        panel.show()
        await summarize(&meeting)
        store.update(meeting)
        finish(id)
    }

    private func summarize(_ meeting: inout Meeting) async {
        phase = .processing("Summarizing…")
        let language: Rewriter.Language = meeting.language.hasPrefix("fr") ? .french : .english
        do {
            meeting.summary = try await MeetingSummarizer().summarize(meeting.segments, language: language) { [weak self] message in
                self?.phase = .processing(message)
            }
            meeting.status = .ready
            meeting.failure = nil
        } catch {
            // The transcript is still useful without a summary.
            meeting.status = .ready
            meeting.failure = "The summary could not be made: \(error.localizedDescription)"
            AppLog.write("meeting summary failed: \(error.localizedDescription)")
        }
    }

    private func fail(_ id: Meeting.ID, _ message: String) {
        guard var meeting = store.meeting(id) else { return }
        meeting.status = .failed
        meeting.failure = message
        store.update(meeting)
        AppLog.write("meeting processing failed: \(message)")
        phase = .failed(message, id)
        panel.show()
        scheduleHide(after: 20)
    }

    private func finish(_ id: Meeting.ID) {
        phase = .done(id)
        panel.show()
        scheduleHide(after: 12)
    }

    func open(_ id: Meeting.ID) {
        dismiss()
        onOpenMeeting?(id)
    }

    /// Downloads Apple's on-device transcription model for a language (only the model is
    /// downloaded; nothing is sent).
    func download(_ language: String) async {
        downloading.insert(language)
        defer { downloading.remove(language) }
        do {
            try await MeetingTranscriber.install(language)
        } catch {
            AppLog.write("model download failed: \(error.localizedDescription)")
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.recorder.isRecording else { return }
            if case .processing = self.phase { return }
            self.dismiss()
        }
    }

    private static func shifted(_ segment: MeetingSegment, by offset: TimeInterval) -> MeetingSegment {
        var moved = segment
        moved.start += offset
        moved.end += offset
        return moved
    }
}

// MARK: - Floating panel

/// The small panel at the top right of the screen: the offer, the recording timer with Stop,
/// progress, and the result. It never takes focus from the call.
@MainActor
final class MeetingPanelController {
    private unowned let controller: MeetingController
    private var panel: NSPanel?

    init(controller: MeetingController) {
        self.controller = controller
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSRect(x: 0, y: 0, width: 340, height: 96)
        let panel = NonActivatingPanel(contentRect: size, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = FirstClickHostingView(rootView: MeetingPanelView(controller: controller))
        hosting.frame = size
        panel.contentView = hosting
        return panel
    }
}

private struct MeetingPanelView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .idle:
                EmptyView()
            case .offer(let app):
                Text("\(app) is using your microphone. Record and summarize this call?")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Let everyone know you're recording.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button("Not now") { controller.dismiss() }
                    Button("Record") { controller.acceptOffer() }
                        .buttonStyle(.borderedProminent)
                }
            case .recording(let app):
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("Recording\(app.map { " · \($0)" } ?? "")")
                        .font(.system(size: 13, weight: .semibold))
                    Text(Meeting.clock(controller.elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button("Stop") { controller.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                Text("Both sides of the call, recorded and transcribed on this Mac.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            case .processing(let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.system(size: 13, weight: .semibold))
                }
                Text("This happens on your Mac and can take a moment.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            case .done(let id):
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Meeting notes are ready").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Close") { controller.dismiss() }
                    Button("Open") { controller.open(id) }
                        .buttonStyle(.borderedProminent)
                }
            case .failed(let message, let id):
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { controller.dismiss() }
                    if let id {
                        Button("Open") { controller.open(id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 340, height: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.1).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
    }
}

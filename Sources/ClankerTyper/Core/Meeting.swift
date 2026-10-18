import Foundation

/// One line of a meeting transcript.
struct MeetingSegment: Codable, Equatable, Identifiable {
    enum Speaker: String, Codable {
        /// The user's microphone.
        case me
        /// The Mac's sound output: the other people in the call.
        case others

        var label: String {
            switch self {
            case .me: return "You"
            case .others: return "Others"
            }
        }
    }

    var id = UUID()
    var speaker: Speaker
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct ActionItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

struct MeetingSummary: Codable, Equatable {
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
}

struct Meeting: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case recording, transcribing, summarizing, ready, failed
    }

    var id = UUID()
    var title: String
    var started: Date
    var duration: TimeInterval = 0
    /// Locale identifier used for transcription, for example "en-US".
    var language: String
    /// The call app it was recorded from, when known.
    var appName: String?
    var status: Status = .recording
    var segments: [MeetingSegment] = []
    var summary: MeetingSummary?
    /// False once the user deletes the recording to save space; the transcript stays.
    var hasAudio = true
    var failure: String?
    /// When each recording's first sound arrived, in seconds after the meeting started, so the
    /// two transcripts line up.
    var micOffset: TimeInterval = 0
    var systemOffset: TimeInterval = 0

    init(title: String, started: Date, language: String, appName: String?) {
        self.title = title
        self.started = started
        self.language = language
        self.appName = appName
    }

    /// Fields added later are optional on disk, so older meeting files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        started = try c.decode(Date.self, forKey: .started)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en-US"
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .ready
        segments = try c.decodeIfPresent([MeetingSegment].self, forKey: .segments) ?? []
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        micOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .micOffset) ?? 0
        systemOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .systemOffset) ?? 0
    }

    /// "[12:05] You: …" lines, in time order.
    var transcriptText: String {
        segments.map { "[\(Self.clock($0.start))] \($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }

    /// The whole meeting as Markdown, for copying or saving.
    var markdown: String {
        var lines = ["# \(title)", ""]
        let date = started.formatted(date: .long, time: .shortened)
        lines.append("\(date) · \(Self.clock(duration))" + (appName.map { " · \($0)" } ?? ""))
        let h = Self.headings(french: language.hasPrefix("fr"))
        if let summary {
            lines += ["", "## \(h.summary)", "", summary.overview]
            if !summary.keyPoints.isEmpty { lines += ["", "## \(h.keyPoints)", ""] + summary.keyPoints.map { "- \($0)" } }
            if !summary.decisions.isEmpty { lines += ["", "## \(h.decisions)", ""] + summary.decisions.map { "- \($0)" } }
            if !summary.actionItems.isEmpty {
                lines += ["", "## \(h.actions)", ""] + summary.actionItems.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
            }
        }
        if !segments.isEmpty { lines += ["", "## \(h.transcript)", "", transcriptText] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Section titles in the meeting's language.
    static func headings(french: Bool) -> (summary: String, keyPoints: String, decisions: String, actions: String, transcript: String) {
        french
            ? ("Résumé", "Points clés", "Décisions", "Actions", "Transcription")
            : ("Summary", "Key points", "Decisions", "Action items", "Transcript")
    }

    /// 65 -> "1:05", 3725 -> "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Rejoins pieces of one sentence that the speech engine split at a comma or a short pause:
    /// same speaker, less than `gap` seconds apart, and the earlier piece does not end a sentence.
    /// The capital the engine gave the second piece is dropped only for an ordinary word
    /// ("We" becomes "we"; "I" and "Priya" stay).
    static func joinFragments(_ segments: [MeetingSegment], gap: TimeInterval = 1.2,
                              isOrdinaryLowercaseWord: (String) -> Bool) -> [MeetingSegment] {
        var joined: [MeetingSegment] = []
        for segment in segments {
            if var last = joined.last, last.speaker == segment.speaker,
               segment.start - last.end < gap,
               let end = last.text.last, !".!?…".contains(end) {
                var next = segment.text
                let firstWord = String(next.prefix { $0.isLetter })
                if firstWord.count > 1, firstWord.first?.isUppercase == true,
                   firstWord.dropFirst().allSatisfy(\.isLowercase),
                   isOrdinaryLowercaseWord(firstWord.lowercased()) {
                    next = next.prefix(1).lowercased() + next.dropFirst()
                }
                last.text += " " + next
                last.end = segment.end
                joined[joined.count - 1] = last
            } else {
                joined.append(segment)
            }
        }
        return joined
    }

    /// On speakers, the microphone also hears the other people. Drops "You" lines that repeat an
    /// "Others" line at about the same time with mostly the same words.
    static func removingEchoes(_ mine: [MeetingSegment], heard theirs: [MeetingSegment],
                               slack: TimeInterval = 1.5, sameWords: Double = 0.6) -> [MeetingSegment] {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init))
        }
        return mine.filter { segment in
            let own = words(segment.text)
            guard !own.isEmpty else { return false }
            return !theirs.contains { other in
                other.start - slack <= segment.end && segment.start <= other.end + slack
                    && Double(own.intersection(words(other.text)).count) / Double(own.count) >= sameWords
            }
        }
    }

    /// Puts both speakers' lines into one transcript ordered by time.
    static func merge(_ mine: [MeetingSegment], _ theirs: [MeetingSegment]) -> [MeetingSegment] {
        (mine + theirs).sorted { $0.start == $1.start ? $0.speaker == .others : $0.start < $1.start }
    }
}

/// Meetings on disk: Application Support/ClankerTyper/Meetings/<id>/, with meeting.json and the
/// two recordings (me.caf, others.caf).
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    static func defaultDirectory() -> URL {
        ClankerTyperStore.defaultDirectory().appendingPathComponent("Meetings", isDirectory: true)
    }

    func folder(for id: Meeting.ID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for id: Meeting.ID, speaker: MeetingSegment.Speaker) -> URL {
        folder(for: id).appendingPathComponent(speaker == .me ? "me.caf" : "others.caf")
    }

    func meeting(_ id: Meeting.ID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    @discardableResult
    func create(title: String, language: String, appName: String?) -> Meeting {
        let meeting = Meeting(title: title, started: Date(), language: language, appName: appName)
        try? FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
        meetings.insert(meeting, at: 0)
        save(meeting)
        return meeting
    }

    func update(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        save(meeting)
    }

    func delete(_ id: Meeting.ID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        meetings.removeAll { $0.id == id }
    }

    /// Removes the recordings but keeps the transcript and summary.
    func deleteAudio(_ id: Meeting.ID) {
        for speaker in [MeetingSegment.Speaker.me, .others] {
            try? FileManager.default.removeItem(at: audioURL(for: id, speaker: speaker))
        }
        guard var meeting = meeting(id) else { return }
        meeting.hasAudio = false
        update(meeting)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
                  var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            // Still "recording" or "transcribing" means the app stopped half-way (a crash or a
            // restart). Keep the audio and let the user transcribe it again.
            if meeting.status == .recording || meeting.status == .transcribing || meeting.status == .summarizing {
                meeting.status = .failed
                meeting.failure = "ClankerTyper was closed before this meeting was finished."
            }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.started > $1.started }
    }

    private func save(_ meeting: Meeting) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
            try encoder.encode(meeting).write(to: folder(for: meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            AppLog.write("could not save meeting: \(error.localizedDescription)")
        }
    }
}

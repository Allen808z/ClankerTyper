import Foundation
import Testing
@testable import ClankerTyper

@Suite("Meetings on disk")
@MainActor
struct MeetingStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clanker-meetings-\(UUID().uuidString)")
    }

    @Test func survivesRelaunch() {
        let dir = temporaryDirectory()
        let store = MeetingStore(directory: dir)
        var meeting = store.create(title: "Weekly sync", language: "en-US", appName: "Zoom")
        meeting.status = .ready
        meeting.segments = [MeetingSegment(speaker: .me, start: 1, end: 3, text: "Hi all")]
        store.update(meeting)

        let reopened = MeetingStore(directory: dir)
        #expect(reopened.meetings.map(\.title) == ["Weekly sync"])
        #expect(reopened.meetings.first?.segments.first?.text == "Hi all")
        #expect(reopened.meetings.first?.status == .ready)
    }

    @Test func unfinishedMeetingIsMarkedForRetry() {
        let dir = temporaryDirectory()
        let store = MeetingStore(directory: dir)
        store.create(title: "Cut off", language: "en-US", appName: nil)  // still "recording"
        let reopened = MeetingStore(directory: dir)
        #expect(reopened.meetings.first?.status == .failed)
        #expect(reopened.meetings.first?.hasAudio == true)
    }

    @Test func deletingRemovesTheFolder() {
        let dir = temporaryDirectory()
        let store = MeetingStore(directory: dir)
        let meeting = store.create(title: "Gone", language: "en-US", appName: nil)
        let folder = store.folder(for: meeting.id)
        store.delete(meeting.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(store.meetings.isEmpty)
    }
}

@Suite("Meeting transcript and export")
struct MeetingFormatTests {
    @Test func mergesSpeakersInTimeOrder() {
        let mine = [MeetingSegment(speaker: .me, start: 5, end: 7, text: "Sounds good")]
        let theirs = [MeetingSegment(speaker: .others, start: 1, end: 4, text: "Shall we start?"),
                      MeetingSegment(speaker: .others, start: 9, end: 10, text: "Great")]
        #expect(Meeting.merge(mine, theirs).map(\.text) == ["Shall we start?", "Sounds good", "Great"])
    }

    @Test func rejoinsASentenceSplitAtAComma() {
        let pieces = [
            MeetingSegment(speaker: .others, start: 5, end: 7, text: "If QA passes on Wednesday night,"),
            MeetingSegment(speaker: .others, start: 7, end: 9, text: "We ship on Thursday."),
            MeetingSegment(speaker: .others, start: 9, end: 11, text: "Otherwise, we push to Monday."),
            MeetingSegment(speaker: .me, start: 11.2, end: 12, text: "OK."),
        ]
        let joined = Meeting.joinFragments(pieces, isOrdinaryLowercaseWord: { ["we", "thanks"].contains($0) })
        #expect(joined.map(\.text) == ["If QA passes on Wednesday night, we ship on Thursday.", "Otherwise, we push to Monday.", "OK."])
        #expect(joined.first?.end == 9)
    }

    @Test func keepsNamesAndIAfterAJoin() {
        let pieces = [MeetingSegment(speaker: .me, start: 0, end: 1, text: "Thanks"),
                      MeetingSegment(speaker: .me, start: 1.1, end: 2, text: "I agree with Priya.")]
        #expect(Meeting.joinFragments(pieces, isOrdinaryLowercaseWord: { ["we"].contains($0) }).first?.text == "Thanks I agree with Priya.")
        let named = [MeetingSegment(speaker: .others, start: 0, end: 1, text: "Over to you,"),
                     MeetingSegment(speaker: .others, start: 1.1, end: 2, text: "Priya.")]
        #expect(Meeting.joinFragments(named, isOrdinaryLowercaseWord: { ["we"].contains($0) }).first?.text == "Over to you, Priya.")
    }

    @Test func dropsTheMicrophonesEchoOfTheCall() {
        let theirs = [MeetingSegment(speaker: .others, start: 10, end: 13, text: "We ship on Thursday if QA passes.")]
        let mine = [
            MeetingSegment(speaker: .me, start: 10.4, end: 13.2, text: "we ship on Thursday if QA passes"),  // echo
            MeetingSegment(speaker: .me, start: 14, end: 15, text: "Sounds good to me."),                   // real
            MeetingSegment(speaker: .me, start: 40, end: 42, text: "We ship on Thursday."),                 // later, said by the user
        ]
        #expect(Meeting.removingEchoes(mine, heard: theirs).map(\.text) == ["Sounds good to me.", "We ship on Thursday."])
    }

    @Test func clockFormats() {
        #expect(Meeting.clock(65) == "1:05")
        #expect(Meeting.clock(3725) == "1:02:05")
    }

    @Test func markdownHasSummaryChecklistAndTranscript() {
        var meeting = Meeting(title: "Launch", started: Date(timeIntervalSince1970: 0), language: "en-US", appName: "Zoom")
        meeting.duration = 600
        meeting.segments = [MeetingSegment(speaker: .others, start: 2, end: 4, text: "Let's ship Thursday.")]
        meeting.summary = MeetingSummary(overview: "We planned the launch.", keyPoints: ["Payment tests"],
                                         decisions: ["Ship Thursday"],
                                         actionItems: [ActionItem(text: "Sam runs QA", done: true)])
        let md = meeting.markdown
        #expect(md.contains("# Launch"))
        #expect(md.contains("## Decisions\n\n- Ship Thursday"))
        #expect(md.contains("- [x] Sam runs QA"))
        #expect(md.contains("[0:02] Others: Let's ship Thursday."))
    }
}

@Suite("Meeting summaries")
struct MeetingSummarizerTests {
    @Test func parsesEnglishSections() throws {
        let text = """
        SUMMARY:
        The team planned the launch.
        KEY POINTS:
        - Payment tests are not done
        - QA runs Wednesday
        DECISIONS:
        - Ship on Thursday
        ACTION ITEMS:
        - Sam: run the full QA suite
        - You: tell the client by noon
        """
        let summary = try #require(MeetingSummarizer.parse(text))
        #expect(summary.overview == "The team planned the launch.")
        #expect(summary.keyPoints == ["Payment tests are not done", "QA runs Wednesday"])
        #expect(summary.decisions == ["Ship on Thursday"])
        #expect(summary.actionItems.map(\.text) == ["Sam: run the full QA suite", "You: tell the client by noon"])
    }

    @Test func parsesFrenchWithMarkdownAndNone() throws {
        let text = """
        **RÉSUMÉ :** Réunion sur le lancement.
        ## POINTS CLÉS :
        * Les tests de paiement ne sont pas finis
        ## DÉCISIONS :
        - Aucune
        ## ACTIONS :
        - Sam : lancer les tests
        """
        let summary = try #require(MeetingSummarizer.parse(text))
        #expect(summary.overview == "Réunion sur le lancement.")
        #expect(summary.keyPoints == ["Les tests de paiement ne sont pas finis"])
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems.map(\.text) == ["Sam : lancer les tests"])
    }

    @Test func dropsActionItemsWithNoTask() throws {
        let summary = try #require(MeetingSummarizer.parse("SUMMARY:\nA sync.\nACTION ITEMS:\n- Priya: fix the tests\n- You: None\n- Sam : aucune"))
        #expect(summary.actionItems.map(\.text) == ["Priya: fix the tests"])
    }

    @Test func textWithoutSectionsIsRejected() {
        #expect(MeetingSummarizer.parse("I'm sorry, I can't help with that.") == nil)
    }

    @Test func chunksNeverSplitALine() {
        let lines = (1...10).map { "line \($0) " + String(repeating: "x", count: 20) }
        let chunks = MeetingSummarizer.chunk(lines, limit: 70)
        #expect(chunks.count == 5)
        #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
    }

    @Test func longMeetingIsSummarizedInParts() async throws {
        final class CountingModel: TextModel, @unchecked Sendable {
            var calls = 0
            func complete(instructions: String, prompt: String, timeout: TimeInterval) async throws -> String {
                calls += 1
                return "SUMMARY:\nPart notes.\nKEY POINTS:\n- A point\nDECISIONS:\n- None\nACTION ITEMS:\n- None"
            }
            func warmUp() {}
        }
        let model = CountingModel()
        let segments = (0..<400).map { MeetingSegment(speaker: .others, start: Double($0), end: Double($0) + 1,
                                                       text: "We talked about item number \($0) in some detail.") }
        let summary = try await MeetingSummarizer(model: model).summarize(segments, language: .english)
        #expect(summary.keyPoints == ["A point"])
        #expect(model.calls > 2)  // several parts, then at least one combining step
    }
}

@Suite("Noticing calls")
struct CallWatcherTests {
    @Test func callAppsInFront() {
        #expect(CallWatcher.callName(frontmostBundleID: "us.zoom.xos", frontWindowTitle: nil) == "Zoom")
        #expect(CallWatcher.callName(frontmostBundleID: "com.apple.FaceTime", frontWindowTitle: nil) == "FaceTime")
    }

    @Test func browserOnAMeetingPage() {
        #expect(CallWatcher.callName(frontmostBundleID: "com.google.Chrome", frontWindowTitle: "Meet - abc-defg-hij") == "Google Meet")
        #expect(CallWatcher.callName(frontmostBundleID: "com.apple.Safari", frontWindowTitle: "Weekly sync | Microsoft Teams") == "Microsoft Teams")
    }

    @Test func otherAppsAndPagesAreNotCalls() {
        #expect(CallWatcher.callName(frontmostBundleID: "com.google.Chrome", frontWindowTitle: "Inbox - Gmail") == nil)
        #expect(CallWatcher.callName(frontmostBundleID: "com.apple.Notes", frontWindowTitle: "Notes") == nil)
        #expect(CallWatcher.callName(frontmostBundleID: nil, frontWindowTitle: nil) == nil)
    }
}

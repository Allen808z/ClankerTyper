import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Meetings in the main window: the list on the left, the chosen meeting's notes on the right.
struct MeetingsPage: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var store: MeetingStore
    @Binding var selection: Meeting.ID?
    @AppStorage(AppSettings.Key.meetingLanguage) private var languageRaw = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Meetings").font(.system(size: 22, weight: .bold))
                recordButton
                Picker("Language", selection: Binding(
                    get: { _ = languageRaw; return AppSettings.meetingLanguage },
                    set: { AppSettings.meetingLanguage = $0; languageRaw = $0 }
                )) {
                    ForEach(AppSettings.languageOptions, id: \.id) { Text($0.label).tag($0.id) }
                }
                .controlSize(.small)
                if store.meetings.isEmpty {
                    Text("No meetings yet. When a call starts, ClankerTyper offers to record it, or press Start recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                } else {
                    List(store.meetings, selection: $selection) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title).lineLimit(1)
                            Text("\(meeting.started.formatted(date: .abbreviated, time: .shortened)) · \(Meeting.clock(meeting.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                            if meeting.status != .ready {
                                Text(statusText(meeting)).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .tag(meeting.id)
                    }
                    .listStyle(.inset)
                }
            }
            .padding(16)
            .frame(width: 270)

            Divider()

            if let id = selection, let meeting = store.meeting(id) {
                MeetingDetail(meeting: meeting, controller: controller, store: store, selection: $selection)
            } else {
                VStack {
                    Spacer()
                    Text("Choose a meeting to see its notes.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if selection == nil { selection = store.meetings.first?.id }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if controller.isRecording {
            Button {
                controller.stop()
            } label: {
                Label("Stop recording · \(Meeting.clock(controller.elapsed))", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button {
                Task { await controller.start() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusText(_ meeting: Meeting) -> String {
        switch meeting.status {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .failed: return "Needs attention"
        case .ready: return ""
        }
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var controller: MeetingController
    @ObservedObject var store: MeetingStore
    @Binding var selection: Meeting.ID?
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var modelInstalled: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let failure = meeting.failure { problem(failure) }
                if let summary = meeting.summary { summarySection(summary) }
                if !meeting.segments.isEmpty { transcriptSection }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.id) { _, _ in title = meeting.title; modelInstalled = nil }
        .task(id: meeting.id) { modelInstalled = await MeetingTranscriber.isInstalled(meeting.language) }
        .alert("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.delete(meeting.id)
                selection = store.meetings.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording, transcript and notes are removed from this Mac.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
                .onSubmit(saveTitle)
                .onChange(of: title) { _, _ in saveTitle() }
            Text([meeting.started.formatted(date: .long, time: .shortened), Meeting.clock(meeting.duration),
                  meeting.appName, Dictation.displayName(meeting.language)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy notes") { TextInsertion.putOnClipboard(meeting.markdown) }
                Button("Export…", action: export)
                Menu("More") {
                    if !meeting.segments.isEmpty {
                        Button("Copy transcript") { TextInsertion.putOnClipboard(meeting.transcriptText) }
                        Button("Summarize again") { Task { await controller.resummarize(meeting.id) } }
                    }
                    if meeting.hasAudio {
                        Button("Transcribe again") { Task { await controller.process(meeting.id) } }
                        Button("Delete the recording, keep the notes") { store.deleteAudio(meeting.id) }
                    }
                    Divider()
                    Button("Delete meeting…", role: .destructive) { confirmDelete = true }
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
    }

    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if modelInstalled == false {
                if controller.downloading.contains(meeting.language) {
                    HStack { ProgressView().controlSize(.small); Text("Downloading the model…") }
                } else {
                    Button("Download the \(Dictation.displayName(meeting.language)) transcription model") {
                        Task {
                            await controller.download(meeting.language)
                            modelInstalled = await MeetingTranscriber.isInstalled(meeting.language)
                        }
                    }
                    Text("A one-time download from Apple. Your recordings stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if modelInstalled == true, meeting.hasAudio, meeting.status == .failed {
                Button("Transcribe now") { Task { await controller.process(meeting.id) } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summarySection(_ summary: MeetingSummary) -> some View {
        let h = Meeting.headings(french: meeting.language.hasPrefix("fr"))
        return VStack(alignment: .leading, spacing: 14) {
            block(h.summary) { Text(summary.overview).textSelection(.enabled) }
            if !summary.keyPoints.isEmpty { block(h.keyPoints) { bullets(summary.keyPoints) } }
            if !summary.decisions.isEmpty { block(h.decisions) { bullets(summary.decisions) } }
            if !summary.actionItems.isEmpty {
                block(h.actions) {
                    ForEach(summary.actionItems) { item in
                        Toggle(isOn: Binding(get: { item.done }, set: { setDone(item.id, $0) })) {
                            Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var transcriptSection: some View {
        block(Meeting.headings(french: meeting.language.hasPrefix("fr")).transcript) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(meeting.segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Meeting.clock(segment.start))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(segment.speaker.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(segment.speaker == .me ? Brand.accent : .secondary)
                            .frame(width: 46, alignment: .leading)
                        Text(segment.text).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != meeting.title, var updated = store.meeting(meeting.id) else { return }
        updated.title = trimmed
        store.update(updated)
    }

    private func setDone(_ itemID: ActionItem.ID, _ done: Bool) {
        guard var updated = store.meeting(meeting.id), var summary = updated.summary,
              let index = summary.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
        summary.actionItems[index].done = done
        updated.summary = summary
        store.update(updated)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try meeting.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.write("export failed: \(error.localizedDescription)")
        }
    }
}

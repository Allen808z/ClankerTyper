import AppKit

// Command-line check of the writing tools, without starting the app:
//   ClankerTyper --rewrite <style> "some text"   (see the usage message for the styles)
// Prints the rewritten text, or the reason it was not used.
if let flag = CommandLine.arguments.firstIndex(of: "--rewrite") {
    let args = CommandLine.arguments
    let styleName = args.count > flag + 1 ? args[flag + 1] : ""
    let text = args.count > flag + 2 ? args[flag + 2] : ""
    let styles: [String: Rewriter.Style] = [
        "dictation": .dictation, "grammar": .grammar, "improve": .improve, "shorter": .shorter,
        "formal": .formal, "friendly": .friendly, "translate": .translate, "summarize": .summarize,
    ]
    // "custom:<instruction>" and "generate:<request>" take their instruction after the colon.
    let style: Rewriter.Style?
    if styleName.hasPrefix("custom:") {
        style = .custom(String(styleName.dropFirst("custom:".count)))
    } else if styleName.hasPrefix("generate:") {
        style = .generate(String(styleName.dropFirst("generate:".count)))
    } else {
        style = styles[styleName]
    }
    guard let style, !text.isEmpty else {
        FileHandle.standardError.write(Data("usage: ClankerTyper --rewrite dictation|grammar|improve|shorter|formal|friendly|translate|summarize|custom:<instruction>|generate:<request> \"text\"\n".utf8))
        exit(2)
    }
    let showRaw = CommandLine.arguments.contains("--raw")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            if showRaw {
                // The model's own words, before any checks: for working on prompts.
                let language = Rewriter.detectLanguage(text) ?? .english
                let raw = try await Rewriter().model.complete(
                    instructions: Rewriter.instructions(style: style, language: language, wordCount: text.split(separator: " ").count),
                    prompt: Rewriter.prompt(text, language: language), timeout: 60)
                print("raw: \(raw)")
            }
            print(try await Rewriter().rewrite(text, style: style, timeout: 60))
        } catch {
            FileHandle.standardError.write(Data("not used: \(error.localizedDescription)\n".utf8))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Command-line check of meeting transcription: ClankerTyper --transcribe audio-file [en-US|fr-FR]
if let flag = CommandLine.arguments.firstIndex(of: "--transcribe") {
    let args = CommandLine.arguments
    guard args.count > flag + 1 else {
        FileHandle.standardError.write(Data("usage: ClankerTyper --transcribe audio-file [en-US|fr-FR]\n".utf8))
        exit(2)
    }
    let file = URL(fileURLWithPath: args[flag + 1])
    let language = args.count > flag + 2 ? args[flag + 2] : "en-US"
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let start = Date()
            let segments = try await MeetingTranscriber.transcribe(file, speaker: .others, language: language)
            for segment in segments { print("[\(Meeting.clock(segment.start))–\(Meeting.clock(segment.end))] \(segment.text)") }
            print(String(format: "(%d segments, %.1fs)", segments.count, Date().timeIntervalSince(start)))
        } catch {
            FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Command-line check of meeting summaries: ClankerTyper --summarize transcript.txt [fr]
// The file has lines like "[1:05] You: text" or "[1:07] Others: text".
if let flag = CommandLine.arguments.firstIndex(of: "--summarize") {
    let args = CommandLine.arguments
    guard args.count > flag + 1, let text = try? String(contentsOfFile: args[flag + 1], encoding: .utf8) else {
        FileHandle.standardError.write(Data("usage: ClankerTyper --summarize transcript.txt [fr]\n".utf8))
        exit(2)
    }
    let french = args.count > flag + 2 && args[flag + 2] == "fr"
    let segments: [MeetingSegment] = text.split(separator: "\n").compactMap { line in
        guard let close = line.firstIndex(of: "]"), let colon = line[close...].firstIndex(of: ":") else { return nil }
        let speaker = line[line.index(after: close)..<colon].trimmingCharacters(in: .whitespaces)
        let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return MeetingSegment(speaker: speaker == "You" ? .me : .others, start: 0, end: 0, text: body)
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let start = Date()
            let summary = try await MeetingSummarizer().summarize(segments, language: french ? .french : .english)
            var meeting = Meeting(title: "Test", started: Date(), language: french ? "fr-FR" : "en-US", appName: nil)
            meeting.summary = summary
            print(meeting.markdown)
            print(String(format: "(%.1fs)", Date().timeIntervalSince(start)))
        } catch {
            FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Self-test of meeting recording, run as the installed app so it has its permissions:
//   open -n /Applications/ClankerTyper.app --args --meeting-selftest 12
// Records the microphone and the Mac's sound for the given seconds, transcribes both, writes
// the result to the log and quits. Uses a temporary folder, not the user's meetings.
if let flag = CommandLine.arguments.firstIndex(of: "--meeting-selftest") {
    let args = CommandLine.arguments
    let seconds = args.count > flag + 1 ? Double(args[flag + 1]) ?? 10 : 10
    // Optional: --app <bundle id> records only that app's sound.
    let appBundleID = args.firstIndex(of: "--app").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
    MainActor.assumeIsolated {
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clanker-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let mic = dir.appendingPathComponent("me.caf")
            let system = dir.appendingPathComponent("others.caf")
            let recorder = MeetingRecorder()
            do {
                try await recorder.start(micURL: mic, systemURL: system, appBundleID: appBundleID)
            } catch {
                AppLog.write("selftest: could not start: \(error.localizedDescription)")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let result = await recorder.stop()
            AppLog.write("selftest: mic audio=\(result.hasMic) system audio=\(result.hasSystem) offsets mic=\(String(format: "%.2f", result.micOffset)) system=\(String(format: "%.2f", result.systemOffset))")
            for (url, speaker) in [(system, MeetingSegment.Speaker.others), (mic, .me)] where FileManager.default.fileExists(atPath: url.path) {
                do {
                    let segments = try await MeetingTranscriber.transcribe(url, speaker: speaker, language: "en-US")
                    AppLog.write("selftest \(speaker.label): \(segments.map(\.text).joined(separator: " "))")
                } catch {
                    AppLog.write("selftest \(speaker.label): transcription failed: \(error.localizedDescription)")
                }
            }
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
    }
    RunLoop.main.run()
}

// End-to-end check of a whole meeting, in a throwaway folder (not the user's Meetings):
//   open -n /Applications/ClankerTyper.app --args --meeting-pipeline-test 15
// Records, stops, transcribes, removes echoes, summarizes, and logs the notes' shape.
if let flag = CommandLine.arguments.firstIndex(of: "--meeting-pipeline-test") {
    let args = CommandLine.arguments
    let seconds = args.count > flag + 1 ? Double(args[flag + 1]) ?? 15 : 15
    MainActor.assumeIsolated {
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clanker-pipeline-\(UUID().uuidString)")
            let controller = MeetingController(store: MeetingStore(directory: dir))
            await controller.start(app: "Test call")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            controller.stop()
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .done = controller.phase { break }
                if case .failed = controller.phase { break }
            }
            if let meeting = controller.store.meetings.first {
                let you = meeting.segments.filter { $0.speaker == .me }.count
                let others = meeting.segments.filter { $0.speaker == .others }.count
                AppLog.write("pipeline: status \(meeting.status.rawValue), \(meeting.segments.count) lines (You \(you), Others \(others)), summary \(meeting.summary != nil), failure \(meeting.failure ?? "none")")
                AppLog.write("pipeline notes:\n\(meeting.markdown)")
            } else {
                AppLog.write("pipeline: no meeting was created (\(controller.phase))")
            }
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
    }
    RunLoop.main.run()
}

// Top-level code runs on the main thread, which is the main actor's executor.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(AppSettings.activationPolicy)
    application.run()
}

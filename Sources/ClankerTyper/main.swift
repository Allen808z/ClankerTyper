import AppKit

// Command-line check of the writing tools, without starting the app:
//   ClankerTyper --rewrite grammar|improve|dictation "some text"
// Prints the rewritten text, or the reason it was not used.
if let flag = CommandLine.arguments.firstIndex(of: "--rewrite") {
    let args = CommandLine.arguments
    let styleName = args.count > flag + 1 ? args[flag + 1] : ""
    let text = args.count > flag + 2 ? args[flag + 2] : ""
    let styles: [String: Rewriter.Style] = ["grammar": .grammar, "improve": .improve, "dictation": .dictation]
    guard let style = styles[styleName], !text.isEmpty else {
        FileHandle.standardError.write(Data("usage: ClankerTyper --rewrite grammar|improve|dictation \"text\"\n".utf8))
        exit(2)
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            print(try await Rewriter().rewrite(text, style: style, timeout: 60))
        } catch {
            FileHandle.standardError.write(Data("not used: \(error.localizedDescription)\n".utf8))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Top-level code runs on the main thread, which is the main actor's executor.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(AppSettings.activationPolicy)
    application.run()
}

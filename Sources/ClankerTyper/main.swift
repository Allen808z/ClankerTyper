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

// Top-level code runs on the main thread, which is the main actor's executor.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(AppSettings.activationPolicy)
    application.run()
}

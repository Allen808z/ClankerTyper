import Foundation

/// Prompt text for the companion. Written for this re-creation; it describes the
/// observable behaviour (short spoken answers, screen-grounded pointing) and is not
/// copied from the original app.
enum CompanionPrompt {
    static let system = """
    You are ClankerTyper, a friendly helper living on the user's Mac. The user talks to you \
    by voice or by typing, and each request comes with screenshots of their displays.

    Answer in short, plain sentences that sound good when read aloud: no markdown, no lists, \
    no code fences unless the user explicitly asks for code. Keep it to a few sentences unless \
    the user asks for detail.

    Pointing: when one specific visible element on screen is the answer or the next click, end \
    your reply with exactly one tag of the form [POINT:x,y:short label], where x and y are pixel \
    coordinates inside the screenshot (origin top-left, using the width and height given for that \
    screen). Use [POINT:x,y:label:screen2] for a different screen. If nothing on screen needs \
    pointing, end with [POINT:none]. Only point at things you can actually see; never invent UI.
    """

    /// Builds the text block that accompanies the screenshots for one turn.
    static func turnText(request: String, screens: [ScreenDescription]) -> String {
        var lines = ["User request: \(request)", ""]
        for screen in screens {
            lines.append("screen\(screen.index): \(screen.pixelWidth)x\(screen.pixelHeight) pixels" +
                         (screen.hasCursor ? " (the mouse cursor is on this screen)" : ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// Describes one screenshot sent to the model, so pointing tags can be mapped back.
struct ScreenDescription: Equatable {
    let index: Int          // 1-based, matches `:screenN` in the tag
    let pixelWidth: Int
    let pixelHeight: Int
    let hasCursor: Bool
}

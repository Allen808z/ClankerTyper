import Foundation

/// A visual target the model asked the companion to point at.
/// Coordinates are in the pixel space of the screenshot named by `screenIndex`
/// (top-left origin, 1-based screen numbering as sent in the prompt).
struct PointTarget: Equatable {
    let x: Double
    let y: Double
    let label: String?
    let screenIndex: Int?
}

struct ParsedReply: Equatable {
    /// The reply with the trailing POINT tag removed, ready to show and speak.
    let spokenText: String
    let target: PointTarget?
}

enum PointingParser {
    /// Matches a trailing `[POINT:none]` or `[POINT:x,y(:label)?(:screenN)?]`.
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#
    )

    static func parse(_ reply: String) -> ParsedReply {
        let ns = reply as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = tagPattern.firstMatch(in: reply, range: full) else {
            return ParsedReply(spokenText: reply.trimmingCharacters(in: .whitespacesAndNewlines), target: nil)
        }

        let spoken = ns.substring(to: match.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        guard let xText = group(1), let yText = group(2),
              let x = Double(xText), let y = Double(yText) else {
            // `[POINT:none]` or anything unparseable: no target.
            return ParsedReply(spokenText: spoken, target: nil)
        }

        let target = PointTarget(
            x: x,
            y: y,
            label: group(3)?.trimmingCharacters(in: .whitespaces),
            screenIndex: group(4).flatMap(Int.init)
        )
        return ParsedReply(spokenText: spoken, target: target)
    }
}

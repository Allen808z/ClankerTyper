import Foundation

/// One screenshot ready to send: its JPEG bytes plus the description used in the prompt.
struct EncodedScreen {
    let description: ScreenDescription
    let jpeg: Data
}

/// Holds the short conversation memory and turns a request plus screens into a reply.
@MainActor
final class Assistant {
    struct Exchange {
        let user: String
        let assistant: String
    }

    private(set) var exchanges: [Exchange] = []
    private let maxExchanges: Int
    private let ollama: OllamaClient

    init(maxExchanges: Int = 8, ollama: OllamaClient = OllamaClient()) {
        self.maxExchanges = maxExchanges
        self.ollama = ollama
    }

    func reset() { exchanges.removeAll() }

    /// Builds the messages for a turn without sending them. Earlier turns are text only,
    /// so screenshots are only paid for once, on the turn they were taken.
    func messages(for request: String, screens: [EncodedScreen]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for exchange in exchanges {
            messages.append(.init(role: "user", content: [.text(exchange.user)]))
            messages.append(.init(role: "assistant", content: [.text(exchange.assistant)]))
        }

        var blocks: [ChatMessage.Block] = screens.map {
            .imageJPEG(base64: $0.jpeg.base64EncodedString())
        }
        let text = CompanionPrompt.turnText(request: request, screens: screens.map(\.description))
        blocks.append(.text(text))
        messages.append(.init(role: "user", content: blocks))
        return messages
    }

    /// Sends one turn to the local vision model. The raw reply (including its POINT tag) is kept
    /// in memory so the model sees its own earlier pointing decisions.
    func reply(to request: String, screens: [EncodedScreen], host: URL, model: String) async throws -> ParsedReply {
        let raw = try await ollama.send(host: host, model: model, system: CompanionPrompt.system,
                                        messages: messages(for: request, screens: screens))
        record(Exchange(user: request, assistant: raw))
        return PointingParser.parse(raw)
    }

    /// Keeps only the most recent `maxExchanges` turns.
    func record(_ exchange: Exchange) {
        exchanges.append(exchange)
        if exchanges.count > maxExchanges {
            exchanges.removeFirst(exchanges.count - maxExchanges)
        }
    }
}

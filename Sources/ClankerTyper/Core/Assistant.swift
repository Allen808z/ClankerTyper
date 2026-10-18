import Foundation

/// One screenshot ready to send: its JPEG bytes plus the description used in the prompt.
struct EncodedScreen {
    let description: ScreenDescription
    let jpeg: Data
}

/// Where a turn is answered: the Anthropic API with a key, or a local Ollama model.
enum ModelBackend: Equatable {
    case anthropic(apiKey: String, model: String)
    case ollama(host: URL, model: String)
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
    private let client: AnthropicClient
    private let ollama: OllamaClient

    init(maxExchanges: Int = 8, client: AnthropicClient = AnthropicClient(), ollama: OllamaClient = OllamaClient()) {
        self.maxExchanges = maxExchanges
        self.client = client
        self.ollama = ollama
    }

    func reset() { exchanges.removeAll() }

    /// Builds the messages for a turn without sending them. Earlier turns are text only,
    /// so screenshots are only paid for once, on the turn they were taken.
    func messages(for request: String, screens: [EncodedScreen]) -> [AnthropicClient.Message] {
        var messages: [AnthropicClient.Message] = []
        for exchange in exchanges {
            messages.append(.init(role: "user", content: [.text(exchange.user)]))
            messages.append(.init(role: "assistant", content: [.text(exchange.assistant)]))
        }

        var blocks: [AnthropicClient.ContentBlock] = screens.map {
            .imageJPEG(base64: $0.jpeg.base64EncodedString())
        }
        let text = CompanionPrompt.turnText(request: request, screens: screens.map(\.description))
        blocks.append(.text(text))
        messages.append(.init(role: "user", content: blocks))
        return messages
    }

    /// Sends one turn. The raw reply (including its POINT tag) is kept in memory so the
    /// model sees its own earlier pointing decisions.
    func reply(to request: String, screens: [EncodedScreen], backend: ModelBackend) async throws -> ParsedReply {
        let messages = messages(for: request, screens: screens)
        let raw: String
        switch backend {
        case let .anthropic(apiKey, model):
            let urlRequest = try AnthropicClient.makeRequest(
                apiKey: apiKey,
                model: model,
                system: CompanionPrompt.system,
                maxTokens: 1024,
                messages: messages
            )
            raw = try await client.send(urlRequest)
        case let .ollama(host, model):
            raw = try await ollama.send(host: host, model: model, system: CompanionPrompt.system, messages: messages)
        }
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

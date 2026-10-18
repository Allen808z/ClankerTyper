import Foundation

/// Chat client for a local Ollama server (`POST /api/chat`). Takes the same Messages-shaped
/// turns as `AnthropicClient` so the rest of the app does not care which backend answers.
struct OllamaClient {
    static let defaultHost = URL(string: "http://localhost:11434")!

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
        let images: [String]?
    }

    enum ClientError: LocalizedError, Equatable {
        case noModel
        case notRunning
        case modelMissing(String)
        case server(status: Int, message: String)
        case emptyReply
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .noModel:
                return "Choose a local model name in Settings, for example qwen2.5vl:7b."
            case .notRunning:
                return "Ollama isn't running. Open the Ollama app, or run `ollama serve`, then try again."
            case .modelMissing(let model):
                return "Ollama doesn't have \(model) yet. Run `ollama pull \(model)` in Terminal, then try again."
            case .server(let status, let message):
                return "Ollama returned HTTP \(status): \(message)"
            case .emptyReply:
                return "The local model returned no text."
            case .malformedResponse:
                return "The local model response could not be read."
            }
        }
    }

    /// Builds the POST request. Pure: no I/O.
    static func makeRequest(host: URL, model: String, system: String,
                            messages: [AnthropicClient.Message], timeout: TimeInterval = 300) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ClientError.noModel }

        var chat = [Message(role: "system", content: system, images: nil)]
        for message in messages {
            var texts: [String] = []
            var images: [String] = []
            for block in message.content {
                switch block {
                case .text(let text): texts.append(text)
                case .imageJPEG(let base64): images.append(base64)
                }
            }
            chat.append(Message(
                role: message.role,
                content: texts.joined(separator: "\n"),
                images: images.isEmpty ? nil : images
            ))
        }

        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let stream: Bool
        }
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Local models on a laptop can be slow, especially the first request after loading.
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(Body(model: model, messages: chat, stream: false))
        return request
    }

    /// Reads the assistant text from a non-streaming `/api/chat` response.
    static func parseReply(data: Data, status: Int, model: String) throws -> String {
        struct Response: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let error: String?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ClientError.malformedResponse
        }
        if let error = decoded.error {
            if status == 404 || error.lowercased().contains("not found") {
                throw ClientError.modelMissing(model)
            }
            throw ClientError.server(status: status, message: error)
        }
        guard (200..<300).contains(status) else {
            throw ClientError.server(status: status, message: "unexpected response")
        }
        let text = (decoded.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyReply }
        return text
    }

    func send(host: URL, model: String, system: String, messages: [AnthropicClient.Message],
              timeout: TimeInterval = 300) async throws -> String {
        let request = try Self.makeRequest(host: host, model: model, system: system, messages: messages, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try Self.parseReply(data: data, status: status, model: model)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw ClientError.notRunning
        }
    }
}

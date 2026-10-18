import Foundation

/// Minimal Messages API client. Requests are built by a pure function so they can be
/// tested without network access.
struct AnthropicClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    struct Message: Encodable, Equatable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Encodable, Equatable {
        case text(String)
        case imageJPEG(base64: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageJPEG(let base64):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode("image/jpeg", forKey: .mediaType)
                try source.encode(base64, forKey: .data)
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, source }
        private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }
    }

    enum ClientError: LocalizedError, Equatable {
        case missingAPIKey
        case http(status: Int, message: String)
        case emptyReply
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Anthropic API key in ClankerTyper Settings to get answers."
            case .http(let status, let message):
                return "Anthropic returned HTTP \(status): \(message)"
            case .emptyReply:
                return "The model returned no text."
            case .malformedResponse:
                return "The model response could not be read."
            }
        }
    }

    /// Builds the POST request. Pure: no I/O.
    static func makeRequest(apiKey: String, model: String, system: String,
                            maxTokens: Int, messages: [Message]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }
        let body = Body(model: model, max_tokens: maxTokens, system: system, messages: messages)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Extracts the concatenated text blocks from a Messages API response body.
    static func parseReply(data: Data, status: Int) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct APIError: Decodable { let message: String }
            let content: [Block]?
            let error: APIError?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ClientError.malformedResponse
        }
        if let apiError = decoded.error {
            throw ClientError.http(status: status, message: apiError.message)
        }
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: "unexpected response")
        }
        let text = (decoded.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.emptyReply }
        return trimmed
    }

    func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parseReply(data: data, status: status)
    }
}

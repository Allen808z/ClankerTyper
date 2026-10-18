import Foundation
import Testing
@testable import Clanker

@Suite("Anthropic Messages API client")
struct AnthropicClientTests {
    @Test func requestHasHeadersAndBody() throws {
        let message = AnthropicClient.Message(role: "user", content: [
            .imageJPEG(base64: "AAAA"),
            .text("hi"),
        ])
        let request = try AnthropicClient.makeRequest(
            apiKey: "test-key", model: "claude-sonnet-5-5", system: "sys", maxTokens: 256, messages: [message]
        )
        #expect(request.url == AnthropicClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["system"] as? String == "sys")

        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image")
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == "AAAA")
        #expect(content[1]["text"] as? String == "hi")
    }

    @Test func missingKeyFailsBeforeNetwork() {
        #expect(throws: AnthropicClient.ClientError.missingAPIKey) {
            try AnthropicClient.makeRequest(apiKey: "", model: "m", system: "s", maxTokens: 1, messages: [])
        }
    }

    @Test func parsesConcatenatedTextBlocks() throws {
        let body = #"{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"there. [POINT:none]"}]}"#
        let text = try AnthropicClient.parseReply(data: Data(body.utf8), status: 200)
        #expect(text == "Hello there. [POINT:none]")
    }

    @Test func surfacesAPIErrorMessage() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(throws: AnthropicClient.ClientError.http(status: 401, message: "invalid x-api-key")) {
            try AnthropicClient.parseReply(data: Data(body.utf8), status: 401)
        }
    }

    @Test func emptyReplyIsAnError() {
        #expect(throws: AnthropicClient.ClientError.emptyReply) {
            try AnthropicClient.parseReply(data: Data(#"{"content":[]}"#.utf8), status: 200)
        }
    }

    @Test @MainActor func assistantKeepsOnlyRecentTextOnlyHistory() {
        let assistant = Assistant(maxExchanges: 2)
        let screen = EncodedScreen(
            description: ScreenDescription(index: 1, pixelWidth: 10, pixelHeight: 10, hasCursor: true),
            jpeg: Data([1, 2, 3])
        )
        let first = assistant.messages(for: "first", screens: [screen])
        #expect(first.count == 1)
        #expect(first[0].content.count == 2)  // image + text

        assistant.record(.init(user: "one", assistant: "a1"))
        assistant.record(.init(user: "two", assistant: "a2"))
        assistant.record(.init(user: "three", assistant: "a3"))
        #expect(assistant.exchanges.map(\.user) == ["two", "three"])

        let next = assistant.messages(for: "now", screens: [screen])
        #expect(next.count == 5)  // two text-only exchanges (two messages each) + current turn
        #expect(next[0].content == [.text("two")])
        #expect(next[1].content == [.text("a2")])
        #expect(next.last?.content.count == 2)
    }
}

@Suite("Ollama chat client")
struct OllamaClientTests {
    @Test func requestConvertsTurnsAndImagesForOllama() throws {
        let messages: [AnthropicClient.Message] = [
            .init(role: "user", content: [.imageJPEG(base64: "AAAA"), .text("what is this")]),
            .init(role: "assistant", content: [.text("a button")]),
        ]
        let request = try OllamaClient.makeRequest(
            host: OllamaClient.defaultHost, model: "qwen2.5vl:7b", system: "sys", messages: messages
        )
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen2.5vl:7b")
        #expect(json["stream"] as? Bool == false)

        let chat = try #require(json["messages"] as? [[String: Any]])
        #expect(chat.count == 3)
        #expect(chat[0]["role"] as? String == "system")
        #expect(chat[1]["content"] as? String == "what is this")
        #expect(chat[1]["images"] as? [String] == ["AAAA"])
        #expect(chat[2]["images"] == nil)
    }

    @Test func emptyModelNameIsRejected() {
        #expect(throws: OllamaClient.ClientError.noModel) {
            try OllamaClient.makeRequest(host: OllamaClient.defaultHost, model: " ", system: "s", messages: [])
        }
    }

    @Test func parsesMessageContent() throws {
        let body = #"{"message":{"role":"assistant","content":"Click Save. [POINT:10,20:save]"},"done":true}"#
        let text = try OllamaClient.parseReply(data: Data(body.utf8), status: 200, model: "m")
        #expect(text == "Click Save. [POINT:10,20:save]")
    }

    @Test func missingModelGivesPullHint() {
        let body = #"{"error":"model 'qwen2.5vl:7b' not found"}"#
        #expect(throws: OllamaClient.ClientError.modelMissing("qwen2.5vl:7b")) {
            try OllamaClient.parseReply(data: Data(body.utf8), status: 404, model: "qwen2.5vl:7b")
        }
    }
}

@Suite("Permissions by mode")
struct PermissionModeTests {
    @Test func transcribeOnlyNeverNeedsScreenRecording() {
        let kinds = PermissionKind.required(transcribeOnly: true)
        #expect(!kinds.contains(.screen))
        #expect(kinds.contains(.microphone))
        #expect(kinds.contains(.speech))
    }

    @Test func askModeNeedsAllFour() {
        #expect(Set(PermissionKind.required(transcribeOnly: false)) == Set(PermissionKind.allCases))
    }
}

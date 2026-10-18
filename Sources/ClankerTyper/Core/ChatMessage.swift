import Foundation

/// One message to a local model: text, and for ask mode, screenshots.
struct ChatMessage: Equatable {
    enum Block: Equatable {
        case text(String)
        case imageJPEG(base64: String)
    }

    let role: String
    let content: [Block]
}

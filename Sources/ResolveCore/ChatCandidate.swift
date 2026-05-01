import Foundation

public struct ChatCandidate: Sendable, Equatable, Codable {
    public let chatId: Int64
    public let chatIdentifier: String
    public let displayName: String?
    public let service: String
    public let participants: [String]
    public let handleCount: Int
    public let lastMessageAt: Date

    public init(
        chatId: Int64,
        chatIdentifier: String,
        displayName: String?,
        service: String,
        participants: [String],
        handleCount: Int,
        lastMessageAt: Date
    ) {
        self.chatId = chatId
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.service = service
        self.participants = participants
        self.handleCount = handleCount
        self.lastMessageAt = lastMessageAt
    }
}

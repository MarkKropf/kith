import Foundation

public struct ContactGroup: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let memberCount: Int

    public init(id: String, name: String, memberCount: Int) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }
}

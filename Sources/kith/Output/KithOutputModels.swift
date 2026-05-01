import Foundation
import KithAgentProtocol

// Wire-shape types (`KithChat`, `KithMessage`, `KithAttachment`) and the
// `cleanMessageText` / `makeKithMessage` helpers moved to `KithAgentProtocol`
// in v0.2.0 so the agent and CLI agree on a single Codable shape. This file
// holds CLI-only output projections that don't need to cross the XPC boundary.

public struct KithHandle: Encodable, Sendable {
    public let kind: String   // "phone" | "email" | "other"
    public let value: String
    public let raw: String
}

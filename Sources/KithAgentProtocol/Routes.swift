import ContactsCore
import Foundation
import SecureXPC

/// Mach service name the agent listens on. Must match the `MachServices` key
/// of the LaunchAgent plist in `Kith.app/Contents/Library/LaunchAgents/`.
public let kithAgentMachServiceName = "com.supaku.kith.agent"

/// Wire-protocol error type that survives XPC encoding. The agent's route
/// handlers translate internal errors (`ContactsError`, raw NSErrors) into
/// these so the CLI gets a stable, typed error shape.
public enum KithWireError: Error, Codable, Sendable {
    case permissionDenied(String)
    case notFound(String)
    case ambiguous(String, candidates: [Contact])
    case dbUnavailable(String)
    case `internal`(String)
}

/// XPC routes vended by the agent. The CLI uses these via `KithAgentClient`.
///
/// `nonisolated(unsafe)` is here because SecureXPC's `XPCRoute*` types pre-date
/// Swift 6 strict concurrency and aren't Sendable-annotated. The route values
/// are immutable in practice (built once via the fluent API), so this is safe
/// — drop the annotation when SecureXPC ships Sendable conformance.
public enum AgentRoutes {
    /// Search Contacts. Mirrors `ContactsStore.find(query:)` from ContactsCore.
    public nonisolated(unsafe) static let find = XPCRoute
        .named("contacts", "find")
        .withMessageType(ContactsQuery.self)
        .withReplyType([Contact].self)
        .throwsType(KithWireError.self)
}

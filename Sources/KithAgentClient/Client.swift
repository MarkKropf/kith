import ContactsCore
import Foundation
import KithAgentProtocol
import SecureXPC

/// Errors surfaced by the agent client. Distinct from `ContactsError` so the
/// CLI can branch on "agent unreachable" (probably needs to be launched) vs.
/// permission/data errors that propagate from inside the agent.
public enum KithAgentClientError: Error, CustomStringConvertible {
    /// The agent isn't running or the Mach service isn't registered.
    case agentUnreachable(underlying: Error)
    /// The agent rejected our identity (code-signature mismatch).
    case clientNotAccepted
    /// The agent ran the request but it threw — typically a wrapped
    /// `ContactsError` (permissionDenied, notFound, ambiguous).
    case agentReturnedError(underlying: Error)

    public var description: String {
        switch self {
        case .agentUnreachable(let e):    return "agent unreachable: \(e)"
        case .clientNotAccepted:          return "agent rejected client (code-signature mismatch)"
        case .agentReturnedError(let e):  return "agent error: \(e)"
        }
    }
}

/// Thin client that the CLI uses to talk to the agent.
///
/// `@unchecked Sendable` because SecureXPC's `XPCClient` isn't Sendable-
/// annotated; the underlying client is internally synchronized and used
/// only via the typed routes here.
public final class KithAgentClient: @unchecked Sendable {
    private let xpc: XPCClient

    public init() throws {
        self.xpc = try XPCClient.forMachService(
            named: kithAgentMachServiceName,
            withServerRequirement: .sameTeamIdentifierIfPresent
        )
    }

    public func find(query: ContactsQuery) async throws -> [Contact] {
        do {
            return try await xpc.sendMessage(query, to: AgentRoutes.find)
        } catch let wire as KithWireError {
            throw KithAgentClientError.agentReturnedError(underlying: wire)
        } catch {
            throw Self.classify(error)
        }
    }

    private static func classify(_ error: Error) -> Error {
        // SecureXPC raises XPCError values; we substring-match because the
        // public surface doesn't expose stable case discriminants we can
        // pattern-match on here. The empirical failure modes we care about:
        //   - `connectionInvalid` — the Mach service isn't registered or has
        //     no listening process. Means the agent isn't running.
        //   - `connectionInterrupted` — the agent listening process died
        //     mid-request. Treat the same as unreachable for UX purposes.
        //   - "code signing requirement" / "not accepted" — the agent
        //     refused our identity. Surface a different hint so the user
        //     knows to check signing rather than restart the agent.
        let message = String(describing: error).lowercased()
        if message.contains("connectioninvalid")
            || message.contains("connectioninterrupted")
            || message.contains("could not connect")
            || message.contains("does not exist")
            || message.contains("no such file") {
            return KithAgentClientError.agentUnreachable(underlying: error)
        }
        if message.contains("not accepted") || message.contains("code signing requirement") {
            return KithAgentClientError.clientNotAccepted
        }
        return KithAgentClientError.agentReturnedError(underlying: error)
    }
}

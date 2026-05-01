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
    /// Auto-bootstrap of `/Applications/Kith.app` failed; agent still
    /// unreachable. Carries both the bootstrap and the original errors so
    /// the CLI can surface a useful hint.
    case bootstrapFailed(bootstrap: Error, original: Error)
    /// The agent rejected our identity (code-signature mismatch).
    case clientNotAccepted
    /// The agent ran the request but it threw — typically a wrapped
    /// `KithWireError` (permissionDenied, notFound, ambiguous, …).
    case agentReturnedError(underlying: Error)

    public var description: String {
        switch self {
        case .agentUnreachable(let e):     return "agent unreachable: \(e)"
        case .bootstrapFailed(let b, let o): return "agent bootstrap failed: \(b); original: \(o)"
        case .clientNotAccepted:           return "agent rejected client (code-signature mismatch)"
        case .agentReturnedError(let e):   return "agent error: \(e)"
        }
    }
}

/// Thin client that the CLI uses to talk to the agent.
///
/// `@unchecked Sendable` because SecureXPC's `XPCClient` isn't Sendable-
/// annotated; the underlying client is internally synchronized and used
/// only via the typed routes here.
public final class KithAgentClient: @unchecked Sendable {
    /// Path to the Kith.app bundle the bootstrap step launches when the
    /// agent's Mach service isn't registered. Overrideable via the
    /// `KITH_BOOTSTRAP_APP_PATH` env var (used by `release-rehearsal.sh`
    /// to point at `~/Applications/Kith.app`). Concurrency-unsafe in
    /// principle (it's mutable global state), but in practice it's set
    /// once at process start by the rehearsal harness — single writer,
    /// never concurrent. The annotation acknowledges that.
    public nonisolated(unsafe) static var bootstrapAppPath: String = {
        if let override = ProcessInfo.processInfo.environment["KITH_BOOTSTRAP_APP_PATH"], !override.isEmpty {
            return override
        }
        return "/Applications/Kith.app"
    }()

    /// How long to wait for the agent's Mach service after launching
    /// Kith.app via `open -a … --args register`. Defaults to ~5s; bumped
    /// only by tests. Same single-writer invariant as `bootstrapAppPath`.
    public nonisolated(unsafe) static var bootstrapTimeout: TimeInterval = 5.0

    private let xpc: XPCClient

    public init() {
        self.xpc = XPCClient.forMachService(
            named: kithAgentMachServiceName,
            withServerRequirement: .sameTeamIdentifierIfPresent
        )
    }

    // MARK: - contacts.*

    public func find(query: ContactsQuery) async throws -> [Contact] {
        return try await retryAfterBootstrap {
            try await self.xpc.sendMessage(query, to: AgentRoutes.find)
        }
    }

    public func get(id: String) async throws -> Contact? {
        let wrapped: OptionalContact = try await retryAfterBootstrap {
            try await self.xpc.sendMessage(id, to: AgentRoutes.contactsGet)
        }
        return wrapped.value
    }

    public func listGroups() async throws -> [ContactGroup] {
        return try await retryAfterBootstrap {
            try await self.xpc.send(to: AgentRoutes.contactsListGroups)
        }
    }

    public func groupMembers(groupID: String, limit: Int) async throws -> [Contact] {
        let q = ContactsGroupMembersQuery(groupID: groupID, limit: limit)
        return try await retryAfterBootstrap {
            try await self.xpc.sendMessage(q, to: AgentRoutes.contactsGroupMembers)
        }
    }

    public func groupsByName(_ name: String) async throws -> [ContactGroup] {
        return try await retryAfterBootstrap {
            try await self.xpc.sendMessage(name, to: AgentRoutes.contactsGroupsByName)
        }
    }

    // MARK: - messages.*

    public func chats(query: MessagesChatsQuery) async throws -> [KithChat] {
        return try await retryAfterBootstrap {
            try await self.xpc.sendMessage(query, to: AgentRoutes.messagesChats)
        }
    }

    public func history(query: MessagesHistoryQuery) async throws -> MessagesHistoryResult {
        return try await retryAfterBootstrap {
            try await self.xpc.sendMessage(query, to: AgentRoutes.messagesHistory)
        }
    }

    // MARK: - system.*

    public func ping() async throws -> String {
        do {
            return try await xpc.send(to: AgentRoutes.systemPing)
        } catch {
            throw Self.classify(error)
        }
    }

    public func health() async throws -> AgentHealthReport {
        return try await retryAfterBootstrap {
            try await self.xpc.send(to: AgentRoutes.systemHealth)
        }
    }

    // MARK: - Bootstrap-and-retry plumbing

    /// Run `block`. If it surfaces a bootstrap-eligible error (Mach
    /// service missing, signing mismatch from a stale registration, or
    /// Contacts in `.notDetermined` state), run a one-time bootstrap and
    /// retry the block once.
    ///
    /// Bootstrap actions, by error class:
    ///   - `.agentUnreachable` / `.clientNotAccepted`
    ///                  → `open -a Kith.app --args register`
    ///                    (registers the LaunchAgent against the current
    ///                    bundle path; updates BTM)
    ///   - `agentReturnedError(.contactsNotDetermined)`
    ///                  → `open -a Kith.app --args request-contacts`
    ///                    (fires the system TCC prompt from the .app's
    ///                    foreground UI context — the agent itself is a
    ///                    background process and can't host the prompt).
    private func retryAfterBootstrap<R>(_ block: () async throws -> R) async throws -> R {
        do {
            return try await self.invoke(block)
        } catch let err as KithAgentClientError {
            let action: String
            switch err {
            case .agentUnreachable, .clientNotAccepted:
                action = "register"
            case .agentReturnedError(let underlying):
                if let wire = underlying as? KithWireError, case .contactsNotDetermined = wire {
                    action = "request-contacts"
                } else {
                    throw err
                }
            default:
                throw err
            }
            do {
                try await Self.runBootstrap(action: action)
            } catch let bootErr {
                throw KithAgentClientError.bootstrapFailed(bootstrap: bootErr, original: err)
            }
            // Retry once. Anything that surfaces from this attempt is the
            // final answer.
            return try await self.invoke(block)
        }
    }

    /// Wrap `block`'s raw errors in `KithAgentClientError` cases.
    private func invoke<R>(_ block: () async throws -> R) async throws -> R {
        do {
            return try await block()
        } catch let wire as KithWireError {
            throw KithAgentClientError.agentReturnedError(underlying: wire)
        } catch {
            throw Self.classify(error)
        }
    }

    /// Run `open -a Kith.app --args <action>` and wait for it to settle.
    ///
    /// `action` is one of:
    ///   - `"register"`         → `SMAppService.agent.register()` + then
    ///                            requests Contacts access if the auth
    ///                            state is .notDetermined. KithApp handles
    ///                            both. We poll `system.ping` after to
    ///                            confirm the Mach service is alive.
    ///   - `"request-contacts"` → only fires the Contacts TCC prompt.
    ///                            We do NOT poll system.ping (the agent
    ///                            may already be running). Just wait for
    ///                            KithApp to exit.
    private static func runBootstrap(action: String) async throws {
        let appPath = bootstrapAppPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-W` makes `open` block until the launched .app exits — which is
        // what we want, because KithApp's `request-contacts` action blocks
        // on a synchronous semaphore until the user clicks Allow / Don't
        // Allow on the TCC prompt.
        process.arguments = ["-W", "-a", appPath, "--args", action]
        try process.run()
        process.waitUntilExit()

        if action == "register" {
            // Poll for service availability. Each ping uses a fresh
            // XPCClient so we don't reuse a connection that may have
            // cached a "service does not exist" failure on first attempt.
            let deadline = Date().addingTimeInterval(bootstrapTimeout)
            var lastError: Error? = nil
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
                do {
                    let probe = XPCClient.forMachService(
                        named: kithAgentMachServiceName,
                        withServerRequirement: .sameTeamIdentifierIfPresent
                    )
                    _ = try await probe.send(to: AgentRoutes.systemPing) as String
                    return
                } catch {
                    lastError = error
                    continue
                }
            }
            if let lastError {
                throw lastError
            }
            throw KithAgentClientError.agentUnreachable(
                underlying: NSError(domain: "kith.bootstrap", code: -1, userInfo: [NSLocalizedDescriptionKey: "agent did not register within \(bootstrapTimeout)s"])
            )
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
        // SecureXPC raises `.insecure` when the connection's audit token
        // doesn't satisfy the server's client requirement. In practice the
        // common cause is a stale agent registration pointing at an old
        // bundle path that doesn't match the freshly-installed CLI's
        // signature. Lump it with `clientNotAccepted` so the bootstrap
        // retry path re-registers SMAppService against the current bundle.
        if message.contains("not accepted")
            || message.contains("code signing requirement")
            || message.contains("insecure") {
            return KithAgentClientError.clientNotAccepted
        }
        return KithAgentClientError.agentReturnedError(underlying: error)
    }
}

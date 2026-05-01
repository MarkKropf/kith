import ArgumentParser
import ContactsCore
import Foundation
import KithAgentClient
import KithAgentProtocol
import KithMessagesService
import MessagesCore
import ResolveCore

enum RunHelpers {
    /// Construct a `KithAgentClient`. Construction itself is infallible
    /// (binds the Mach service lookup lazily); errors only surface on the
    /// first XPC call. Returns the client.
    static func makeClient(machine _: Bool) -> KithAgentClient {
        return KithAgentClient()
    }

    /// Whether the CLI should bypass the agent and run the messages.*
    /// pipeline in-process. Triggered by setting `KITH_DB_PATH` (the
    /// integration tests rely on this — the agent process can't pick up an
    /// env var from the calling shell).
    static var localModeEnabled: Bool {
        return ProcessInfo.processInfo.environment["KITH_DB_PATH"] != nil
    }

    /// Open `MessageStore` for local-mode requests. Honors `KITH_DB_PATH`
    /// via `MessageStore.kithDefaultPath`.
    static func openLocalMessageStore() throws -> MessageStore {
        do {
            return try MessageStore(path: MessageStore.kithDefaultPath)
        } catch {
            throw KithWireError.dbUnavailable(String(describing: error))
        }
    }

    /// Open `ContactsStore` for local-mode requests. Used by the resolver
    /// when --with names a person; CN access is gated by the calling
    /// process's TCC grant. The integration suite avoids paths that need
    /// CNContactStore by passing phone numbers / chat-id explicitly.
    static func openLocalContactsStore(normalizer: KithPhoneNumberNormalizer) -> ContactsStore {
        return CNBackedContactsStore(normalizer: normalizer)
    }

    /// Translate a thrown `KithAgentClientError` into a kith error envelope
    /// + ExitCode. Centralizes the connectivity/permission/agent-error split
    /// so individual commands can stay terse.
    static func emitClientError(_ err: Error, machine: Bool) -> Int32 {
        if let clientErr = err as? KithAgentClientError {
            switch clientErr {
            case .agentUnreachable:
                return ErrorReporter.emit(
                    .generic,
                    message: "kith-agent isn't running and bootstrap was not attempted.",
                    hint: "In dev: `bash scripts/dev-agent.sh load && bash scripts/dev-agent.sh kickstart`. In production, install Kith.app via `brew install --cask kith` and launch it once.",
                    machine: machine
                )
            case .bootstrapFailed:
                return ErrorReporter.emit(
                    .generic,
                    message: "kith-agent isn't running and auto-bootstrap of \(KithAgentClient.bootstrapAppPath) failed: \(clientErr)",
                    hint: "Make sure Kith.app is installed (e.g. via `brew install --cask kith`) and launch it once to register the LaunchAgent.",
                    machine: machine
                )
            case .clientNotAccepted:
                return ErrorReporter.emit(
                    .generic,
                    message: "kith-agent rejected this client (code-signature mismatch).",
                    hint: "Make sure the kith CLI and KithAgent are signed with the same Apple Team ID.",
                    machine: machine
                )
            case .agentReturnedError(let underlying):
                if let wire = underlying as? KithWireError {
                    return emitWireError(wire, machine: machine)
                }
                return ErrorReporter.emit(.generic, message: String(describing: underlying), machine: machine)
            }
        }
        return ErrorReporter.emit(.generic, message: String(describing: err), machine: machine)
    }

    /// Render a `KithWireError` as a kith error envelope.
    static func emitWireError(_ err: KithWireError, machine: Bool) -> Int32 {
        switch err {
        case .permissionDenied(let m):
            return ErrorReporter.emit(.permissionDenied, message: m, hint: "Run `kith doctor` for permission details.", machine: machine)
        case .notFound(let m):
            return ErrorReporter.emit(.notFound, message: m, machine: machine)
        case .ambiguous(let m, let candidates):
            let envelope = candidates.map { c in
                KithErrorEnvelope.Candidate(chatId: nil, chatIdentifier: nil, displayName: nil, service: nil, participants: nil, handleCount: nil, lastMessageAt: nil, contactId: c.id, fullName: c.fullName, mergeRejectionReason: nil)
            }
            return ErrorReporter.emit(.ambiguous, message: m, hint: "Re-run with the contact id.", candidates: envelope, machine: machine)
        case .dbUnavailable(let m):
            return ErrorReporter.emit(.dbUnavailable, message: m, hint: "Make sure Kith.app has Full Disk Access; see `kith doctor`.", machine: machine)
        case .internal(let m):
            return ErrorReporter.emit(.generic, message: m, machine: machine)
        case .invalidInput(let m):
            return ErrorReporter.emit(.invalidInput, message: m, machine: machine)
        case .resolverInvalidWith(let s):
            return ErrorReporter.emit(.invalidInput, message: "invalid --with value: \(s)", machine: machine)
        case .resolverContactNotFound(let s):
            return ErrorReporter.emit(.notFound, message: "no contact match for \(s)", machine: machine)
        case .resolverContactAmbiguous(let s, let ids, let names):
            let envelope = zip(ids, names).map { id, name in
                KithErrorEnvelope.Candidate(chatId: nil, chatIdentifier: nil, displayName: nil, service: nil, participants: nil, handleCount: nil, lastMessageAt: nil, contactId: id, fullName: name, mergeRejectionReason: nil)
            }
            return ErrorReporter.emit(.ambiguous, message: "multiple contacts match \(s)", hint: "re-run with --with <CNContact-uuid> to disambiguate", candidates: envelope, machine: machine)
        case .noChatFound(let with):
            let hint = "no chat found for \(with); try kith chats --participant <X> or kith find --name <Y> to debug"
            return ErrorReporter.emit(.notFound, message: "no chat for \(with)", hint: hint, machine: machine)
        case .noCanonical1to1(let m, let candidates):
            let envelope = candidates.map { c in
                KithErrorEnvelope.Candidate(
                    chatId: c.chatId, chatIdentifier: c.chatIdentifier, displayName: c.displayName,
                    service: c.service, participants: c.participants, handleCount: c.handleCount,
                    lastMessageAt: c.lastMessageAt, contactId: nil, fullName: nil,
                    mergeRejectionReason: c.mergeRejectionReason
                )
            }
            return ErrorReporter.emit(.ambiguous, message: m, hint: "Pick a chat-id from the candidates, e.g. --with chat-id:<n>.", candidates: envelope, machine: machine)
        }
    }
}

enum KithCommandError: Error {
    case permissionDenied(String)
    case dbUnavailable(String)
    case notFound(String)
    case ambiguous(String, candidates: [KithErrorEnvelope.Candidate])
    case invalidInput(String)
    case usage(String)
}

extension KithCommandError {
    func emit(machine: Bool) -> Int32 {
        switch self {
        case .permissionDenied(let m):
            return ErrorReporter.emit(.permissionDenied, message: m, hint: "Run `kith doctor` for permission details.", machine: machine)
        case .dbUnavailable(let m):
            return ErrorReporter.emit(.dbUnavailable, message: m, hint: "Make sure Kith.app has Full Disk Access; see `kith doctor`.", machine: machine)
        case .notFound(let m):
            return ErrorReporter.emit(.notFound, message: m, hint: nil, machine: machine)
        case .ambiguous(let m, let candidates):
            return ErrorReporter.emit(.ambiguous, message: m, hint: "Re-run with --with chat-id:<n> to disambiguate.", candidates: candidates, machine: machine)
        case .invalidInput(let m):
            return ErrorReporter.emit(.invalidInput, message: m, hint: nil, machine: machine)
        case .usage(let m):
            return ErrorReporter.emit(.usage, message: m, hint: nil, machine: machine)
        }
    }
}

/// Helper to print one JSON line per record (JSONL stream).
enum JSONLEmitter {
    static func emit<T: Encodable>(_ records: [T]) throws {
        let enc = KithJSON.encoder()
        var stdout = StdoutStream()
        for record in records {
            let data = try enc.encode(record)
            stdout.write(String(decoding: data, as: UTF8.self))
            stdout.write("\n")
        }
    }
}

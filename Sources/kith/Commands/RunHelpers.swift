import ArgumentParser
import ContactsCore
import Foundation
import MessagesCore
import ResolveCore

enum RunHelpers {
    /// Construct a (ContactsStore, normalizer) pair, requesting access if the
    /// permission status is `notDetermined` (so the first invocation prompts
    /// the user exactly once).
    static func makeContactsStore() throws -> (CNBackedContactsStore, KithPhoneNumberNormalizer) {
        let normalizer = KithPhoneNumberNormalizer()
        let store = CNBackedContactsStore(normalizer: normalizer)
        if store.authorizationStatus() == .notDetermined {
            // requestAccess can throw a raw NSError (CNErrorDomain code 100,
            // sometimes formatted as "Access Denied"). Wrap so the user gets
            // a kith-formatted error envelope instead of the bare NSError
            // bubbling up to ArgumentParser.
            do {
                try store.requestAccess()
            } catch {
                throw KithCommandError.permissionDenied(
                    "Contacts access request failed: \(error.localizedDescription). Add your terminal app to System Settings → Privacy & Security → Contacts, then restart it."
                )
            }
        }
        let status = store.authorizationStatus()
        if status != .granted {
            throw KithCommandError.permissionDenied("Contacts access not granted (status: \(status.rawValue)). Add your terminal app to System Settings → Privacy & Security → Contacts, then restart it.")
        }
        return (store, normalizer)
    }

    /// Open the Messages chat.db at the kith default path (with KITH_DB_PATH
    /// override).
    static func openMessages() throws -> MessageStore {
        do {
            return try MessageStore(path: MessageStore.kithDefaultPath)
        } catch {
            throw KithCommandError.dbUnavailable(String(describing: error))
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
            return ErrorReporter.emit(
                .permissionDenied,
                message: m,
                hint: "Run `kith doctor` for permission details.",
                machine: machine
            )
        case .dbUnavailable(let m):
            return ErrorReporter.emit(
                .dbUnavailable,
                message: m,
                hint: "Make sure your terminal has Full Disk Access; see `kith doctor`.",
                machine: machine
            )
        case .notFound(let m):
            return ErrorReporter.emit(.notFound, message: m, hint: nil, machine: machine)
        case .ambiguous(let m, let candidates):
            return ErrorReporter.emit(
                .ambiguous,
                message: m,
                hint: "Re-run with --with chat-id:<n> to disambiguate.",
                candidates: candidates,
                machine: machine
            )
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

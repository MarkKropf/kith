import Foundation

/// Stable string codes emitted in machine-mode errors (§3.8) and used to map
/// to exit codes.
enum KithExitCode: Int32 {
    case ok = 0
    case generic = 1
    case usage = 2
    case notFound = 3
    case ambiguous = 4
    case permissionDenied = 5
    case dbUnavailable = 6
    case invalidInput = 7

    var stringCode: String {
        switch self {
        case .ok: return "OK"
        case .generic: return "GENERIC_ERROR"
        case .usage: return "USAGE"
        case .notFound: return "NOT_FOUND"
        case .ambiguous: return "AMBIGUOUS_MATCH"
        case .permissionDenied: return "PERMISSION_DENIED"
        case .dbUnavailable: return "DB_UNAVAILABLE"
        case .invalidInput: return "INVALID_INPUT"
        }
    }
}

struct KithErrorEnvelope: Encodable {
    struct Candidate: Encodable {
        let chatId: Int64?
        let chatIdentifier: String?
        let displayName: String?
        let service: String?
        let participants: [String]?
        let handleCount: Int?
        let lastMessageAt: Date?
        let contactId: String?
        let fullName: String?
        /// One of the `MergeRejectionReason` values when the candidate was
        /// rejected by the canonical-1:1 filter; nil otherwise.
        let mergeRejectionReason: String?
    }

    let code: String
    let exit: Int32
    let message: String
    let hint: String?
    let candidates: [Candidate]?
}

enum ErrorReporter {
    /// Emit an error and return its exit code. Machine = JSON to stderr;
    /// human = single-line + indented hint + one-line-per-candidate when
    /// candidates are supplied.
    static func emit(
        _ exit: KithExitCode,
        message: String,
        hint: String? = nil,
        candidates: [KithErrorEnvelope.Candidate]? = nil,
        machine: Bool
    ) -> Int32 {
        var stderr = StderrStream()
        if machine {
            let env = KithErrorEnvelope(
                code: exit.stringCode,
                exit: exit.rawValue,
                message: message,
                hint: hint,
                candidates: candidates
            )
            do {
                let data = try KithJSON.encoder().encode(env)
                let line = String(decoding: data, as: UTF8.self)
                print(line, to: &stderr)
            } catch {
                print("kith: error: \(message)", to: &stderr)
            }
        } else {
            let style = AnsiStyle.auto
            print("\(style.boldRed("kith: error:")) \(message)", to: &stderr)
            if let hint, !hint.isEmpty {
                print("  \(style.yellow("hint:")) \(hint)", to: &stderr)
            }
            if let candidates, !candidates.isEmpty {
                print("  \(style.dim("candidates:"))", to: &stderr)
                for c in candidates {
                    print("    \(formatHumanCandidate(c, style: style))", to: &stderr)
                }
            }
        }
        return exit.rawValue
    }

    /// One-line summary of a candidate for human stderr output. Combines
    /// chat-id, the merge-rejection reason (so the user knows WHY a chat
    /// didn't fold into the canonical 1:1), and the most important
    /// metadata for picking.
    private static func formatHumanCandidate(_ c: KithErrorEnvelope.Candidate, style: AnsiStyle = .auto) -> String {
        // Contact-level ambiguity (resolved before chat lookup).
        if let id = c.contactId, let name = c.fullName {
            return "\(style.bold(name))  \(style.dim("[\(id)]"))"
        }
        var parts: [String] = []
        if let chatId = c.chatId {
            parts.append(style.bold("chat-id:\(chatId)"))
        }
        if let reason = c.mergeRejectionReason {
            switch reason {
            case "groupChat":
                parts.append(style.yellow("group chat (\(c.handleCount ?? 0) handles)"))
            case "namedChat":
                parts.append(style.yellow("named: \"\(c.displayName ?? "?")\""))
            case "identifierMismatch":
                parts.append(style.yellow("identifier: \"\(c.chatIdentifier ?? "?")\""))
            case "differentService":
                parts.append(style.yellow("service: \(c.service ?? "?")"))
            default:
                break
            }
        }
        if let last = c.lastMessageAt {
            parts.append(style.dim("last: \(KithDateFormatter.string(from: last))"))
        }
        if let participants = c.participants, !participants.isEmpty {
            let shown = participants.prefix(3).joined(separator: ", ")
            let suffix = participants.count > 3 ? ", +\(participants.count - 3) more" : ""
            parts.append(style.dim("[\(shown)\(suffix)]"))
        }
        return parts.joined(separator: "  ")
    }
}

struct StderrStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

struct StdoutStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }
}

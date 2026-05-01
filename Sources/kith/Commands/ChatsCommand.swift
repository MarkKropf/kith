import ArgumentParser
import ContactsCore
import Foundation
import MessagesCore
import ResolveCore

struct ChatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List chats from the local Messages database."
    )

    @Option(name: .long, help: "Maximum results.")
    var limit: Int = 20

    @Option(name: .long, help: "Phone or email handle (normalized via --region).")
    var participant: String?

    @Option(name: .long, help: "name | phone | email | chat-id:<n> | chat-guid:<g> | CNContact UUID.")
    var with: String?

    @Option(name: .long, help: "ISO-2 region for phone normalization.")
    var region: String = "US"

    @Flag(name: .long, help: "Emit JSONL.")
    var jsonl: Bool = false

    @OptionGroup var common: CommonOutputOptions

    func run() async throws {
        common.applyStyle()
        let messages: MessageStore
        do { messages = try RunHelpers.openMessages() }
        catch let err as KithCommandError { throw ExitCode(err.emit(machine: jsonl)) }

        let normalizer = KithPhoneNumberNormalizer()
        var identities: Set<String> = []

        if let participant {
            identities.formUnion(phoneOrEmailIdentities(participant, region: region, normalizer: normalizer))
        }

        if let with {
            // Use full Resolver pipeline for cross-domain lookups.
            let (contacts, _) = (try? RunHelpers.makeContactsStore()) ?? (CNBackedContactsStore(normalizer: normalizer), normalizer)
            let resolver = Resolver(contacts: contacts, messages: messages, normalizer: normalizer, region: region)
            do {
                let target: ResolvedTarget
                do {
                    target = try resolver.resolve(with)
                } catch let e as ResolverError {
                    throw e
                } catch let e as KithCommandError {
                    throw ExitCode(e.emit(machine: jsonl))
                } catch {
                    _ = ErrorReporter.emit(.generic, message: "resolver failed: \(error.localizedDescription)", hint: "Run `kith doctor` to check permissions.", machine: jsonl)
                    throw ExitCode(KithExitCode.generic.rawValue)
                }
                if target.chatIDs.isEmpty {
                    _ = ErrorReporter.emit(.notFound, message: "no chats matched --with \"\(with)\"", machine: jsonl)
                    throw ExitCode(KithExitCode.notFound.rawValue)
                }
                let chats = try messages.chatCandidates(chatIDs: target.chatIDs)
                let infos = try chats.compactMap { row -> KithChat? in
                    guard let info = try messages.chatInfo(chatID: row.chatID) else { return nil }
                    return KithChat(
                        id: info.id,
                        guid: info.guid,
                        identifier: info.identifier,
                        name: info.name,
                        service: info.service,
                        participants: row.participants,
                        lastMessageAt: row.lastMessageAt
                    )
                }
                try emit(infos)
                return
            } catch let err as ResolverError {
                throw ExitCode(handleResolverError(err, machine: jsonl))
            }
        }

        // Plain listing (or filtered by --participant).
        do {
            let chats = try messages.listChatsForIdentities(identities, limit: limit)
            var out: [KithChat] = []
            for c in chats {
                let participants = (try? messages.participants(chatID: c.id)) ?? []
                let info = try messages.chatInfo(chatID: c.id)
                out.append(KithChat(
                    id: c.id,
                    guid: info?.guid ?? "",
                    identifier: c.identifier,
                    name: c.name,
                    service: c.service,
                    participants: participants,
                    lastMessageAt: c.lastMessageAt
                ))
            }
            try emit(out)
        } catch {
            _ = ErrorReporter.emit(.dbUnavailable, message: String(describing: error), machine: jsonl)
            throw ExitCode(KithExitCode.dbUnavailable.rawValue)
        }
    }

    private func emit(_ chats: [KithChat]) throws {
        if jsonl {
            try JSONLEmitter.emit(chats)
        } else {
            for c in chats { print(HumanRenderer.render(chat: c)) }
        }
    }

    private func phoneOrEmailIdentities(_ raw: String, region: String, normalizer: KithPhoneNumberNormalizer) -> Set<String> {
        if raw.contains("@") {
            return [raw.lowercased()]
        }
        let normalized = normalizer.normalize(raw, region: region)
        var set: Set<String> = [raw]
        if !normalized.isEmpty {
            set.insert(normalized)
            if normalized.hasPrefix("+") { set.insert(String(normalized.dropFirst())) }
            set.insert("tel:\(normalized)")
        }
        return set
    }

    private func handleResolverError(_ err: ResolverError, machine: Bool) -> Int32 {
        switch err {
        case .invalidWithArg(let s):
            return ErrorReporter.emit(.invalidInput, message: "invalid --with value: \(s)", machine: machine)
        case .contactNotFound(let s):
            return ErrorReporter.emit(.notFound, message: "no contact match for \(s)", machine: machine)
        case .contactAmbiguous(let s, let ids, let names):
            let candidates = zip(ids, names).map { id, name in
                KithErrorEnvelope.Candidate(chatId: nil, chatIdentifier: nil, displayName: nil, service: nil, participants: nil, handleCount: nil, lastMessageAt: nil, contactId: id, fullName: name, mergeRejectionReason: nil)
            }
            return ErrorReporter.emit(.ambiguous, message: "multiple contacts match \(s)", hint: "re-run with --with <CNContact-uuid> to disambiguate", candidates: candidates, machine: machine)
        }
    }
}

import ArgumentParser
import ContactsCore
import Foundation
import MessagesCore
import ResolveCore

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Stream message history with someone (cross-domain --with resolution)."
    )

    @Option(name: .long, help: "name | phone | email | chat-id:<n> | chat-guid:<g> | CNContact UUID.")
    var with: String

    @Option(name: .long, help: "Maximum messages (max 5000).")
    var limit: Int = 50

    @Option(name: .long, help: "ISO-8601 lower bound (inclusive).")
    var start: String?

    @Option(name: .long, help: "ISO-8601 upper bound (exclusive).")
    var end: String?

    @Option(name: .long, help: "ISO-2 region for phone normalization.")
    var region: String = "US"

    @Flag(name: .long, help: "Include attachment metadata array on each message.")
    var attachments: Bool = false

    @Flag(name: .long, help: "Include reaction tapbacks (default: filtered out).")
    var includeReactions: Bool = false

    @Flag(name: .long, help: "Emit byte-faithful message text. By default kith strips U+FFFD / U+0000 noise from the attributedBody decoder and replaces U+FFFC inline attachment placeholders with `[attachment: <name>]` (or generic `[attachment]` when --attachments is not set).")
    var rawText: Bool = false

    @Flag(name: .long, help: "Render attachments inline in supported terminals (iTerm2, VS Code, Ghostty, Kitty, WezTerm). HEIC is converted to PNG via /usr/bin/sips. Mutually exclusive with --jsonl.")
    var inline: Bool = false

    @Flag(name: .long, help: "Emit JSONL.")
    var jsonl: Bool = false

    @OptionGroup var common: CommonOutputOptions

    func run() async throws {
        common.applyStyle()
        if limit < 1 || limit > 5000 {
            _ = ErrorReporter.emit(.invalidInput, message: "--limit must be in 1..5000", machine: jsonl)
            throw ExitCode(KithExitCode.invalidInput.rawValue)
        }
        if inline && jsonl {
            _ = ErrorReporter.emit(.usage, message: "--inline and --jsonl are mutually exclusive", machine: false)
            throw ExitCode(KithExitCode.usage.rawValue)
        }

        let messages: MessageStore
        do { messages = try RunHelpers.openMessages() }
        catch let err as KithCommandError { throw ExitCode(err.emit(machine: jsonl)) }

        let normalizer = KithPhoneNumberNormalizer()
        // Contacts may not be needed for chat-id/-guid forms, but the
        // CNBackedContactsStore is cheap to construct; only authorize on
        // demand.
        let lazyContacts = LazyContacts(normalizer: normalizer)

        let parsed = WithArgParser.parse(with)
        let needsContacts: Bool
        switch parsed {
        case .name, .cnContactID: needsContacts = true
        default: needsContacts = false
        }
        // The 1:1 filter enforces "messages with this person" semantics. It
        // only fires when --with names a person; explicit chat-id / chat-guid
        // means "messages from this chat", which bypasses the filter.
        let enforceCanonical1to1: Bool
        switch parsed {
        case .chatID, .chatGUID: enforceCanonical1to1 = false
        default: enforceCanonical1to1 = true
        }
        let contactsStore: ContactsStore
        if needsContacts {
            do {
                contactsStore = try lazyContacts.required().0
            } catch let err as KithCommandError {
                throw ExitCode(err.emit(machine: jsonl))
            }
        } else {
            contactsStore = lazyContacts.optionalStore()
        }

        let resolver = Resolver(contacts: contactsStore, messages: messages, normalizer: normalizer, region: region)
        let target: ResolvedTarget
        do {
            target = try resolver.resolve(with)
        } catch let err as ResolverError {
            throw ExitCode(handleResolverError(err, machine: jsonl))
        } catch let err as KithCommandError {
            throw ExitCode(err.emit(machine: jsonl))
        } catch {
            // SQLite / Contacts / I/O errors that escape the typed-error
            // catches above. Format as a kith error envelope so the user
            // doesn't see ArgumentParser's bare "Error: ..." formatter.
            _ = ErrorReporter.emit(
                .generic,
                message: "resolver failed: \(error.localizedDescription)",
                hint: "Run `kith doctor` to check permissions.",
                machine: jsonl
            )
            throw ExitCode(KithExitCode.generic.rawValue)
        }

        if target.chatIDs.isEmpty {
            let hint = "no chat found for \(with); try kith chats --participant <X> or kith find --name <Y> to debug"
            _ = ErrorReporter.emit(.notFound, message: "no chat for \(with)", hint: hint, machine: jsonl)
            throw ExitCode(KithExitCode.notFound.rawValue)
        }

        // Resolved chat-id set used for the actual streaming query. When
        // --with names a person (name/phone/email/CN-id), enforce the
        // canonical-1:1 filter — exactly the agent/human mental model of
        // "messages with X" excludes group / named chats. Explicit chat-id /
        // chat-guid bypasses the filter.
        var streamChatIDs: [Int64] = target.chatIDs

        if enforceCanonical1to1 {
            let identities = mergeIdentities(target: target, messages: messages)
            let result: MessageStore.MergeableResult
            do {
                result = try messages.kithMergeable(chatIDs: target.chatIDs, identities: identities)
            } catch {
                _ = ErrorReporter.emit(.dbUnavailable, message: String(describing: error), machine: jsonl)
                throw ExitCode(KithExitCode.dbUnavailable.rawValue)
            }
            if result.merged.isEmpty {
                // No canonical 1:1 — only group / named chats matched. The
                // user has to pick a chat-id explicitly.
                throw ExitCode(emitAmbiguity(with: with, candidates: target.candidates, reasons: result.reasons))
            }
            streamChatIDs = result.merged
            // Audit trail: when more than one chat-id contributed to the
            // resolution (rotation OR group chats also matched), drop a
            // one-liner on stderr so the auto-selection is visible to
            // humans. Silenced in --jsonl mode to keep agent stderr clean
            // — agents that want the audit can run `kith chats --with X`.
            if !jsonl && (result.merged.count > 1 || !result.leftover.isEmpty) {
                emitAutoSelectNote(merged: result.merged, leftover: result.leftover, with: with)
            }
        }

        let chatID = streamChatIDs[0]
        let startDate = start.flatMap(KithDateFormatter.date(from:))
        if let s = start, startDate == nil {
            _ = ErrorReporter.emit(.invalidInput, message: "invalid --start ISO-8601 value: \(s)", machine: jsonl)
            throw ExitCode(KithExitCode.invalidInput.rawValue)
        }
        let endDate = end.flatMap(KithDateFormatter.date(from:))
        if let e = end, endDate == nil {
            _ = ErrorReporter.emit(.invalidInput, message: "invalid --end ISO-8601 value: \(e)", machine: jsonl)
            throw ExitCode(KithExitCode.invalidInput.rawValue)
        }

        let filter = MessageFilter(participants: [], startDate: startDate, endDate: endDate)
        let chatService = (try? messages.chatInfo(chatID: chatID)?.service) ?? ""

        let raw: [Message]
        do {
            if streamChatIDs.count > 1 {
                raw = try messages.messagesAcrossChats(
                    streamChatIDs,
                    limit: limit,
                    filter: filter,
                    includeReactions: includeReactions
                )
            } else {
                raw = try messages.messagesIncludingReactions(
                    chatID: chatID,
                    limit: limit,
                    filter: filter,
                    includeReactions: includeReactions
                )
            }
        } catch {
            _ = ErrorReporter.emit(.dbUnavailable, message: String(describing: error), machine: jsonl)
            throw ExitCode(KithExitCode.dbUnavailable.rawValue)
        }

        var emitted: [(KithMessage, [AttachmentMeta]?)] = []
        for m in raw {
            let metas: [AttachmentMeta]?
            if attachments || inline {
                metas = (try? messages.attachments(for: m.rowID)) ?? []
            } else {
                metas = nil
            }
            // Pass metas to makeKithMessage when --attachments is set so the
            // wire shape includes them; pass them when --inline is set so the
            // text-cleanup step can use real transferNames in [attachment: …]
            // placeholders.
            let cleanupMetas = (attachments || inline) ? metas : nil
            let kmsg = makeKithMessage(
                m,
                chatService: chatService,
                attachments: attachments ? metas : nil,
                cleanText: !rawText,
                cleanupAttachments: cleanupMetas
            )
            emitted.append((kmsg, metas))
        }

        if jsonl {
            try JSONLEmitter.emit(emitted.map { $0.0 })
        } else {
            let inlineProto: InlineImageRenderer.InlineProtocol = inline
                ? InlineImageRenderer.detectProtocol()
                : .unsupported
            if inline && inlineProto == .unsupported {
                var stderr = StderrStream()
                print("kith: note: --inline requested but the current terminal does not advertise an inline-image protocol; falling back to text.", to: &stderr)
            }
            var stdout = StdoutStream()
            let canRender = inline && inlineProto != .unsupported && InlineImageRenderer.isStdoutTTY()
            for (m, metas) in emitted {
                print(HumanRenderer.render(message: m))
                if canRender, let metas = metas {
                    for meta in metas {
                        if let escape = InlineImageRenderer.render(meta: meta, protocol: inlineProto) {
                            stdout.write(escape)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Merge helpers

    private func toEnvelope(_ c: ChatCandidate, reason: MessageStore.MergeRejectionReason? = nil) -> KithErrorEnvelope.Candidate {
        return KithErrorEnvelope.Candidate(
            chatId: c.chatId,
            chatIdentifier: c.chatIdentifier.isEmpty ? nil : c.chatIdentifier,
            displayName: c.displayName,
            service: c.service.isEmpty ? nil : c.service,
            participants: c.participants,
            handleCount: c.handleCount,
            lastMessageAt: c.lastMessageAt,
            contactId: nil,
            fullName: nil,
            mergeRejectionReason: reason?.rawValue
        )
    }

    private func emitAmbiguity(with: String, candidates: [ChatCandidate], reasons: [Int64: MessageStore.MergeRejectionReason]? = nil) -> Int32 {
        let envelope = candidates.map { c in toEnvelope(c, reason: reasons?[c.chatId]) }
        return ErrorReporter.emit(
            .ambiguous,
            message: "no canonical 1:1 chat with \(with); only group/named chats matched.",
            hint: "Pick a chat-id from the candidates, e.g. --with chat-id:<n>.",
            candidates: envelope,
            machine: jsonl
        )
    }

    /// One-line stderr audit trail explaining a non-trivial auto-resolution.
    /// Format examples:
    ///   note: auto-selected 1:1 chat-id:158 (5 group/named chats also matched; run `kith chats --with "Mark Kropf"` for the full list)
    ///   note: auto-merged 1:1 across chat-id:1,4,7 (rotation)
    private func emitAutoSelectNote(merged: [Int64], leftover: [Int64], with: String) {
        var stderr = StderrStream()
        let style = AnsiStyle.auto
        var line = "\(style.cyan("kith: note:")) "
        if merged.count == 1 {
            line += "auto-selected 1:1 \(style.bold("chat-id:\(merged[0])"))"
        } else {
            line += "auto-merged 1:1 across \(style.bold("chat-id:\(merged.map(String.init).joined(separator: ","))"))"
        }
        if !leftover.isEmpty {
            let plural = leftover.count == 1 ? "" : "s"
            line += style.dim(" (\(leftover.count) group/named chat\(plural) also matched; run `kith chats --with \"\(with)\"` for the full list)")
        } else if merged.count > 1 {
            line += style.dim(" (rotation)")
        }
        print(line, to: &stderr)
    }

    /// Source the identity set the mergeable filter compares chat_identifier
    /// against. Prefer the resolver's `resolvedFromContact` (the cleanest
    /// case); fall back to the union of participants on the candidate chats
    /// when --with was a chat-id list.
    private func mergeIdentities(target: ResolvedTarget, messages: MessageStore) -> Set<String> {
        if let c = target.resolvedFromContact {
            var ids: Set<String> = []
            for p in c.phones { ids.insert(p) }
            for e in c.emails { ids.insert(e) }
            return ids
        }
        return Set(target.candidates.flatMap { $0.participants.map { $0.lowercased() } })
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

/// Lazy contacts store wrapper — defers TCC prompts until really needed.
final class LazyContacts {
    let normalizer: KithPhoneNumberNormalizer
    init(normalizer: KithPhoneNumberNormalizer) { self.normalizer = normalizer }
    func optionalStore() -> ContactsStore {
        return CNBackedContactsStore(normalizer: normalizer)
    }
    func required() throws -> (CNBackedContactsStore, KithPhoneNumberNormalizer) {
        return try RunHelpers.makeContactsStore()
    }
}

import ArgumentParser
import Foundation
import KithAgentClient
import KithAgentProtocol
import KithMessagesService
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

        // The agent always loads attachments when `--inline` is set so it
        // can populate the inline-rendering metadata even when the wire
        // shape's `attachments` array is suppressed (i.e., when the user
        // didn't pass --attachments).
        let q = MessagesHistoryQuery(
            with: with, limit: limit, start: startDate, end: endDate, region: region,
            attachments: attachments || inline,
            includeReactions: includeReactions,
            cleanText: !rawText
        )
        let result: MessagesHistoryResult
        if RunHelpers.localModeEnabled {
            do {
                let normalizer = KithPhoneNumberNormalizer()
                let messages = try RunHelpers.openLocalMessageStore()
                let contacts = RunHelpers.openLocalContactsStore(normalizer: normalizer)
                result = try KithMessagesService.messagesHistory(
                    contacts: contacts, messages: messages, normalizer: normalizer, query: q
                )
            } catch let err as KithWireError {
                throw ExitCode(RunHelpers.emitWireError(err, machine: jsonl))
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
        } else {
            let client = RunHelpers.makeClient(machine: jsonl)
            do {
                result = try await client.history(query: q)
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
        }

        // One-line stderr audit when the agent auto-merged across rotation
        // shards or auto-selected a 1:1 over group/named candidates.
        if !jsonl, let note = result.autoSelect {
            emitAutoSelectNote(note: note)
        }

        let messages = result.messages
        // When --inline was set without --attachments, suppress the wire
        // shape's attachments field so the JSONL output shape matches the
        // pre-XPC behavior.
        let emitAttachmentsField = attachments

        if jsonl {
            if emitAttachmentsField {
                try JSONLEmitter.emit(messages)
            } else {
                try JSONLEmitter.emit(messages.map { stripAttachmentsField($0) })
            }
            return
        }

        let inlineProto: InlineImageRenderer.InlineProtocol = inline
            ? InlineImageRenderer.detectProtocol()
            : .unsupported
        if inline && inlineProto == .unsupported {
            var stderr = StderrStream()
            print("kith: note: --inline requested but the current terminal does not advertise an inline-image protocol; falling back to text.", to: &stderr)
        }
        var stdout = StdoutStream()
        let canRender = inline && inlineProto != .unsupported && InlineImageRenderer.isStdoutTTY()
        for m in messages {
            print(HumanRenderer.render(message: m))
            if canRender, let metas = m.attachments {
                for meta in metas {
                    if let escape = InlineImageRenderer.render(attachment: meta, protocol: inlineProto) {
                        stdout.write(escape)
                    }
                }
            }
        }
    }

    private func stripAttachmentsField(_ m: KithMessage) -> KithMessage {
        return KithMessage(
            id: m.id, chatId: m.chatId, guid: m.guid,
            replyToGuid: m.replyToGuid, threadOriginatorGuid: m.threadOriginatorGuid,
            destinationCallerId: m.destinationCallerId,
            sender: m.sender, isFromMe: m.isFromMe, service: m.service, text: m.text, date: m.date,
            attachmentsCount: m.attachmentsCount, attachments: nil,
            isReaction: m.isReaction, reactionType: m.reactionType,
            isReactionAdd: m.isReactionAdd, reactedToGuid: m.reactedToGuid
        )
    }

    private func emitAutoSelectNote(note: AutoSelectNote) {
        var stderr = StderrStream()
        let style = AnsiStyle.auto
        var line = "\(style.cyan("kith: note:")) "
        if note.merged.count == 1 {
            line += "auto-selected 1:1 \(style.bold("chat-id:\(note.merged[0])"))"
        } else {
            line += "auto-merged 1:1 across \(style.bold("chat-id:\(note.merged.map(String.init).joined(separator: ","))"))"
        }
        if !note.leftover.isEmpty {
            let plural = note.leftover.count == 1 ? "" : "s"
            line += style.dim(" (\(note.leftover.count) group/named chat\(plural) also matched; run `kith chats --with \"\(with)\"` for the full list)")
        } else if note.merged.count > 1 {
            line += style.dim(" (rotation)")
        }
        print(line, to: &stderr)
    }
}

import ArgumentParser
import Foundation
import KithAgentClient
import KithAgentProtocol
import KithMessagesService
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
        let query = MessagesChatsQuery(limit: limit, participant: participant, with: with, region: region)
        let chats: [KithChat]
        if RunHelpers.localModeEnabled {
            // KITH_DB_PATH is set — run the pipeline in-process against the
            // fixture DB. Doesn't need the agent.
            do {
                let normalizer = KithPhoneNumberNormalizer()
                let messages = try RunHelpers.openLocalMessageStore()
                let contacts = RunHelpers.openLocalContactsStore(normalizer: normalizer)
                chats = try KithMessagesService.messagesChats(
                    contacts: contacts, messages: messages, normalizer: normalizer, query: query
                )
            } catch let err as KithWireError {
                throw ExitCode(RunHelpers.emitWireError(err, machine: jsonl))
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
        } else {
            let client = RunHelpers.makeClient(machine: jsonl)
            do {
                chats = try await client.chats(query: query)
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
        }
        if jsonl {
            try JSONLEmitter.emit(chats)
        } else {
            for c in chats { print(HumanRenderer.render(chat: c)) }
        }
    }
}

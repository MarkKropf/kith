import ArgumentParser
import ContactsCore
import Foundation
import KithAgentClient

struct GroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List contact groups and their members.",
        subcommands: [List.self, Members.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List Contacts groups.")
        @Flag(name: .long, help: "Emit JSONL.")
        var jsonl: Bool = false

        @OptionGroup var common: CommonOutputOptions

        func run() async throws {
            common.applyStyle()
            let client = RunHelpers.makeClient(machine: jsonl)
            let groups: [ContactGroup]
            do {
                groups = try await client.listGroups()
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
            if jsonl {
                try JSONLEmitter.emit(groups)
            } else {
                for g in groups { print(HumanRenderer.render(group: g)) }
            }
        }
    }

    struct Members: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "members", abstract: "List members of a group.")

        @Argument(help: "Group id or exact group name.")
        var target: String

        @Option(name: .long, help: "Maximum results.")
        var limit: Int = 500

        @Option(name: .long, help: "Comma-separated field projection.")
        var fields: String?

        @Flag(name: .long, help: "Emit JSONL.")
        var jsonl: Bool = false

        @OptionGroup var common: CommonOutputOptions

        private static let uuidRegex = try! NSRegularExpression(pattern: "^[0-9A-F-]{36}$")

        func run() async throws {
            common.applyStyle()
            let client = RunHelpers.makeClient(machine: jsonl)

            let isUUID = Self.uuidRegex.firstMatch(
                in: target, options: [], range: NSRange(location: 0, length: target.utf16.count)
            ) != nil

            let groupID: String
            if isUUID {
                groupID = target
            } else {
                let groups: [ContactGroup]
                do {
                    groups = try await client.groupsByName(target)
                } catch {
                    throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
                }
                if groups.isEmpty {
                    _ = ErrorReporter.emit(.notFound, message: "no group named \"\(target)\"", machine: jsonl)
                    throw ExitCode(KithExitCode.notFound.rawValue)
                }
                if groups.count > 1 {
                    _ = ErrorReporter.emit(.ambiguous, message: "\(groups.count) groups named \"\(target)\"", hint: "Re-run with the group id.", machine: jsonl)
                    throw ExitCode(KithExitCode.ambiguous.rawValue)
                }
                groupID = groups[0].id
            }

            let members: [Contact]
            do {
                members = try await client.groupMembers(groupID: groupID, limit: limit)
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: jsonl))
            }
            if jsonl {
                try JSONLEmitter.emit(members)
            } else {
                for c in members {
                    print(HumanRenderer.render(contact: c))
                    print("")
                }
            }
        }
    }
}

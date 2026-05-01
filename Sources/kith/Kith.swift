import ArgumentParser
import Foundation

@main
struct Kith: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kith",
        abstract: "Read Apple Contacts and iMessage from the terminal.",
        version: BuildInfo.version,
        subcommands: [
            FindCommand.self,
            GetCommand.self,
            GroupsCommand.self,
            ChatsCommand.self,
            HistoryCommand.self,
            DoctorCommand.self,
            ToolsCommand.self,
            VersionCommand.self,
        ]
    )
}

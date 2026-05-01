import ArgumentParser
import Foundation

struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Emit machine-readable command manifests and type schemas.",
        subcommands: [Manifest.self, Schema.self, Help.self]
    )

    struct Manifest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "manifest",
            abstract: "Emit the kith command manifest in the requested style."
        )

        @Option(name: .long, help: "kith | openai | anthropic | json-schema")
        var style: String = "kith"

        func run() async throws {
            let raw: Any
            switch style {
            case "kith":
                raw = encodeViaCodable(ManifestEntries.document())
            case "openai":
                raw = ["tools": OpenAIProjection.tools()]
            case "anthropic":
                raw = ["tools": AnthropicProjection.tools()]
            case "json-schema":
                let doc = ManifestEntries.document()
                var commands: [[String: Any]] = []
                for cmd in doc.commands {
                    commands.append([
                        "name": cmd.name,
                        "summary": cmd.summary,
                        "parameters": JSONSchemaProjection.parametersSchema(for: cmd),
                    ])
                }
                raw = [
                    "$schema": "https://json-schema.org/draft/2020-12/schema",
                    "name": doc.name,
                    "version": doc.version,
                    "commands": commands,
                    "types": ManifestEntries.types().mapValues { $0.value },
                ]
            default:
                _ = ErrorReporter.emit(.usage, message: "unknown manifest style: \(style)", hint: "use one of: kith, openai, anthropic, json-schema", machine: true)
                throw ExitCode(KithExitCode.usage.rawValue)
            }
            try emitJSON(raw)
        }

        private func encodeViaCodable<T: Encodable>(_ value: T) -> Any {
            // Round-trip Codable → JSONSerialization to mix with ad-hoc dicts.
            do {
                let data = try KithJSON.encoder().encode(value)
                return try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                return [:] as [String: Any]
            }
        }

        private func emitJSON(_ value: Any) throws {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct Help: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "help",
            abstract: "Dump the full help surface (every command + subcommand) in one stream.",
            discussion: "Single-shot agent onboarding. For structured / machine-readable output prefer `kith tools manifest --style {kith|openai|anthropic|json-schema}`."
        )

        func run() async throws {
            // Ordered tree walk: parent → children inline. Keeps the dump
            // grep-friendly and lets a reader follow the same hierarchy
            // they'd discover with `kith help <cmd>` calls.
            let entries: [(path: String, type: any ParsableCommand.Type)] = [
                ("kith",                  Kith.self),
                ("kith find",             FindCommand.self),
                ("kith get",              GetCommand.self),
                ("kith groups",           GroupsCommand.self),
                ("kith groups list",      GroupsCommand.List.self),
                ("kith groups members",   GroupsCommand.Members.self),
                ("kith chats",            ChatsCommand.self),
                ("kith history",          HistoryCommand.self),
                ("kith doctor",           DoctorCommand.self),
                ("kith tools",            ToolsCommand.self),
                ("kith tools manifest",   ToolsCommand.Manifest.self),
                ("kith tools schema",     ToolsCommand.Schema.self),
                ("kith tools help",       ToolsCommand.Help.self),
                ("kith version",          VersionCommand.self),
            ]

            for (i, entry) in entries.enumerated() {
                if i > 0 { print("") }
                let header = "===== \(entry.path) ====="
                print(header)
                print(entry.type.helpMessage(columns: nil))
            }
        }
    }

    struct Schema: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "schema",
            abstract: "Emit a JSON Schema 2020-12 fragment for a named type."
        )

        @Option(name: .long, help: "Contact | ContactGroup | Chat | Message | Handle | Attachment | Error | DoctorReport")
        var type: String

        func run() async throws {
            let schema: [String: Any]
            switch type {
            case "Contact": schema = JSONSchemaProjection.contactSchema()
            case "ContactGroup": schema = JSONSchemaProjection.contactGroupSchema()
            case "Chat": schema = JSONSchemaProjection.chatSchema()
            case "Message": schema = JSONSchemaProjection.messageSchema()
            case "Handle": schema = JSONSchemaProjection.handleSchema()
            case "Attachment": schema = JSONSchemaProjection.attachmentSchema()
            case "Error": schema = JSONSchemaProjection.errorSchema()
            case "DoctorReport": schema = JSONSchemaProjection.doctorReportSchema()
            default:
                _ = ErrorReporter.emit(.usage, message: "unknown type: \(type)", machine: true)
                throw ExitCode(KithExitCode.usage.rawValue)
            }
            var withMeta = schema
            withMeta["$schema"] = "https://json-schema.org/draft/2020-12/schema"
            let data = try JSONSerialization.data(
                withJSONObject: withMeta,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

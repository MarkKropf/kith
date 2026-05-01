import Foundation

/// kith-native manifest entry. Source of truth; the OpenAI / Anthropic /
/// JSONSchema projections are derived.
struct ManifestArg: Encodable {
    let name: String
    /// "option" | "flag" | "positional"
    let kind: String
    /// "string" | "integer" | "boolean"
    let type: String
    let required: Bool
    let `default`: AnyCodable?
    let description: String?
    /// Optional `oneOf`-style alternatives for `--with`-shaped args.
    let anyOf: [[String: AnyCodable]]?
}

struct ManifestCommand: Encodable {
    let name: String
    let summary: String
    let description: String?
    let arguments: [ManifestArg]
    let output: ManifestOutput
    let exitCodes: [Int32]
}

struct ManifestOutput: Encodable {
    let schemaRef: String?
    /// True when the command emits a JSONL stream.
    let stream: Bool
}

struct ManifestDocument: Encodable {
    let name: String
    let version: String
    let commands: [ManifestCommand]
    let types: [String: AnyCodable]
}

/// Type-erased Encodable for heterogeneous manifest values.
struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Int32: try c.encode(v)
        case let v as Int64: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        case is NSNull: try c.encodeNil()
        default:
            try c.encodeNil()
        }
    }
}

enum ManifestEntries {
    static func document() -> ManifestDocument {
        return ManifestDocument(
            name: "kith",
            version: BuildInfo.version,
            commands: commands(),
            types: types()
        )
    }

    private static func commands() -> [ManifestCommand] {
        return [find, get, groupsList, groupsMembers, chats, history, doctor, version]
    }

    private static var find: ManifestCommand {
        return ManifestCommand(
            name: "find",
            summary: "Search local Apple Contacts.",
            description: "Multiple results allowed. Combine query flags (AND).",
            arguments: [
                ManifestArg(name: "name", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "email", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "phone", kind: "option", type: "string", required: false, default: nil, description: "Normalized to E.164 via --region.", anyOf: nil),
                ManifestArg(name: "org", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "region", kind: "option", type: "string", required: false, default: AnyCodable("US"), description: nil, anyOf: nil),
                ManifestArg(name: "limit", kind: "option", type: "integer", required: false, default: AnyCodable(25), description: nil, anyOf: nil),
                ManifestArg(name: "fields", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "jsonl", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/Contact", stream: true),
            exitCodes: [0, 2, 5, 7]
        )
    }

    private static var get: ManifestCommand {
        return ManifestCommand(
            name: "get",
            summary: "Resolve one canonical contact by id or exact full name.",
            description: "Identifier is the local CN-record UUID; not portable across accounts/devices.",
            arguments: [
                ManifestArg(name: "target", kind: "positional", type: "string", required: true, default: nil, description: "CNContact UUID or exact full name.", anyOf: nil),
                ManifestArg(name: "resolve-only", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
                ManifestArg(name: "fields", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "json", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/Contact", stream: false),
            exitCodes: [0, 2, 3, 4, 5, 7]
        )
    }

    private static var groupsList: ManifestCommand {
        return ManifestCommand(
            name: "groups list",
            summary: "List Contacts groups with member counts.",
            description: nil,
            arguments: [
                ManifestArg(name: "jsonl", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/ContactGroup", stream: true),
            exitCodes: [0, 5]
        )
    }

    private static var groupsMembers: ManifestCommand {
        return ManifestCommand(
            name: "groups members",
            summary: "List contacts in a group.",
            description: nil,
            arguments: [
                ManifestArg(name: "target", kind: "positional", type: "string", required: true, default: nil, description: "Group id or exact group name.", anyOf: nil),
                ManifestArg(name: "limit", kind: "option", type: "integer", required: false, default: AnyCodable(500), description: nil, anyOf: nil),
                ManifestArg(name: "fields", kind: "option", type: "string", required: false, default: nil, description: nil, anyOf: nil),
                ManifestArg(name: "jsonl", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/Contact", stream: true),
            exitCodes: [0, 2, 3, 4, 5, 7]
        )
    }

    private static var chats: ManifestCommand {
        return ManifestCommand(
            name: "chats",
            summary: "List chats from chat.db.",
            description: "Filter by --participant or --with (cross-domain).",
            arguments: [
                ManifestArg(name: "limit", kind: "option", type: "integer", required: false, default: AnyCodable(20), description: nil, anyOf: nil),
                ManifestArg(name: "participant", kind: "option", type: "string", required: false, default: nil, description: "Phone or email (normalized via --region).", anyOf: nil),
                ManifestArg(name: "with", kind: "option", type: "string", required: false, default: nil, description: "name | phone | email | chat-id:<n> | chat-guid:<g> | CNContact UUID.", anyOf: withAnyOf),
                ManifestArg(name: "region", kind: "option", type: "string", required: false, default: AnyCodable("US"), description: nil, anyOf: nil),
                ManifestArg(name: "jsonl", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/Chat", stream: true),
            exitCodes: [0, 2, 3, 4, 5, 6]
        )
    }

    private static var history: ManifestCommand {
        return ManifestCommand(
            name: "history",
            summary: "Stream message history with someone.",
            description: "Resolves --with cross-domain (name -> contact -> phones+emails -> chat). When the resolution returns multiple chats, kith auto-prefers the canonical 1:1 (chat_identifier matches an identity, no display_name, exactly one other participant). When multiple shards are 1:1 (chat-id rotation), they are unioned silently. When only group/named chats match, exits 4 with the candidate list. Chat-id and chat-guid forms REQUIRE the prefix; bare integers are not chat IDs. Use --with chat-id:N (or chat-id:N,M,…) to bypass auto-resolution.",
            arguments: [
                ManifestArg(name: "with", kind: "option", type: "string", required: true, default: nil, description: "name | phone | email | chat-id:<n> | chat-guid:<g> | CNContact UUID.", anyOf: withAnyOf),
                ManifestArg(name: "limit", kind: "option", type: "integer", required: false, default: AnyCodable(50), description: nil, anyOf: nil),
                ManifestArg(name: "start", kind: "option", type: "string", required: false, default: nil, description: "ISO-8601 lower bound.", anyOf: nil),
                ManifestArg(name: "end", kind: "option", type: "string", required: false, default: nil, description: "ISO-8601 upper bound.", anyOf: nil),
                ManifestArg(name: "region", kind: "option", type: "string", required: false, default: AnyCodable("US"), description: nil, anyOf: nil),
                ManifestArg(name: "attachments", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
                ManifestArg(name: "include-reactions", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
                ManifestArg(name: "raw-text", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: "Skip default text cleanup. By default kith strips U+FFFD/U+0000 noise from the attributedBody decoder and replaces U+FFFC inline-attachment placeholders with [attachment: <name>] / [attachment].", anyOf: nil),
                ManifestArg(name: "inline", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: "Render attachments inline in the terminal (iTerm2 / VS Code / Ghostty / Kitty / WezTerm). HEIC is converted via /usr/bin/sips. Mutually exclusive with --jsonl.", anyOf: nil),
                ManifestArg(name: "jsonl", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/Message", stream: true),
            exitCodes: [0, 2, 3, 4, 5, 6, 7]
        )
    }

    private static var doctor: ManifestCommand {
        return ManifestCommand(
            name: "doctor",
            summary: "Check that kith can read Contacts and the Messages database.",
            description: nil,
            arguments: [
                ManifestArg(name: "json", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: "#/types/DoctorReport", stream: false),
            exitCodes: [0, 5]
        )
    }

    private static var version: ManifestCommand {
        return ManifestCommand(
            name: "version",
            summary: "Print kith version.",
            description: nil,
            arguments: [
                ManifestArg(name: "json", kind: "flag", type: "boolean", required: false, default: AnyCodable(false), description: nil, anyOf: nil),
            ],
            output: ManifestOutput(schemaRef: nil, stream: false),
            exitCodes: [0]
        )
    }

    private static var withAnyOf: [[String: AnyCodable]] {
        return [
            ["format": AnyCodable("name")],
            ["format": AnyCodable("phone")],
            ["format": AnyCodable("email")],
            ["format": AnyCodable("chat-id"),    "pattern": AnyCodable("^chat-id:[0-9]+$")],
            ["format": AnyCodable("chat-guid"),  "pattern": AnyCodable("^chat-guid:[A-Za-z]+;-;.+$")],
            ["format": AnyCodable("cncontact-id"),"pattern": AnyCodable("^[0-9A-F-]{36}$")],
        ]
    }

    static func types() -> [String: AnyCodable] {
        return [
            "Contact": AnyCodable(JSONSchemaProjection.contactSchema()),
            "ContactGroup": AnyCodable(JSONSchemaProjection.contactGroupSchema()),
            "Chat": AnyCodable(JSONSchemaProjection.chatSchema()),
            "Message": AnyCodable(JSONSchemaProjection.messageSchema()),
            "Handle": AnyCodable(JSONSchemaProjection.handleSchema()),
            "Attachment": AnyCodable(JSONSchemaProjection.attachmentSchema()),
            "Error": AnyCodable(JSONSchemaProjection.errorSchema()),
            "DoctorReport": AnyCodable(JSONSchemaProjection.doctorReportSchema()),
        ]
    }
}

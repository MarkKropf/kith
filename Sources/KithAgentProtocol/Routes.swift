import ContactsCore
import Foundation
import SecureXPC

/// Mach service name the agent listens on. Must match the `MachServices` key
/// of the LaunchAgent plist in `Kith.app/Contents/Library/LaunchAgents/`.
public let kithAgentMachServiceName = "com.supaku.kith.agent"

// MARK: - Wire-protocol error type

/// Wire-protocol error type that survives XPC encoding. The agent's route
/// handlers translate internal errors (`ContactsError`, `ResolverError`,
/// `MergeableResult` empties, raw NSErrors) into these so the CLI gets a
/// stable, typed error shape.
public enum KithWireError: Error, Codable, Sendable {
    case permissionDenied(String)
    case notFound(String)
    case ambiguous(String, candidates: [Contact])
    case dbUnavailable(String)
    case `internal`(String)
    case invalidInput(String)

    case resolverInvalidWith(String)
    case resolverContactNotFound(String)
    case resolverContactAmbiguous(String, candidateIDs: [String], candidateFullNames: [String])
    case noChatFound(String)
    case noCanonical1to1(String, candidates: [KithChatCandidate])
}

// MARK: - Wire data shapes

/// Disambiguation candidate for chat-level ambiguities. Mirrors the existing
/// `KithErrorEnvelope.Candidate` shape so the CLI's renderer can be reused.
public struct KithChatCandidate: Codable, Sendable, Equatable {
    public let chatId: Int64?
    public let chatIdentifier: String?
    public let displayName: String?
    public let service: String?
    public let participants: [String]?
    public let handleCount: Int?
    public let lastMessageAt: Date?
    public let mergeRejectionReason: String?

    public init(
        chatId: Int64?,
        chatIdentifier: String?,
        displayName: String?,
        service: String?,
        participants: [String]?,
        handleCount: Int?,
        lastMessageAt: Date?,
        mergeRejectionReason: String?
    ) {
        self.chatId = chatId
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.service = service
        self.participants = participants
        self.handleCount = handleCount
        self.lastMessageAt = lastMessageAt
        self.mergeRejectionReason = mergeRejectionReason
    }
}

/// `Chat` projection emitted by `kith chats`. Wire shape (id, guid,
/// identifier, name, service, participants, lastMessageAt).
public struct KithChat: Codable, Sendable, Equatable {
    public let id: Int64
    public let guid: String
    public let identifier: String
    public let name: String
    public let service: String
    public let participants: [String]
    public let lastMessageAt: Date

    public init(id: Int64, guid: String, identifier: String, name: String, service: String, participants: [String], lastMessageAt: Date) {
        self.id = id
        self.guid = guid
        self.identifier = identifier
        self.name = name
        self.service = service
        self.participants = participants
        self.lastMessageAt = lastMessageAt
    }
}

/// `Attachment` projection (subset of `MessagesCore.AttachmentMeta`).
public struct KithAttachment: Codable, Sendable, Equatable {
    public let filename: String
    public let transferName: String
    public let uti: String
    public let mimeType: String
    public let totalBytes: Int64
    public let isSticker: Bool
    public let originalPath: String
    public let missing: Bool

    public init(
        filename: String,
        transferName: String,
        uti: String,
        mimeType: String,
        totalBytes: Int64,
        isSticker: Bool,
        originalPath: String,
        missing: Bool
    ) {
        self.filename = filename
        self.transferName = transferName
        self.uti = uti
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.originalPath = originalPath
        self.missing = missing
    }
}

/// `Message` projection emitted by `kith history`.
public struct KithMessage: Codable, Sendable, Equatable {
    public let id: Int64
    public let chatId: Int64
    public let guid: String
    public let replyToGuid: String?
    public let threadOriginatorGuid: String?
    public let destinationCallerId: String?
    public let sender: String
    public let isFromMe: Bool
    public let service: String
    public let text: String
    public let date: Date
    public let attachmentsCount: Int
    public let attachments: [KithAttachment]?
    public let isReaction: Bool
    public let reactionType: String?
    public let isReactionAdd: Bool?
    public let reactedToGuid: String?

    public init(
        id: Int64, chatId: Int64, guid: String,
        replyToGuid: String?, threadOriginatorGuid: String?, destinationCallerId: String?,
        sender: String, isFromMe: Bool, service: String, text: String, date: Date,
        attachmentsCount: Int, attachments: [KithAttachment]?,
        isReaction: Bool, reactionType: String?, isReactionAdd: Bool?, reactedToGuid: String?
    ) {
        self.id = id
        self.chatId = chatId
        self.guid = guid
        self.replyToGuid = replyToGuid
        self.threadOriginatorGuid = threadOriginatorGuid
        self.destinationCallerId = destinationCallerId
        self.sender = sender
        self.isFromMe = isFromMe
        self.service = service
        self.text = text
        self.date = date
        self.attachmentsCount = attachmentsCount
        self.attachments = attachments
        self.isReaction = isReaction
        self.reactionType = reactionType
        self.isReactionAdd = isReactionAdd
        self.reactedToGuid = reactedToGuid
    }
}

// MARK: - Query types

public struct ContactsGroupMembersQuery: Codable, Sendable {
    public let groupID: String
    public let limit: Int
    public init(groupID: String, limit: Int) {
        self.groupID = groupID
        self.limit = limit
    }
}

public struct MessagesChatsQuery: Codable, Sendable {
    public let limit: Int
    public let participant: String?
    public let with: String?
    public let region: String

    public init(limit: Int, participant: String?, with: String?, region: String) {
        self.limit = limit
        self.participant = participant
        self.with = with
        self.region = region
    }
}

public struct MessagesHistoryQuery: Codable, Sendable {
    public let with: String
    public let limit: Int
    public let start: Date?
    public let end: Date?
    public let region: String
    public let attachments: Bool
    public let includeReactions: Bool
    /// When true (default), agent runs the message-text cleanup pass
    /// (U+FFFC → `[attachment: …]`, strip U+FFFD/U+0000). The CLI's
    /// `--raw-text` flag inverts this.
    public let cleanText: Bool

    public init(
        with: String, limit: Int, start: Date?, end: Date?, region: String,
        attachments: Bool, includeReactions: Bool, cleanText: Bool
    ) {
        self.with = with
        self.limit = limit
        self.start = start
        self.end = end
        self.region = region
        self.attachments = attachments
        self.includeReactions = includeReactions
        self.cleanText = cleanText
    }
}

/// Audit trail for the canonical-1:1 auto-resolution. Surfaced by
/// `messages.history` so the CLI can emit a one-line stderr note explaining
/// why a particular chat (or rotation set) was selected.
public struct AutoSelectNote: Codable, Sendable, Equatable {
    public let merged: [Int64]
    public let leftover: [Int64]
    public init(merged: [Int64], leftover: [Int64]) {
        self.merged = merged
        self.leftover = leftover
    }
}

public struct MessagesHistoryResult: Codable, Sendable {
    public let messages: [KithMessage]
    public let autoSelect: AutoSelectNote?

    public init(messages: [KithMessage], autoSelect: AutoSelectNote?) {
        self.messages = messages
        self.autoSelect = autoSelect
    }
}

// MARK: - Health / doctor wire shape

public struct AgentHealthReport: Codable, Sendable {
    public let agentVersion: String
    public let contactsAuthStatus: String      // "granted" | "denied" | "restricted" | "not-determined"
    public let totalContacts: Int              // 0 when not granted or unreadable
    public let messagesDbPath: String
    public let messagesDbOpenable: Bool
    public let schemaFlags: [String: Bool]

    public init(
        agentVersion: String,
        contactsAuthStatus: String,
        totalContacts: Int,
        messagesDbPath: String,
        messagesDbOpenable: Bool,
        schemaFlags: [String: Bool]
    ) {
        self.agentVersion = agentVersion
        self.contactsAuthStatus = contactsAuthStatus
        self.totalContacts = totalContacts
        self.messagesDbPath = messagesDbPath
        self.messagesDbOpenable = messagesDbOpenable
        self.schemaFlags = schemaFlags
    }
}

// MARK: - Routes

/// XPC routes vended by the agent. The CLI uses these via `KithAgentClient`.
///
/// `nonisolated(unsafe)` is here because SecureXPC's `XPCRoute*` types pre-date
/// Swift 6 strict concurrency and aren't Sendable-annotated. The route values
/// are immutable in practice (built once via the fluent API), so this is safe
/// — drop the annotation when SecureXPC ships Sendable conformance.
public enum AgentRoutes {
    /// Search Contacts. Mirrors `ContactsStore.find(query:)`.
    public nonisolated(unsafe) static let find = XPCRoute
        .named("contacts", "find")
        .withMessageType(ContactsQuery.self)
        .withReplyType([Contact].self)
        .throwsType(KithWireError.self)

    /// Resolve one canonical contact by id. Mirrors `ContactsStore.get(byID:)`.
    public nonisolated(unsafe) static let contactsGet = XPCRoute
        .named("contacts", "get")
        .withMessageType(String.self)
        .withReplyType(OptionalContact.self)
        .throwsType(KithWireError.self)

    /// List Contacts groups. Mirrors `ContactsStore.listGroups()`.
    public nonisolated(unsafe) static let contactsListGroups = XPCRoute
        .named("contacts", "listGroups")
        .withReplyType([ContactGroup].self)
        .throwsType(KithWireError.self)

    /// List members of a group. Mirrors `ContactsStore.members(ofGroupID:limit:)`.
    public nonisolated(unsafe) static let contactsGroupMembers = XPCRoute
        .named("contacts", "groupMembers")
        .withMessageType(ContactsGroupMembersQuery.self)
        .withReplyType([Contact].self)
        .throwsType(KithWireError.self)

    /// Find groups by name. Mirrors `ContactsStore.groups(named:)`.
    public nonisolated(unsafe) static let contactsGroupsByName = XPCRoute
        .named("contacts", "groupsByName")
        .withMessageType(String.self)
        .withReplyType([ContactGroup].self)
        .throwsType(KithWireError.self)

    /// `kith chats` — high-level chat listing. The agent runs the resolver
    /// when `--with` is set, otherwise filters by `--participant` (or returns
    /// the recent-chat list).
    public nonisolated(unsafe) static let messagesChats = XPCRoute
        .named("messages", "chats")
        .withMessageType(MessagesChatsQuery.self)
        .withReplyType([KithChat].self)
        .throwsType(KithWireError.self)

    /// `kith history` — full pipeline: resolver, canonical-1:1 filter,
    /// message stream, attachments, text cleanup. CLI just renders.
    public nonisolated(unsafe) static let messagesHistory = XPCRoute
        .named("messages", "history")
        .withMessageType(MessagesHistoryQuery.self)
        .withReplyType(MessagesHistoryResult.self)
        .throwsType(KithWireError.self)

    /// Liveness ping — returns the agent's reported version. Used by the
    /// client's bootstrap-and-retry path to confirm the Mach service is
    /// reachable before retrying the original request.
    public nonisolated(unsafe) static let systemPing = XPCRoute
        .named("system", "ping")
        .withReplyType(String.self)
        .throwsType(KithWireError.self)

    /// `kith doctor` — agent-side health probe (Contacts auth, chat.db
    /// openability, schema flags). The CLI augments with its own metadata
    /// (terminal arch, color source, etc.) for the human/JSON report.
    public nonisolated(unsafe) static let systemHealth = XPCRoute
        .named("system", "health")
        .withReplyType(AgentHealthReport.self)
        .throwsType(KithWireError.self)
}

/// SecureXPC won't encode `Optional<Contact>` as a top-level reply type —
/// reply types must be a concrete Codable struct. Wrap it.
public struct OptionalContact: Codable, Sendable {
    public let value: Contact?
    public init(_ value: Contact?) { self.value = value }
}

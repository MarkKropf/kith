import Foundation
import MessagesCore

/// `Chat` projection emitted by `kith chats`. Wraps MessagesCore's domain
/// type with the §3.3 wire shape (id, guid, identifier, name, service,
/// participants, lastMessageAt).
public struct KithChat: Encodable, Sendable {
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

/// `Message` projection emitted by `kith history`. §3.4.
public struct KithMessage: Encodable, Sendable {
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

public struct KithAttachment: Encodable, Sendable {
    public let filename: String
    public let transferName: String
    public let uti: String
    public let mimeType: String
    public let totalBytes: Int64
    public let isSticker: Bool
    public let originalPath: String
    public let missing: Bool

    public init(meta: AttachmentMeta) {
        self.filename = meta.filename
        self.transferName = meta.transferName
        self.uti = meta.uti
        self.mimeType = meta.mimeType
        self.totalBytes = meta.totalBytes
        self.isSticker = meta.isSticker
        self.originalPath = meta.originalPath
        self.missing = meta.missing
    }
}

public struct KithHandle: Encodable, Sendable {
    public let kind: String   // "phone" | "email" | "other"
    public let value: String
    public let raw: String
}

/// Clean message text for downstream consumers (BI agents). iMessage's
/// `attributedBody` blob occasionally leaves three kinds of detritus when
/// decoded:
///   - U+FFFC OBJECT REPLACEMENT CHARACTER → Apple's inline attachment
///     placeholder. Replace with `[attachment: <transferName>]` when we have
///     attachment metadata, else `[attachment]`. Each `￼` consumes one
///     attachment in `message_attachment_join` order.
///   - U+FFFD REPLACEMENT CHARACTER → invalid UTF-8 from incomplete
///     attributedBody decoding. Strip.
///   - U+0000 NULL → stray null byte from same source. Strip.
public func cleanMessageText(_ raw: String, attachments: [AttachmentMeta]?) -> String {
    var attachmentIdx = 0
    var out = String()
    out.reserveCapacity(raw.count)
    for ch in raw {
        switch ch {
        case "\u{FFFD}", "\u{0000}":
            continue
        case "\u{FFFC}":
            if let metas = attachments, attachmentIdx < metas.count {
                let name = metas[attachmentIdx].transferName.isEmpty
                    ? metas[attachmentIdx].filename
                    : metas[attachmentIdx].transferName
                out += "[attachment: \(name)]"
                attachmentIdx += 1
            } else {
                out += "[attachment]"
            }
        default:
            out.append(ch)
        }
    }
    return out
}

/// Convert MessagesCore `Message` plus optional attachment list and
/// chat-service into the wire shape. Defaults to cleaning the text per
/// `cleanMessageText`; pass `cleanText: false` to emit byte-faithful output.
///
/// `attachments` populates the wire-shape attachments array (only emitted
/// when caller wants the metadata stream). `cleanupAttachments` is consulted
/// solely for U+FFFC-replacement during text cleanup — useful when the
/// caller has loaded attachments for inline rendering but doesn't want the
/// wire shape to leak them.
public func makeKithMessage(
    _ m: Message,
    chatService: String,
    attachments: [AttachmentMeta]?,
    cleanText: Bool = true,
    cleanupAttachments: [AttachmentMeta]? = nil
) -> KithMessage {
    let attachmentsField: [KithAttachment]? = {
        guard let attachments else { return nil }
        return attachments.map(KithAttachment.init(meta:))
    }()
    let cleanupSource = cleanupAttachments ?? attachments
    let text = cleanText ? cleanMessageText(m.text, attachments: cleanupSource) : m.text
    return KithMessage(
        id: m.rowID,
        chatId: m.chatID,
        guid: m.guid,
        replyToGuid: m.replyToGUID,
        threadOriginatorGuid: m.threadOriginatorGUID,
        destinationCallerId: m.destinationCallerID,
        sender: m.sender,
        isFromMe: m.isFromMe,
        service: m.service.isEmpty ? chatService : m.service,
        text: text,
        date: m.date,
        attachmentsCount: m.attachmentsCount,
        attachments: attachmentsField,
        isReaction: m.isReaction,
        reactionType: m.reactionType?.name,
        isReactionAdd: m.isReactionAdd,
        reactedToGuid: m.reactedToGUID
    )
}

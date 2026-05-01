import Foundation
import MessagesCore

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
        return attachments.map { meta in
            KithAttachment(
                filename: meta.filename,
                transferName: meta.transferName,
                uti: meta.uti,
                mimeType: meta.mimeType,
                totalBytes: meta.totalBytes,
                isSticker: meta.isSticker,
                originalPath: meta.originalPath,
                missing: meta.missing
            )
        }
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

import Foundation
import SQLite

extension MessageStore {
    /// Public read-only accessors over schema-detection flags computed at
    /// init. Used by `kith doctor` to surface schema state.
    public struct KithSchemaFlags: Sendable {
        public let hasAttributedBody: Bool
        public let hasReactionColumns: Bool
        public let hasThreadOriginatorGUIDColumn: Bool
        public let hasDestinationCallerID: Bool
        public let hasAudioMessageColumn: Bool
        public let hasAttachmentUserInfo: Bool
        public let hasBalloonBundleIDColumn: Bool
    }

    public var kithSchemaFlags: KithSchemaFlags {
        return KithSchemaFlags(
            hasAttributedBody: hasAttributedBody,
            hasReactionColumns: hasReactionColumns,
            hasThreadOriginatorGUIDColumn: hasThreadOriginatorGUIDColumn,
            hasDestinationCallerID: hasDestinationCallerID,
            hasAudioMessageColumn: hasAudioMessageColumn,
            hasAttachmentUserInfo: hasAttachmentUserInfo,
            hasBalloonBundleIDColumn: hasBalloonBundleIDColumn
        )
    }

    /// Path used by `kith` commands by default. Honors the `KITH_DB_PATH` env
    /// var so integration tests can point at a fixture database.
    public static var kithDefaultPath: String {
        if let override = ProcessInfo.processInfo.environment["KITH_DB_PATH"],
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return MessageStore.defaultPath
    }

    /// Resolve a set of handle identities (E.164 phones, emails, raw / `tel:`
    /// variants) to the chat ROWIDs whose participants include any of them.
    /// Matches `handle.id` case-insensitively to tolerate email casing.
    public func chatsForIdentities(_ ids: Set<String>) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let bindings: [Binding?] = ids.map { $0 as Binding? }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT DISTINCT chj.chat_id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE h.id COLLATE NOCASE IN (\(placeholders))
            """
        return try withConnection { db in
            var out: [Int64] = []
            for row in try db.prepare(sql, bindings) {
                if let v = self.int64Value(row[0]) { out.append(v) }
            }
            return out
        }
    }

    /// Lightweight chat candidate used by ambiguity reporting (chat-id +
    /// the metadata that drove the §4 mergeable filter).
    public struct ChatCandidateRow: Sendable, Equatable {
        public let chatID: Int64
        public let chatIdentifier: String
        public let displayName: String  // empty when unset
        public let service: String
        public let participants: [String]
        public let handleCount: Int
        public let lastMessageAt: Date
    }

    /// Build candidate rows for the given chat IDs, sorted by `lastMessageAt`
    /// descending. Used by §3.8 ambiguity error candidates.
    public func chatCandidates(chatIDs: [Int64]) throws -> [ChatCandidateRow] {
        guard !chatIDs.isEmpty else { return [] }
        var rows: [ChatCandidateRow] = []
        for id in chatIDs {
            let sql = """
                SELECT IFNULL(c.chat_identifier, ''),
                       IFNULL(c.display_name, ''),
                       IFNULL(c.service_name, ''),
                       (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS handle_count,
                       (SELECT MAX(m.date)
                          FROM chat_message_join cmj
                          JOIN message m ON m.ROWID = cmj.message_id
                         WHERE cmj.chat_id = c.ROWID) AS last_date
                FROM chat c
                WHERE c.ROWID = ?
                LIMIT 1
                """
            var chatIdentifier = ""
            var displayName = ""
            var service = ""
            var handleCount = 0
            var lastDate = appleDate(from: nil)
            try withConnection { db in
                for row in try db.prepare(sql, id) {
                    chatIdentifier = self.stringValue(row[0])
                    displayName = self.stringValue(row[1])
                    service = self.stringValue(row[2])
                    handleCount = self.intValue(row[3]) ?? 0
                    lastDate = self.appleDate(from: self.int64Value(row[4]))
                }
            }
            let participants = try self.participants(chatID: id)
            rows.append(ChatCandidateRow(
                chatID: id,
                chatIdentifier: chatIdentifier,
                displayName: displayName,
                service: service,
                participants: participants,
                handleCount: handleCount,
                lastMessageAt: lastDate
            ))
        }
        rows.sort { $0.lastMessageAt > $1.lastMessageAt }
        return rows
    }

    /// Latest message timestamp on a chat, or the apple-epoch origin if the
    /// chat has no messages.
    public func lastMessageDate(chatID: Int64) throws -> Date {
        let sql = """
            SELECT MAX(m.date)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            """
        return try withConnection { db in
            for row in try db.prepare(sql, chatID) {
                return self.appleDate(from: self.int64Value(row[0]))
            }
            return self.appleDate(from: nil)
        }
    }

    /// List chats filtered by handle identity set, ordered by most recent
    /// message. When `ids` is empty, behaves like `listChats(limit:)`.
    public func listChatsForIdentities(_ ids: Set<String>, limit: Int) throws -> [Chat] {
        guard !ids.isEmpty else { return try listChats(limit: limit) }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT c.ROWID,
                   IFNULL(c.display_name, c.chat_identifier) AS name,
                   c.chat_identifier,
                   c.service_name,
                   MAX(m.date) AS last_date
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON h.ROWID = chj.handle_id
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE h.id COLLATE NOCASE IN (\(placeholders))
            GROUP BY c.ROWID
            ORDER BY last_date DESC
            LIMIT ?
            """
        var bindings: [Binding?] = ids.map { $0 as Binding? }
        bindings.append(Int64(limit))
        return try withConnection { db in
            var chats: [Chat] = []
            for row in try db.prepare(sql, bindings) {
                let id = self.int64Value(row[0]) ?? 0
                let name = self.stringValue(row[1])
                let identifier = self.stringValue(row[2])
                let service = self.stringValue(row[3])
                let lastDate = self.appleDate(from: self.int64Value(row[4]))
                chats.append(Chat(
                    id: id,
                    identifier: identifier,
                    name: name,
                    service: service,
                    lastMessageAt: lastDate
                ))
            }
            return chats
        }
    }

    /// Why a particular chat-id was excluded (or admitted) by `kithMergeable`.
    /// `eligible` denotes a row that joined the merged 1:1 union; the others
    /// are mutually exclusive rejection causes, evaluated in this order:
    /// `identifierMismatch` → `groupChat` → `namedChat` → `differentService`.
    public enum MergeRejectionReason: String, Sendable, Codable {
        case eligible
        case identifierMismatch
        case groupChat
        case namedChat
        case differentService
    }

    /// Result of `kithMergeable`: the candidate IDs that are eligible to be
    /// streamed as a single 1:1 union, plus any IDs that were left out (group
    /// chats, named chats, service-specific synthetic chats, etc.).
    public struct MergeableResult: Sendable, Equatable {
        public let merged: [Int64]
        public let leftover: [Int64]
        public let service: String?
        /// Per-input chat ID, the reason it landed where it did.
        public let reasons: [Int64: MergeRejectionReason]
    }

    /// Apply the §3.8 / §4-extension mergeability filter:
    ///   - `chat.chat_identifier` is in the resolved-identity set
    ///   - `chat.display_name` is NULL or empty
    ///   - `COUNT(chat_handle_join WHERE chat_id = c.ROWID) = 1` (exactly one
    ///     other participant — rejects group chats)
    ///   - `service_name` is the same across the merged subset (uses the
    ///     freshest shard's service as the canonical)
    /// Inputs:
    ///   - `chatIDs`: candidate chat ROWIDs from the Resolver.
    ///   - `identities`: the resolved phone E.164s and lowercased emails.
    public func kithMergeable(chatIDs: [Int64], identities: Set<String>) throws -> MergeableResult {
        guard !chatIDs.isEmpty else {
            return MergeableResult(merged: [], leftover: [], service: nil, reasons: [:])
        }

        // Lowercased identity set for case-insensitive comparison.
        let needle = Set(identities.map { $0.lowercased() })

        struct Row {
            let id: Int64
            let chatIdentifier: String
            let displayName: String
            let service: String
            let handleCount: Int
            let lastDate: Date
        }

        var rows: [Row] = []
        for cid in chatIDs {
            let sql = """
                SELECT c.ROWID,
                       IFNULL(c.chat_identifier, '') AS chat_identifier,
                       IFNULL(c.display_name, '') AS display_name,
                       IFNULL(c.service_name, '') AS service_name,
                       (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS handle_count,
                       (SELECT MAX(m.date)
                          FROM chat_message_join cmj
                          JOIN message m ON m.ROWID = cmj.message_id
                         WHERE cmj.chat_id = c.ROWID) AS last_date
                FROM chat c
                WHERE c.ROWID = ?
                LIMIT 1
                """
            try withConnection { db in
                for row in try db.prepare(sql, cid) {
                    rows.append(Row(
                        id: int64Value(row[0]) ?? 0,
                        chatIdentifier: stringValue(row[1]),
                        displayName: stringValue(row[2]),
                        service: stringValue(row[3]),
                        handleCount: intValue(row[4]) ?? 0,
                        lastDate: appleDate(from: int64Value(row[5]))
                    ))
                }
            }
        }

        // Sort DESC by lastDate so the canonical service comes from the
        // freshest shard.
        rows.sort { $0.lastDate > $1.lastDate }

        var merged: [Row] = []
        var leftover: [Row] = []
        var canonicalService: String?
        var reasons: [Int64: MergeRejectionReason] = [:]

        for row in rows {
            let identifierMatches = needle.contains(row.chatIdentifier.lowercased())
            let unnamed = row.displayName.isEmpty
            let exactlyOneOther = row.handleCount == 1
            let serviceOK: Bool = {
                guard let s = canonicalService else { return true }
                return row.service == s
            }()

            // Evaluate causes in the documented priority. First failing
            // criterion is recorded as the rejection reason — assigning
            // multiple would muddy the diagnostic.
            let reason: MergeRejectionReason
            if !identifierMatches {
                reason = .identifierMismatch
            } else if !exactlyOneOther {
                reason = .groupChat
            } else if !unnamed {
                reason = .namedChat
            } else if !serviceOK {
                reason = .differentService
            } else {
                reason = .eligible
            }
            reasons[row.id] = reason

            if reason == .eligible {
                if canonicalService == nil { canonicalService = row.service }
                merged.append(row)
            } else {
                leftover.append(row)
            }
        }

        return MergeableResult(
            merged: merged.map { $0.id },
            leftover: leftover.map { $0.id },
            service: canonicalService,
            reasons: reasons
        )
    }

    /// Stream messages across a set of chat IDs (the 1:1-union case).
    /// Mirrors the SQL of `messages(chatID:limit:filter:)` but uses
    /// `cmj.chat_id IN (?,?,…)` so `--limit N` means "newest N across the
    /// union."
    public func messagesAcrossChats(
        _ chatIDs: [Int64],
        limit: Int,
        filter: MessageFilter? = nil,
        includeReactions: Bool = false
    ) throws -> [Message] {
        guard !chatIDs.isEmpty else { return [] }
        if chatIDs.count == 1 {
            // Reuse the existing single-chat helper for the trivial case.
            if includeReactions {
                return try messagesIncludingReactions(chatID: chatIDs[0], limit: limit, filter: filter, includeReactions: true)
            }
            return try messages(chatID: chatIDs[0], limit: limit, filter: filter)
        }

        let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
        let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
        let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
        let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
        let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
        let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
        let threadOriginatorColumn = hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
        let reactionFilter: String = {
            guard hasReactionColumns, !includeReactions else { return "" }
            return " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
        }()

        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        var sql = """
            SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
                   \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
                   \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
                   (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
                   \(bodyColumn) AS body,
                   \(threadOriginatorColumn) AS thread_originator_guid
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id IN (\(placeholders))\(reactionFilter)
            """
        var bindings: [Binding?] = chatIDs.map { $0 as Binding? }

        if let filter {
            if let s = filter.startDate {
                sql += " AND m.date >= ?"
                bindings.append(MessageStore.appleEpoch(s))
            }
            if let e = filter.endDate {
                sql += " AND m.date < ?"
                bindings.append(MessageStore.appleEpoch(e))
            }
            if !filter.participants.isEmpty {
                let pPlaceholders = Array(repeating: "?", count: filter.participants.count).joined(separator: ",")
                sql += " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(pPlaceholders))"
                for p in filter.participants { bindings.append(p) }
            }
        }
        sql += " ORDER BY m.date DESC LIMIT ?"
        bindings.append(Int64(limit))

        return try withConnection { db in
            var out: [Message] = []
            for row in try db.prepare(sql, bindings) {
                let rowID = int64Value(row[0]) ?? 0
                let chatID = int64Value(row[1]) ?? 0
                let handleID = int64Value(row[2])
                var sender = stringValue(row[3])
                let text = stringValue(row[4])
                let date = appleDate(from: int64Value(row[5]))
                let isFromMe = boolValue(row[6])
                let service = stringValue(row[7])
                let destinationCaller = stringValue(row[9])
                let guid = stringValue(row[10])
                let associatedGUID = stringValue(row[11])
                let associatedType = intValue(row[12])
                let attachmentsCount = intValue(row[13]) ?? 0
                let body = dataValue(row[14])
                let threadOriginatorGUID = stringValue(row[15])

                if sender.isEmpty && !destinationCaller.isEmpty { sender = destinationCaller }
                let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
                let replyToGUID = self.replyToGUID(associatedGuid: associatedGUID, associatedType: associatedType)
                let reaction = self.decodeReaction(associatedType: associatedType, associatedGUID: associatedGUID, text: resolvedText)

                out.append(Message(
                    rowID: rowID,
                    chatID: chatID,
                    sender: sender,
                    text: resolvedText,
                    date: date,
                    isFromMe: isFromMe,
                    service: service,
                    handleID: handleID,
                    attachmentsCount: attachmentsCount,
                    guid: guid,
                    routing: Message.RoutingMetadata(
                        replyToGUID: replyToGUID,
                        threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
                        destinationCallerID: destinationCaller.isEmpty ? nil : destinationCaller
                    ),
                    reaction: Message.ReactionMetadata(
                        isReaction: reaction.isReaction,
                        reactionType: reaction.reactionType,
                        isReactionAdd: reaction.isReactionAdd,
                        reactedToGUID: reaction.reactedToGUID
                    )
                ))
            }
            return out
        }
    }

    /// Like `messages(chatID:limit:filter:)` but lets the caller opt into
    /// including reaction tapbacks (associated_message_type 2000-3006). The
    /// upstream `messages(chatID:limit:)` always filters them out.
    public func messagesIncludingReactions(
        chatID: Int64,
        limit: Int,
        filter: MessageFilter? = nil,
        includeReactions: Bool
    ) throws -> [Message] {
        if !includeReactions {
            return try messages(chatID: chatID, limit: limit, filter: filter)
        }
        // Use messagesAfter starting from rowID 0 with includeReactions=true,
        // restrict to this chat, then reverse to keep DESC-by-date ordering
        // consistent with the no-reactions path.
        let asc = try messagesAfter(
            afterRowID: 0,
            chatID: chatID,
            limit: limit,
            includeReactions: true
        )
        let filtered: [Message] = {
            guard let filter else { return asc }
            return asc.filter { m in
                if let s = filter.startDate, m.date < s { return false }
                if let e = filter.endDate, m.date >= e { return false }
                if !filter.participants.isEmpty {
                    let id = m.sender.isEmpty ? (m.destinationCallerID ?? "") : m.sender
                    if !filter.participants.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
                        return false
                    }
                }
                return true
            }
        }()
        return filtered.reversed()
    }

    /// Chat ROWID for an exact GUID match, or nil if absent.
    public func chatID(forGUID guid: String) throws -> Int64? {
        let sql = "SELECT ROWID FROM chat WHERE guid = ? LIMIT 1"
        return try withConnection { db in
            for row in try db.prepare(sql, guid) {
                return self.int64Value(row[0])
            }
            return nil
        }
    }
}

import Foundation
import SQLite
@testable import MessagesCore

/// Construct an in-memory SQLite database matching the relevant subset of
/// chat.db's schema. Returns an open `MessageStore` bound to it.
enum FixtureDB {
    static func make() throws -> MessageStore {
        let connection = try Connection(.inMemory)
        try createSchema(connection)
        // The internal init that takes a Connection is `init(connection:path:...)`.
        return try MessageStore(connection: connection, path: ":memory:")
    }

    static func createSchema(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_identifier TEXT,
                guid TEXT,
                display_name TEXT,
                service_name TEXT
            );
            CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT
            );
            CREATE TABLE chat_handle_join (
                chat_id INTEGER,
                handle_id INTEGER
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                handle_id INTEGER,
                text TEXT,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                guid TEXT,
                associated_message_guid TEXT,
                associated_message_type INTEGER,
                attributedBody BLOB,
                thread_originator_guid TEXT,
                destination_caller_id TEXT,
                is_audio_message INTEGER,
                balloon_bundle_id TEXT
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER,
                message_id INTEGER
            );
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT,
                transfer_name TEXT,
                uti TEXT,
                mime_type TEXT,
                total_bytes INTEGER,
                is_sticker INTEGER,
                user_info BLOB
            );
            CREATE TABLE message_attachment_join (
                message_id INTEGER,
                attachment_id INTEGER
            );
            """)
    }

    @discardableResult
    static func insertChat(_ db: Connection, identifier: String, guid: String, name: String? = nil, service: String = "iMessage") throws -> Int64 {
        let bindings: [Binding?] = [identifier, guid, name, service]
        try db.run("INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES (?, ?, ?, ?)", bindings)
        return db.lastInsertRowid
    }

    @discardableResult
    static func insertHandle(_ db: Connection, id: String) throws -> Int64 {
        let bindings: [Binding?] = [id]
        try db.run("INSERT INTO handle (id) VALUES (?)", bindings)
        return db.lastInsertRowid
    }

    static func linkChatHandle(_ db: Connection, chatID: Int64, handleID: Int64) throws {
        let bindings: [Binding?] = [chatID, handleID]
        try db.run("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", bindings)
    }

    @discardableResult
    static func insertMessage(
        _ db: Connection,
        chatID: Int64,
        handleID: Int64? = nil,
        text: String,
        date: Date,
        isFromMe: Bool = false,
        service: String = "iMessage",
        guid: String = UUID().uuidString,
        associatedGUID: String? = nil,
        associatedType: Int? = nil
    ) throws -> Int64 {
        let dateNS = MessageStore.appleEpoch(date)
        let mb: [Binding?] = [
            handleID, text, dateNS, isFromMe ? 1 : 0, service, guid,
            associatedGUID, associatedType,
        ]
        try db.run("""
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid, associated_message_guid, associated_message_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, mb)
        let mid = db.lastInsertRowid
        let lb: [Binding?] = [chatID, mid]
        try db.run("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", lb)
        return mid
    }

    @discardableResult
    static func insertAttachment(
        _ db: Connection,
        messageID: Int64,
        filename: String,
        transferName: String? = nil,
        uti: String = "public.heic",
        mimeType: String = "image/heic",
        totalBytes: Int64 = 0,
        isSticker: Bool = false
    ) throws -> Int64 {
        let ab: [Binding?] = [filename, transferName ?? filename, uti, mimeType, totalBytes, isSticker ? 1 : 0]
        try db.run("""
            INSERT INTO attachment (filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
            VALUES (?, ?, ?, ?, ?, ?)
            """, ab)
        let aid = db.lastInsertRowid
        let lb: [Binding?] = [messageID, aid]
        try db.run("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", lb)
        return aid
    }
}

/// Convenience: peek at the underlying Connection of a MessageStore for
/// fixture seeding. The vendored MessageStore init takes a Connection
/// directly, so the test holds onto its own reference.
final class FixtureScenario {
    let db: Connection
    let store: MessageStore

    init() throws {
        self.db = try Connection(.inMemory)
        try FixtureDB.createSchema(self.db)
        self.store = try MessageStore(connection: self.db, path: ":memory:")
    }
}

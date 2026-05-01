import Foundation
import SQLite
import Testing
@testable import ContactsCore
@testable import MessagesCore
@testable import ResolveCore

/// Local fixture-DB helpers (the canonical one lives in MessagesCoreTests but
/// can't be imported across test targets). Keep this minimal.
private enum FxDB {
    static func make() throws -> (Connection, MessageStore) {
        let db = try Connection(.inMemory)
        try db.execute("""
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT, guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER, attributedBody BLOB, thread_originator_guid TEXT, destination_caller_id TEXT, is_audio_message INTEGER, balloon_bundle_id TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            """)
        return (db, try MessageStore(connection: db, path: ":memory:"))
    }

    static func chat(_ db: Connection, identifier: String, guid: String? = nil, name: String? = nil) throws -> Int64 {
        let g = guid ?? "iMessage;-;\(identifier)"
        let b: [Binding?] = [identifier, g, name, "iMessage"]
        try db.run("INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES (?, ?, ?, ?)", b)
        return db.lastInsertRowid
    }

    static func handle(_ db: Connection, id: String) throws -> Int64 {
        let b: [Binding?] = [id]
        try db.run("INSERT INTO handle (id) VALUES (?)", b)
        return db.lastInsertRowid
    }

    static func link(_ db: Connection, chat: Int64, handle: Int64) throws {
        let b: [Binding?] = [chat, handle]
        try db.run("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", b)
    }

    static func msg(_ db: Connection, chat: Int64, handle: Int64, text: String, date: Date) throws {
        let dateNS = MessageStore.appleEpoch(date)
        let mb: [Binding?] = [handle, text, dateNS, UUID().uuidString]
        try db.run("INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (?, ?, ?, 0, 'iMessage', ?)", mb)
        let lb: [Binding?] = [chat, db.lastInsertRowid]
        try db.run("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", lb)
    }
}

private func makeContact(_ id: String, name: String, phones: [String], emails: [String]) -> Contact {
    return Contact(
        id: id,
        givenName: nil,
        familyName: nil,
        fullName: name,
        emails: emails.map { LabeledEmail(label: nil, value: $0) },
        phones: phones.map { LabeledPhone(label: nil, value: $0, raw: $0) }
    )
}

@Suite("Resolver — §4 cross-domain marquee scenarios")
struct ResolverTests {
    @Test("Mark Kropf has 3 phones, 2 chats → returns both, sorted DESC")
    func markAmbiguous() throws {
        let (db, store) = try FxDB.make()
        // Phones
        let p1 = "+14155551111", p2 = "+14155552222", p3 = "+14155553333"
        let e1 = "mark@example.com"
        let h1 = try FxDB.handle(db, id: p1)
        let h2 = try FxDB.handle(db, id: p2)
        let hE = try FxDB.handle(db, id: e1)

        let chatA = try FxDB.chat(db, identifier: p1)
        try FxDB.link(db, chat: chatA, handle: h1)
        try FxDB.msg(db, chat: chatA, handle: h1, text: "old", date: Date(timeIntervalSince1970: 1_700_000_000))

        let chatB = try FxDB.chat(db, identifier: p2)
        try FxDB.link(db, chat: chatB, handle: h2)
        try FxDB.link(db, chat: chatB, handle: hE)
        try FxDB.msg(db, chat: chatB, handle: h2, text: "new", date: Date(timeIntervalSince1970: 1_800_000_000))

        // Phone P3 has no chat — proves the resolver doesn't fabricate.
        _ = p3

        let fakeStore = FakeContactsStore()
        fakeStore.contacts = [makeContact("C1", name: "Mark Kropf", phones: [p1, p2, p3], emails: [e1])]

        let resolver = Resolver(contacts: fakeStore, messages: store, normalizer: KithPhoneNumberNormalizer())
        let target = try resolver.resolve("Mark Kropf")
        #expect(Set(target.chatIDs) == [chatA, chatB])
        #expect(target.candidates.count == 2)
        // DESC by lastMessageAt — chatB (1_800_000_000) first.
        #expect(target.candidates[0].chatId == chatB)
        #expect(target.candidates[1].chatId == chatA)
        #expect(target.resolvedFromContact?.id == "C1")
    }

    @Test("Email-only contact with one chat → success")
    func emailOnly() throws {
        let (db, store) = try FxDB.make()
        let h = try FxDB.handle(db, id: "mark@example.com")
        let c = try FxDB.chat(db, identifier: "mark@example.com")
        try FxDB.link(db, chat: c, handle: h)
        try FxDB.msg(db, chat: c, handle: h, text: "hi", date: Date())

        let fakeStore = FakeContactsStore()
        fakeStore.contacts = [makeContact("C2", name: "Em Aily", phones: [], emails: ["mark@example.com"])]

        let resolver = Resolver(contacts: fakeStore, messages: store, normalizer: KithPhoneNumberNormalizer())
        let target = try resolver.resolve("Em Aily")
        #expect(target.chatIDs == [c])
    }

    @Test("Same person reachable via phone + email in one group chat → DISTINCT one chat")
    func mixedHandlesSameChat() throws {
        let (db, store) = try FxDB.make()
        let p = "+14155554444"
        let e = "alice@example.com"
        let hP = try FxDB.handle(db, id: p)
        let hE = try FxDB.handle(db, id: e)
        let group = try FxDB.chat(db, identifier: "group")
        try FxDB.link(db, chat: group, handle: hP)
        try FxDB.link(db, chat: group, handle: hE)
        try FxDB.msg(db, chat: group, handle: hP, text: "hi", date: Date())

        let fakeStore = FakeContactsStore()
        fakeStore.contacts = [makeContact("C3", name: "Alice", phones: [p], emails: [e])]

        let resolver = Resolver(contacts: fakeStore, messages: store, normalizer: KithPhoneNumberNormalizer())
        let target = try resolver.resolve("Alice")
        #expect(target.chatIDs == [group])
    }

    @Test("--with chat-id:N resolves directly; bare int does not")
    func chatIDPrefix() throws {
        let (db, store) = try FxDB.make()
        let h = try FxDB.handle(db, id: "+14155555555")
        let c = try FxDB.chat(db, identifier: "+14155555555")
        try FxDB.link(db, chat: c, handle: h)
        try FxDB.msg(db, chat: c, handle: h, text: "hi", date: Date())

        let resolver = Resolver(contacts: FakeContactsStore(), messages: store, normalizer: KithPhoneNumberNormalizer())
        let target = try resolver.resolve("chat-id:\(c)")
        #expect(target.chatIDs == [c])

        // Bare int falls through. With c being a small integer (likely 1), it
        // becomes a name "1" (under 7 digits), so contactNotFound.
        do {
            _ = try resolver.resolve("\(c)")
            Issue.record("expected contactNotFound when bare int falls through to name lookup")
        } catch ResolverError.contactNotFound {
            // expected
        }
    }

    @Test("No match → contactNotFound (caller exits 3)")
    func noMatch() throws {
        let (_, store) = try FxDB.make()
        let resolver = Resolver(contacts: FakeContactsStore(), messages: store, normalizer: KithPhoneNumberNormalizer())
        do {
            _ = try resolver.resolve("Nonexistent Person")
            Issue.record("expected contactNotFound")
        } catch ResolverError.contactNotFound { }
    }

    @Test("Two contacts with same full name → contactAmbiguous (chat-resolution skipped)")
    func contactsAmbiguous() throws {
        let (_, store) = try FxDB.make()
        let fakeStore = FakeContactsStore()
        fakeStore.contacts = [
            makeContact("C-A", name: "John Smith", phones: ["+15550001"], emails: []),
            makeContact("C-B", name: "John Smith", phones: ["+15550002"], emails: []),
        ]
        let resolver = Resolver(contacts: fakeStore, messages: store, normalizer: KithPhoneNumberNormalizer())
        do {
            _ = try resolver.resolve("John Smith")
            Issue.record("expected contactAmbiguous")
        } catch ResolverError.contactAmbiguous(_, let ids, _) {
            #expect(Set(ids) == ["C-A", "C-B"])
        }
    }
}

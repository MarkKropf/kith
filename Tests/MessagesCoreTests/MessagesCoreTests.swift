import Foundation
import Testing
@testable import MessagesCore

@Suite("MessagesCore — fixture-backed integration")
struct MessagesCoreFixtureTests {
    @Test("listChats returns chats ordered by last-message DESC")
    func listChatsOrdering() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db

        let oldChat = try FixtureDB.insertChat(db, identifier: "+14155551111", guid: "iMessage;-;+14155551111")
        let oldHandle = try FixtureDB.insertHandle(db, id: "+14155551111")
        try FixtureDB.linkChatHandle(db, chatID: oldChat, handleID: oldHandle)
        try FixtureDB.insertMessage(db, chatID: oldChat, handleID: oldHandle, text: "old", date: Date(timeIntervalSince1970: 1_700_000_000))

        let newChat = try FixtureDB.insertChat(db, identifier: "+14155552222", guid: "iMessage;-;+14155552222")
        let newHandle = try FixtureDB.insertHandle(db, id: "+14155552222")
        try FixtureDB.linkChatHandle(db, chatID: newChat, handleID: newHandle)
        try FixtureDB.insertMessage(db, chatID: newChat, handleID: newHandle, text: "new", date: Date(timeIntervalSince1970: 1_800_000_000))

        let chats = try scenario.store.listChats(limit: 10)
        #expect(chats.count == 2)
        #expect(chats[0].id == newChat)
        #expect(chats[1].id == oldChat)
    }

    @Test("messages(chatID:limit:) filters out reaction tapbacks by default")
    func reactionsFiltered() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let chatID = try FixtureDB.insertChat(db, identifier: "+14155553333", guid: "iMessage;-;+14155553333")
        let h = try FixtureDB.insertHandle(db, id: "+14155553333")
        try FixtureDB.linkChatHandle(db, chatID: chatID, handleID: h)
        try FixtureDB.insertMessage(db, chatID: chatID, handleID: h, text: "hello", date: Date(timeIntervalSince1970: 1_700_000_001), guid: "MSG-A")
        // Reaction "loved" pointing at MSG-A.
        try FixtureDB.insertMessage(db, chatID: chatID, handleID: h, text: "Loved “hello”", date: Date(timeIntervalSince1970: 1_700_000_002), associatedGUID: "p:0/MSG-A", associatedType: 2000)

        let messagesNoReactions = try scenario.store.messages(chatID: chatID, limit: 10)
        #expect(messagesNoReactions.count == 1)
        #expect(messagesNoReactions[0].text == "hello")

        let withReactions = try scenario.store.messagesIncludingReactions(chatID: chatID, limit: 10, filter: nil, includeReactions: true)
        #expect(withReactions.count == 2)
    }

    @Test("attachments query joins through message_attachment_join")
    func attachmentsJoined() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let chatID = try FixtureDB.insertChat(db, identifier: "x", guid: "iMessage;-;x")
        let h = try FixtureDB.insertHandle(db, id: "x")
        try FixtureDB.linkChatHandle(db, chatID: chatID, handleID: h)
        let mID = try FixtureDB.insertMessage(db, chatID: chatID, handleID: h, text: "look", date: Date(timeIntervalSince1970: 1_700_000_010))
        try FixtureDB.insertAttachment(db, messageID: mID, filename: "/tmp/IMG.HEIC", totalBytes: 100)

        let attachments = try scenario.store.attachments(for: mID)
        #expect(attachments.count == 1)
        #expect(attachments[0].totalBytes == 100)
        #expect(attachments[0].uti == "public.heic")
    }

    @Test("apple-epoch round-trips via appleEpoch / appleDate")
    func appleEpochRoundTrip() throws {
        let scenario = try FixtureScenario()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let nanoseconds = MessageStore.appleEpoch(date)
        let restored = scenario.store.appleDate(from: nanoseconds)
        #expect(abs(restored.timeIntervalSince(date)) < 0.001)
    }

    @Test("chatsForIdentities matches handle.id case-insensitively")
    func chatsForIdentitiesNoCase() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let chatID = try FixtureDB.insertChat(db, identifier: "mark@example.com", guid: "iMessage;-;mark@example.com")
        let h = try FixtureDB.insertHandle(db, id: "Mark@Example.com")
        try FixtureDB.linkChatHandle(db, chatID: chatID, handleID: h)
        try FixtureDB.insertMessage(db, chatID: chatID, handleID: h, text: "hi", date: Date(timeIntervalSince1970: 1_700_000_020))

        let ids = try scenario.store.chatsForIdentities(["mark@example.com"])
        #expect(ids == [chatID])
    }

    @Test("chatID(forGUID:) round-trips an exact guid")
    func chatIDForGUID() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let chatID = try FixtureDB.insertChat(db, identifier: "+1", guid: "iMessage;-;THE_GUID")
        let resolved = try scenario.store.chatID(forGUID: "iMessage;-;THE_GUID")
        #expect(resolved == chatID)
        #expect((try scenario.store.chatID(forGUID: "missing")) == nil)
    }
}

@Suite("PhoneNumberNormalizer (vendored)")
struct PhoneNormalizerTests {
    @Test("US phones normalize to +1XXXXXXXXXX")
    func usPhones() {
        let n = PhoneNumberNormalizer()
        #expect(n.normalize("(415) 555-1212", region: "US") == "+14155551212")
        #expect(n.normalize("415-555-1212", region: "US") == "+14155551212")
    }

    @Test("garbage input round-trips unchanged")
    func garbage() {
        let n = PhoneNumberNormalizer()
        let garbage = "not a number"
        #expect(n.normalize(garbage, region: "US") == garbage)
    }
}

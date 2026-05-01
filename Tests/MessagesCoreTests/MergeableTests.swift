import Foundation
import SQLite
import Testing
@testable import MessagesCore

@Suite("kithMergeable filter — 1:1 shard union safety")
struct MergeableTests {
    @Test("Three 1:1 shards with the same canonical participant all merge")
    func happyPathThreeShards() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db

        let phone = "+14155551111"
        let h1 = try FixtureDB.insertHandle(db, id: phone)
        let h2 = try FixtureDB.insertHandle(db, id: phone)   // separate handle row, same id (different shard)
        let h3 = try FixtureDB.insertHandle(db, id: phone)

        // Three shards — chat_identifier exactly matches the phone, no
        // display_name, exactly one chat_handle_join row each.
        let s1 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);1")
        try FixtureDB.linkChatHandle(db, chatID: s1, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: s1, handleID: h1, text: "old", date: Date(timeIntervalSince1970: 1_700_000_000))

        let s2 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);2")
        try FixtureDB.linkChatHandle(db, chatID: s2, handleID: h2)
        try FixtureDB.insertMessage(db, chatID: s2, handleID: h2, text: "mid", date: Date(timeIntervalSince1970: 1_750_000_000))

        let s3 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);3")
        try FixtureDB.linkChatHandle(db, chatID: s3, handleID: h3)
        try FixtureDB.insertMessage(db, chatID: s3, handleID: h3, text: "new", date: Date(timeIntervalSince1970: 1_800_000_000))

        let result = try scenario.store.kithMergeable(chatIDs: [s1, s2, s3], identities: [phone])
        #expect(Set(result.merged) == [s1, s2, s3])
        #expect(result.leftover.isEmpty)
        #expect(result.service == "iMessage")
    }

    @Test("Group chat (display_name set OR multiple handles) is rejected")
    func groupChatRejected() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db

        let phone = "+14155551111"
        let other = "+14155552222"
        let h1 = try FixtureDB.insertHandle(db, id: phone)
        let h2 = try FixtureDB.insertHandle(db, id: other)

        let s1 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);1")
        try FixtureDB.linkChatHandle(db, chatID: s1, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: s1, handleID: h1, text: "1:1", date: Date())

        // Group chat: matches by chat_identifier=phone but has 2 chat_handle_join rows.
        let group = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;group", name: nil)
        try FixtureDB.linkChatHandle(db, chatID: group, handleID: h1)
        try FixtureDB.linkChatHandle(db, chatID: group, handleID: h2)
        try FixtureDB.insertMessage(db, chatID: group, handleID: h1, text: "group", date: Date())

        // Named chat: matches by chat_identifier=phone, exactly 1 handle, but display_name is set.
        let named = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;named", name: "Project Drillbit")
        try FixtureDB.linkChatHandle(db, chatID: named, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: named, handleID: h1, text: "named", date: Date())

        let result = try scenario.store.kithMergeable(chatIDs: [s1, group, named], identities: [phone])
        #expect(result.merged == [s1])
        #expect(Set(result.leftover) == [group, named])
    }

    @Test("Synthetic chat with non-matching chat_identifier (ThoughtGate-style) is rejected")
    func syntheticServiceChatRejected() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db

        let phone = "+14155551111"
        let h1 = try FixtureDB.insertHandle(db, id: phone)

        let s1 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);1")
        try FixtureDB.linkChatHandle(db, chatID: s1, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: s1, handleID: h1, text: "real", date: Date())

        // ThoughtGate-style: chat_identifier is a service token, not the
        // resolved phone, even though the resolved handle is the lone participant.
        let synth = try FixtureDB.insertChat(db, identifier: "ThoughtGate", guid: "iMessage;-;ThoughtGate")
        try FixtureDB.linkChatHandle(db, chatID: synth, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: synth, handleID: h1, text: "synth", date: Date())

        let result = try scenario.store.kithMergeable(chatIDs: [s1, synth], identities: [phone])
        #expect(result.merged == [s1])
        #expect(result.leftover == [synth])
    }

    @Test("Mixed services — only same-service shards merge with the freshest")
    func mixedServices() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let phone = "+14155551111"
        let h1 = try FixtureDB.insertHandle(db, id: phone)
        let h2 = try FixtureDB.insertHandle(db, id: phone)

        let imsg = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);1", service: "iMessage")
        try FixtureDB.linkChatHandle(db, chatID: imsg, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: imsg, handleID: h1, text: "imsg", date: Date(timeIntervalSince1970: 1_800_000_000), service: "iMessage")

        let sms = try FixtureDB.insertChat(db, identifier: phone, guid: "SMS;-;\(phone);1", service: "SMS")
        try FixtureDB.linkChatHandle(db, chatID: sms, handleID: h2)
        try FixtureDB.insertMessage(db, chatID: sms, handleID: h2, text: "sms", date: Date(timeIntervalSince1970: 1_700_000_000), service: "SMS")

        let result = try scenario.store.kithMergeable(chatIDs: [imsg, sms], identities: [phone])
        // Freshest first → iMessage canonical, SMS leftover.
        #expect(result.merged == [imsg])
        #expect(result.leftover == [sms])
        #expect(result.service == "iMessage")
    }

    @Test("messagesAcrossChats unions a chat-id set, sorted DESC, limited to N")
    func unionStream() throws {
        let scenario = try FixtureScenario()
        let db = scenario.db
        let phone = "+14155551111"
        let h1 = try FixtureDB.insertHandle(db, id: phone)
        let h2 = try FixtureDB.insertHandle(db, id: phone)

        let s1 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);1")
        try FixtureDB.linkChatHandle(db, chatID: s1, handleID: h1)
        try FixtureDB.insertMessage(db, chatID: s1, handleID: h1, text: "old-1", date: Date(timeIntervalSince1970: 1_700_000_001))
        try FixtureDB.insertMessage(db, chatID: s1, handleID: h1, text: "old-2", date: Date(timeIntervalSince1970: 1_700_000_002))

        let s2 = try FixtureDB.insertChat(db, identifier: phone, guid: "iMessage;-;\(phone);2")
        try FixtureDB.linkChatHandle(db, chatID: s2, handleID: h2)
        try FixtureDB.insertMessage(db, chatID: s2, handleID: h2, text: "new-1", date: Date(timeIntervalSince1970: 1_800_000_001))
        try FixtureDB.insertMessage(db, chatID: s2, handleID: h2, text: "new-2", date: Date(timeIntervalSince1970: 1_800_000_002))

        let union = try scenario.store.messagesAcrossChats([s1, s2], limit: 3)
        #expect(union.count == 3)
        // DESC by date — top three are: new-2, new-1, old-2.
        #expect(union[0].text == "new-2")
        #expect(union[1].text == "new-1")
        #expect(union[2].text == "old-2")
    }
}

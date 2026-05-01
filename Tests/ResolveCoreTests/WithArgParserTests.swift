import Testing
@testable import ResolveCore

@Suite("WithArgParser — first-match-wins form sniffing")
struct WithArgParserTests {
    @Test("chat-id: prefix → chatID (single)")
    func chatID() {
        #expect(WithArgParser.parse("chat-id:42") == .chatID([42]))
    }

    @Test("chat-id: prefix accepts comma-separated list (merge recovery target)")
    func chatIDList() {
        #expect(WithArgParser.parse("chat-id:1,4,7,12") == .chatID([1, 4, 7, 12]))
        #expect(WithArgParser.parse("chat-id:1, 2, 3") == .chatID([1, 2, 3]))
    }

    @Test("malformed comma-list → invalid")
    func malformedList() {
        #expect(WithArgParser.parse("chat-id:1,abc,3") == .invalid("chat-id:1,abc,3"))
        #expect(WithArgParser.parse("chat-id:,") == .invalid("chat-id:,"))
    }

    @Test("chat-guid: prefix → chatGUID")
    func chatGUID() {
        #expect(WithArgParser.parse("chat-guid:iMessage;-;+1") == .chatGUID("iMessage;-;+1"))
    }

    @Test("UUID-shaped → cnContactID")
    func uuid() {
        let id = "0AB81E1A-DEAD-BEEF-CAFE-000000000001"
        #expect(WithArgParser.parse(id) == .cnContactID(id))
    }

    @Test("phone-shaped → phone")
    func phone() {
        switch WithArgParser.parse("(415) 555-1212") {
        case .phone(let p): #expect(p == "(415) 555-1212")
        default: Issue.record("expected .phone")
        }
        switch WithArgParser.parse("+14155551212") {
        case .phone(let p): #expect(p == "+14155551212")
        default: Issue.record("expected .phone")
        }
    }

    @Test("email-shaped → email (lowercased)")
    func email() {
        switch WithArgParser.parse("Mark@Example.COM") {
        case .email(let e): #expect(e == "mark@example.com")
        default: Issue.record("expected .email")
        }
    }

    @Test("name fallback")
    func name() {
        switch WithArgParser.parse("Mark Kropf") {
        case .name(let n): #expect(n == "Mark Kropf")
        default: Issue.record("expected .name")
        }
    }

    @Test("bare integer is NOT chatID — falls through to phone or name")
    func bareIntNotChatID() {
        // 7+ digits: phone. Fewer: name.
        switch WithArgParser.parse("12") {
        case .name(let n): #expect(n == "12")
        default: Issue.record("expected .name for 2-digit string")
        }
        switch WithArgParser.parse("1234567") {
        case .phone(let p): #expect(p == "1234567")
        default: Issue.record("expected .phone for 7-digit bare integer")
        }
    }

    @Test("malformed chat-id → invalid")
    func malformedChatID() {
        #expect(WithArgParser.parse("chat-id:abc") == .invalid("chat-id:abc"))
        #expect(WithArgParser.parse("chat-id:0") == .invalid("chat-id:0"))
        #expect(WithArgParser.parse("chat-id:-3") == .invalid("chat-id:-3"))
    }

    @Test("empty input → invalid")
    func emptyInput() {
        #expect(WithArgParser.parse("") == .invalid(""))
    }
}

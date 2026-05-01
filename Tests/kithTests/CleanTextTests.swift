import Foundation
import KithAgentProtocol
import MessagesCore
import Testing
@testable import kith

@Suite("cleanMessageText — strip U+FFFD/U+0000, replace U+FFFC")
struct CleanTextTests {
    @Test("strips U+FFFD and U+0000")
    func stripsNoise() {
        let raw = "hello\u{FFFD}\u{0000} world"
        #expect(cleanMessageText(raw, attachments: nil) == "hello world")
    }

    @Test("replaces U+FFFC with [attachment] when no attachments provided")
    func replacesObjectPlaceholderWithGeneric() {
        let raw = "\u{FFFC}\nhi"
        #expect(cleanMessageText(raw, attachments: nil) == "[attachment]\nhi")
    }

    @Test("replaces U+FFFC with [attachment: name] using transferName order")
    func replacesObjectPlaceholderWithName() {
        let metas = [
            AttachmentMeta(filename: "/x/a.heic", transferName: "IMG_001.HEIC", uti: "public.heic", mimeType: "image/heic", totalBytes: 1, isSticker: false, originalPath: "/x/a.heic", missing: false),
            AttachmentMeta(filename: "/x/b.mov", transferName: "VID_001.MOV", uti: "public.mpeg-4", mimeType: "video/mp4", totalBytes: 2, isSticker: false, originalPath: "/x/b.mov", missing: false),
        ]
        let raw = "look! \u{FFFC} and \u{FFFC} done"
        #expect(cleanMessageText(raw, attachments: metas) == "look! [attachment: IMG_001.HEIC] and [attachment: VID_001.MOV] done")
    }

    @Test("real-world sample with all three attributedBody artifacts")
    func realWorldExample() {
        let raw = "\u{FFFD}\u{FFFD}\u{0000}\u{FFFC}\nThis is the view into agent execution"
        let result = cleanMessageText(raw, attachments: nil)
        #expect(result == "[attachment]\nThis is the view into agent execution")
    }

    @Test("falls back to filename when transferName is empty")
    func fallbackToFilename() {
        let metas = [
            AttachmentMeta(filename: "/x/a.heic", transferName: "", uti: "public.heic", mimeType: "image/heic", totalBytes: 1, isSticker: false, originalPath: "/x/a.heic", missing: false),
        ]
        let raw = "\u{FFFC}"
        #expect(cleanMessageText(raw, attachments: metas) == "[attachment: /x/a.heic]")
    }

    @Test("idempotent on clean input")
    func idempotent() {
        let raw = "Hello, world! 👋"
        #expect(cleanMessageText(raw, attachments: nil) == raw)
    }

    @Test("--raw-text round-trips raw text via cleanText: false path")
    func rawPathPreserves() {
        // Drive the makeKithMessage helper directly with cleanText: false.
        let m = Message(
            rowID: 1,
            chatID: 2,
            sender: "+1",
            text: "\u{FFFD}\u{FFFC}body",
            date: Date(),
            isFromMe: false,
            service: "iMessage",
            handleID: nil,
            attachmentsCount: 1
        )
        let kept = makeKithMessage(m, chatService: "iMessage", attachments: nil, cleanText: false)
        #expect(kept.text == "\u{FFFD}\u{FFFC}body")
        let cleaned = makeKithMessage(m, chatService: "iMessage", attachments: nil, cleanText: true)
        #expect(cleaned.text == "[attachment]body")
    }
}

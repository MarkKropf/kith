import Foundation
import MessagesCore
import Testing
@testable import kith

@Suite("InlineImageRenderer — protocol detection and escape generation")
struct InlineImageTests {
    @Test("VS Code → iTerm2 protocol")
    func vscode() {
        let env = ["TERM_PROGRAM": "vscode"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .iTerm2)
    }

    @Test("iTerm.app → iTerm2 protocol")
    func iterm() {
        let env = ["TERM_PROGRAM": "iTerm.app"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .iTerm2)
    }

    @Test("WezTerm → iTerm2 protocol (it speaks both, prefer iTerm2)")
    func wezterm() {
        let env = ["TERM_PROGRAM": "WezTerm"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .iTerm2)
    }

    @Test("xterm-ghostty → Kitty protocol")
    func ghostty() {
        let env = ["TERM": "xterm-ghostty"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .kitty)
    }

    @Test("xterm-kitty → Kitty protocol")
    func kitty() {
        let env = ["TERM": "xterm-kitty"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .kitty)
    }

    @Test("KITTY_WINDOW_ID set → Kitty protocol")
    func kittyEnv() {
        let env = ["KITTY_WINDOW_ID": "42"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .kitty)
    }

    @Test("Apple Terminal.app → unsupported")
    func appleTerminal() {
        let env = ["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"]
        #expect(InlineImageRenderer.detectProtocol(env: env) == .unsupported)
    }

    @Test("empty env → unsupported")
    func emptyEnv() {
        #expect(InlineImageRenderer.detectProtocol(env: [:]) == .unsupported)
    }

    @Test("canRender filters non-image attachments")
    func canRender() {
        let png = AttachmentMeta(filename: "/x/a.png", transferName: "a.png", uti: "public.png", mimeType: "image/png", totalBytes: 1, isSticker: false, originalPath: "/x/a.png", missing: false)
        let mov = AttachmentMeta(filename: "/x/clip.mov", transferName: "clip.mov", uti: "com.apple.quicktime-movie", mimeType: "video/quicktime", totalBytes: 1, isSticker: false, originalPath: "/x/clip.mov", missing: false)
        let missing = AttachmentMeta(filename: "/x/y.png", transferName: "y.png", uti: "public.png", mimeType: "image/png", totalBytes: 1, isSticker: false, originalPath: "/x/y.png", missing: true)
        #expect(InlineImageRenderer.canRender(meta: png) == true)
        #expect(InlineImageRenderer.canRender(meta: mov) == false)
        #expect(InlineImageRenderer.canRender(meta: missing) == false)
    }

    @Test("canRender accepts known image extensions even when MIME is empty")
    func extensionFallback() {
        let heic = AttachmentMeta(filename: "/x/IMG.HEIC", transferName: "IMG.HEIC", uti: "", mimeType: "", totalBytes: 1, isSticker: false, originalPath: "/x/IMG.HEIC", missing: false)
        #expect(InlineImageRenderer.canRender(meta: heic) == true)
    }

    @Test("iTerm2 escape: starts with OSC 1337, base64 inline, ends BEL")
    func iTerm2EscapeShape() throws {
        let path = try writeTempPNG()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let escape = InlineImageRenderer.iTerm2Escape(path: path) else {
            Issue.record("nil escape"); return
        }
        #expect(escape.hasPrefix("\u{1B}]1337;File="))
        #expect(escape.contains("inline=1"))
        #expect(escape.contains("\u{07}"))
    }

    @Test("Kitty escape: chunked base64, terminates with m=0")
    func kittyEscapeShape() throws {
        let path = try writeTempPNG(byteCount: 12_000)   // forces chunking
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let escape = InlineImageRenderer.kittyEscape(path: path) else {
            Issue.record("nil escape"); return
        }
        #expect(escape.hasPrefix("\u{1B}_Ga=T,f=100,m="))
        // Must end with a final-chunk marker (m=0;...).
        #expect(escape.contains("\u{1B}_Gm=0;"))
        // Must contain at least one continuation chunk for a 12kB payload.
        #expect(escape.contains("\u{1B}_Gm=1;"))
    }

    /// Write a tiny PNG-shaped file (just the 8-byte signature + filler) to
    /// the temp dir for escape-sequence tests. Not a valid PNG, but the
    /// renderer doesn't decode — it just reads bytes and base64-encodes.
    private func writeTempPNG(byteCount: Int = 64) throws -> String {
        let path = NSTemporaryDirectory() + "kith-test-\(UUID().uuidString).png"
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        while bytes.count < byteCount { bytes.append(0xAA) }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }
}

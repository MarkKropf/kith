import Foundation
import KithAgentProtocol

/// Inline image rendering for `kith history --inline`.
///
/// Detection priority (env-var sniffing):
///   - `TERM_PROGRAM=vscode`     → iTerm2 protocol (VS Code's integrated
///                                 terminal speaks it since v1.83).
///   - `TERM_PROGRAM=iTerm.app`  → iTerm2 protocol.
///   - `TERM_PROGRAM=WezTerm`    → iTerm2 protocol.
///   - `TERM=xterm-ghostty`      → Kitty graphics protocol.
///   - `TERM=xterm-kitty` or
///     `KITTY_WINDOW_ID` set     → Kitty graphics protocol.
///   - else                      → unsupported, caller falls back to text.
///
/// HEIC/HEIF/WEBP attachments are run through `/usr/bin/sips` to produce a
/// PNG before transmission. Non-image attachments are skipped.
enum InlineImageRenderer {
    enum InlineProtocol: String {
        case iTerm2
        case kitty
        case unsupported
    }

    static func detectProtocol(env: [String: String] = ProcessInfo.processInfo.environment) -> InlineProtocol {
        // Explicit override — the diagnostic / power-user escape hatch.
        if let raw = env["KITH_INLINE_PROTOCOL"]?.lowercased() {
            switch raw {
            case "iterm2", "iterm": return .iTerm2
            case "kitty", "ghostty": return .kitty
            case "none", "off", "unsupported": return .unsupported
            default: break
            }
        }
        // Ghostty-specific. Ghostty does not set TERM_PROGRAM, and TERM may be
        // xterm-256color unless the user installed its terminfo. Sniff its
        // dedicated env vars first.
        if env["GHOSTTY_RESOURCES_DIR"] != nil
            || env["GHOSTTY_BIN_DIR"] != nil
            || env["GHOSTTY_VERSION"] != nil {
            return .kitty
        }
        if let p = env["TERM_PROGRAM"] {
            switch p {
            case "vscode", "iTerm.app", "WezTerm":
                return .iTerm2
            case "ghostty", "Ghostty":
                return .kitty
            default:
                break
            }
        }
        if let term = env["TERM"] {
            if term == "xterm-ghostty" || term == "xterm-kitty" { return .kitty }
        }
        if env["KITTY_WINDOW_ID"] != nil { return .kitty }
        return .unsupported
    }

    /// Whether to emit per-skip diagnostic notes. Off by default; opt in via
    /// `KITH_DEBUG=1` so the inline path stays quiet for normal use.
    static var debugEnabled: Bool {
        return ProcessInfo.processInfo.environment["KITH_DEBUG"] == "1"
    }

    static func isStdoutTTY() -> Bool {
        return isatty(fileno(stdout)) != 0
    }

    /// Whether the attachment is a still image that any of our supported
    /// protocols can render (after optional sips conversion).
    static func canRender(attachment a: KithAttachment) -> Bool {
        if a.missing { return false }
        let mime = a.mimeType.lowercased()
        let imageMimes: Set<String> = [
            "image/jpeg", "image/jpg", "image/png", "image/gif",
            "image/heic", "image/heif", "image/webp",
        ]
        if imageMimes.contains(mime) { return true }
        let name = (a.transferName.isEmpty ? a.filename : a.transferName).lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".webp"]
            .contains { name.hasSuffix($0) }
    }

    /// Build the escape sequence(s) that draw the image; nil when the
    /// attachment cannot be rendered (file missing, unsupported MIME,
    /// conversion failed, terminal protocol unsupported).
    static func render(attachment a: KithAttachment, protocol p: InlineProtocol) -> String? {
        if !canRender(attachment: a) {
            debugLog("skip \(a.transferName.isEmpty ? a.filename : a.transferName): not a renderable image (mime=\(a.mimeType), missing=\(a.missing))")
            return nil
        }
        if p == .unsupported {
            debugLog("skip \(a.transferName): terminal protocol unsupported")
            return nil
        }
        let path = a.originalPath
        guard !path.isEmpty else {
            debugLog("skip \(a.transferName): originalPath is empty")
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else {
            debugLog("skip \(a.transferName): file does not exist at \(path)")
            return nil
        }

        let lower = path.lowercased()
        let needsConversion: Bool
        switch p {
        case .kitty:
            // Kitty graphics protocol's `f=100` is PNG-only; convert
            // everything else.
            needsConversion = !lower.hasSuffix(".png")
        case .iTerm2:
            // iTerm2 protocol supports PNG/JPEG/GIF natively. Convert the
            // formats Apple ships in iMessage that iTerm2 can't decode.
            needsConversion = lower.hasSuffix(".heic")
                || lower.hasSuffix(".heif")
                || lower.hasSuffix(".webp")
        case .unsupported:
            return nil
        }

        let sourcePath: String
        if needsConversion {
            guard let converted = sipsConvertToPNG(path) else {
                debugLog("skip \(a.transferName): sips conversion failed for \(path)")
                return nil
            }
            sourcePath = converted
        } else {
            sourcePath = path
        }

        switch p {
        case .iTerm2:
            return iTerm2Escape(path: sourcePath)
        case .kitty:
            return kittyEscape(path: sourcePath)
        case .unsupported:
            return nil
        }
    }

    private static func debugLog(_ message: String) {
        guard debugEnabled else { return }
        var stderr = StderrStream()
        print("kith: inline-debug: \(message)", to: &stderr)
    }

    /// Run `sips -s format png <input> --out <tmp>` and return the temp path
    /// on success. The caller is expected NOT to delete the temp until the
    /// terminal has consumed the escape sequence. We don't garbage-collect —
    /// macOS clears /tmp on reboot, and individual files are tiny.
    private static func sipsConvertToPNG(_ path: String) -> String? {
        let tmp = NSTemporaryDirectory() + "kith-img-\(UUID().uuidString).png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-s", "format", "png", path, "--out", tmp]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: tmp)
            else { return nil }
            return tmp
        } catch {
            return nil
        }
    }

    /// iTerm2 inline-image escape (also accepted by VS Code's terminal and
    /// WezTerm). Inline base64 — works regardless of working directory.
    static func iTerm2Escape(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let dataB64 = data.base64EncodedString()
        let nameUTF8 = (path as NSString).lastPathComponent.data(using: .utf8) ?? Data()
        let nameB64 = nameUTF8.base64EncodedString()
        return "\u{1B}]1337;File=name=\(nameB64);size=\(data.count);inline=1:\(dataB64)\u{07}\n"
    }

    /// Kitty graphics protocol escape (also accepted by Ghostty). Uses
    /// chunked base64 transmission (`m=1` until the last chunk is `m=0`),
    /// max 4096 base64 chars per chunk.
    static func kittyEscape(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let base64 = data.base64EncodedString()
        let chunkSize = 4096
        var out = ""
        var offset = 0
        var isFirst = true
        let total = base64.count
        while offset < total {
            let end = min(offset + chunkSize, total)
            let chunk = base64[base64.index(base64.startIndex, offsetBy: offset)..<base64.index(base64.startIndex, offsetBy: end)]
            let m = (end == total) ? "0" : "1"
            if isFirst {
                out += "\u{1B}_Ga=T,f=100,m=\(m);\(chunk)\u{1B}\\"
                isFirst = false
            } else {
                out += "\u{1B}_Gm=\(m);\(chunk)\u{1B}\\"
            }
            offset = end
        }
        out += "\n"
        return out
    }
}

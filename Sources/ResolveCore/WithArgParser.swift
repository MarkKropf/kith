import Foundation

/// Parsed form of a `--with` value. The parser does not look anything up
/// — it just classifies. Bare integers are NEVER chat IDs; the `chat-id:`
/// prefix is mandatory (§4.1).
///
/// `chat-id:` accepts either a single ROWID (`chat-id:42`) or a
/// comma-separated list (`chat-id:1,4,7,12`). The list form is the recovery
/// target offered by the §3.8 ambiguity envelope when `--merge` partially
/// resolves a 1:1 conversation across rotated shards.
public enum WithArg: Sendable, Equatable {
    case chatID([Int64])
    case chatGUID(String)
    case cnContactID(String)
    case phone(String)
    case email(String)
    case name(String)
    case invalid(String)
}

public enum WithArgParser {
    /// First match wins; the order encodes priority.
    public static func parse(_ raw: String) -> WithArg {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .invalid(raw) }

        if let suffix = s.dropPrefix("chat-id:") {
            let parts = suffix.split(separator: ",", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { return .invalid(raw) }
            var ids: [Int64] = []
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let n = Int64(trimmed), n > 0 else { return .invalid(raw) }
                ids.append(n)
            }
            return .chatID(ids)
        }
        if let suffix = s.dropPrefix("chat-guid:") {
            if suffix.isEmpty { return .invalid(raw) }
            return .chatGUID(String(suffix))
        }
        if isUUIDShape(s) {
            return .cnContactID(s)
        }
        if isPhoneShape(s) {
            return .phone(s)
        }
        if isEmailShape(s) {
            return .email(s.lowercased())
        }
        return .name(s)
    }

    static func isUUIDShape(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        for ch in s {
            if ch == "-" { continue }
            // CN identifiers are upper-case hex; the §4.1 pattern is uppercase only.
            if !ch.isHexDigit || ch.isLowercase {
                return false
            }
        }
        return true
    }

    static func isPhoneShape(_ s: String) -> Bool {
        // ^\+?[0-9 ()\-.]{7,}$ with >=7 digits
        let allowed: Set<Character> = ["+", " ", "(", ")", "-", ".",
                                       "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        guard s.count >= 7 else { return false }
        var sawPlusFirst = false
        var digitCount = 0
        for (i, ch) in s.enumerated() {
            if ch == "+" {
                if i != 0 { return false }
                sawPlusFirst = true
                continue
            }
            if !allowed.contains(ch) { return false }
            if ch.isNumber { digitCount += 1 }
        }
        _ = sawPlusFirst
        return digitCount >= 7
    }

    static func isEmailShape(_ s: String) -> Bool {
        guard let at = s.firstIndex(of: "@") else { return false }
        guard at != s.startIndex, s.index(after: at) < s.endIndex else { return false }
        let local = s[..<at]
        let domain = s[s.index(after: at)...]
        guard !local.isEmpty, domain.contains(".") else { return false }
        // Reject whitespace.
        if s.contains(where: { $0.isWhitespace }) { return false }
        return true
    }
}

private extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("A"..."F").contains(self) || ("a"..."f").contains(self)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard self.hasPrefix(prefix) else { return nil }
        return self.dropFirst(prefix.count)
    }
}

import Foundation

/// Strips Contacts framework's `_$!<...>!$_` cruft from labels and lowercases
/// the inner token. Unknown labels pass through lowercased. Empty / nil → nil.
public enum LabelNormalizer {
    public static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = "_$!<"
        if trimmed.hasPrefix(pattern) {
            let afterPrefix = trimmed.dropFirst(pattern.count)
            if let endRange = afterPrefix.range(of: ">!$_") {
                return String(afterPrefix[..<endRange.lowerBound]).lowercased()
            }
        }
        return trimmed.lowercased()
    }
}

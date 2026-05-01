// Vendored from https://github.com/steipete/imsg (MIT)
// Original copyright © Peter Steinberger. See THIRD_PARTY_NOTICES.md.
// Do not edit in-place; see scripts/vendor-sync.sh for upstream syncs.
import Foundation

enum ISO8601Parser {
  static func parse(_ value: String) -> Date? {
    if value.isEmpty { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
  }

  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

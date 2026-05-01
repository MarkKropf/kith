// Vendored from https://github.com/steipete/imsg (MIT)
// Original copyright © Peter Steinberger. See THIRD_PARTY_NOTICES.md.
// Do not edit in-place; see scripts/vendor-sync.sh for upstream syncs.
import Foundation

public struct MessageFilter: Sendable, Equatable {
  public let participants: [String]
  public let startDate: Date?
  public let endDate: Date?

  public init(participants: [String] = [], startDate: Date? = nil, endDate: Date? = nil) {
    self.participants = participants
    self.startDate = startDate
    self.endDate = endDate
  }

  public static func fromISO(participants: [String], startISO: String?, endISO: String?) throws
    -> MessageFilter
  {
    let start = startISO.flatMap { ISO8601Parser.parse($0) }
    if let startISO, start == nil {
      throw IMsgError.invalidISODate(startISO)
    }
    let end = endISO.flatMap { ISO8601Parser.parse($0) }
    if let endISO, end == nil {
      throw IMsgError.invalidISODate(endISO)
    }
    return MessageFilter(participants: participants, startDate: start, endDate: end)
  }

  public func allows(_ message: Message) -> Bool {
    if let startDate, message.date < startDate { return false }
    if let endDate, message.date >= endDate { return false }
    if !participants.isEmpty {
      var match = false
      for participant in participants {
        if participant.caseInsensitiveCompare(message.sender) == .orderedSame {
          match = true
          break
        }
      }
      if !match { return false }
    }
    return true
  }
}

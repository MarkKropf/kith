// Vendored from https://github.com/steipete/imsg (MIT)
// Original copyright © Peter Steinberger. See THIRD_PARTY_NOTICES.md.
// Do not edit in-place; see scripts/vendor-sync.sh for upstream syncs.
import Foundation
import PhoneNumberKit

final class PhoneNumberNormalizer {
  private let phoneNumberUtility = PhoneNumberUtility()

  func normalize(_ input: String, region: String) -> String {
    do {
      let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
      return phoneNumberUtility.format(number, toType: .e164)
    } catch {
      return input
    }
  }
}

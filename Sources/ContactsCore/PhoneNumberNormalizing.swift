import Foundation

/// Strategy for normalizing phone numbers to E.164. The `region` is the ISO-2
/// country code used as the default when an input lacks an explicit country
/// prefix. Implementations must return the original input on parse failure
/// (callers fall back to substring / raw-digit matching).
public protocol PhoneNumberNormalizing: Sendable {
    func normalize(_ input: String, region: String) -> String
}

/// Identity normalizer used when no PhoneNumberKit-backed normalizer is
/// available (e.g. unit tests that don't care about parsing). Returns input
/// unchanged.
public struct IdentityPhoneNumberNormalizer: PhoneNumberNormalizing {
    public init() {}
    public func normalize(_ input: String, region _: String) -> String { input }
}

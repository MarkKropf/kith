import Foundation

/// Public wrapper around the vendored module-internal `PhoneNumberNormalizer`
/// so other modules (ContactsCore protocol adopters, Resolver) can use the
/// PhoneNumberKit-backed normalization without depending on the upstream
/// type directly.
public final class KithPhoneNumberNormalizer: @unchecked Sendable {
    private let inner = PhoneNumberNormalizer()
    public init() {}
    public func normalize(_ input: String, region: String) -> String {
        return inner.normalize(input, region: region)
    }
}

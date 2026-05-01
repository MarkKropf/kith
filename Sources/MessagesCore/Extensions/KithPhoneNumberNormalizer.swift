import Foundation
import PhoneNumberKit

/// Public wrapper around `PhoneNumberKit.PhoneNumberUtility`. Used by both
/// MessagesCore consumers and ContactsCore protocol adopters via the
/// `PhoneNumberNormalizing` conformance in ResolveCore.
///
/// Why we don't use the vendored `PhoneNumberNormalizer` (in this module
/// alongside imsg): SwiftPM's resource accessor for PhoneNumberKit looks for
/// `PhoneNumberMetadata.json` at `Bundle.main.bundleURL/PhoneNumberKit_…
/// .bundle/`. For a SwiftPM-built executable run standalone (e.g. the CLI's
/// libexec/kith), that path is `libexec/PhoneNumberKit_….bundle/` and works
/// fine. But for an executable run inside a `.app` (kith-agent inside
/// `Kith.app/Contents/MacOS/`), `Bundle.main.bundleURL` is the `.app`'s URL
/// — i.e. `/Applications/Kith.app/` — and the bundle naturally lives at
/// `Contents/Resources/`, which the SwiftPM accessor doesn't check. Anything
/// at the `.app` root is also rejected by codesign as "unsealed contents."
///
/// Solution: bypass `Bundle.module` entirely. Construct `PhoneNumberUtility`
/// with a custom `metadataCallback` that searches the four locations the
/// JSON is realistically present in across all our distribution shapes
/// (.app, libexec wrapper, dev `.build/release/`, dev test bundle).
public final class KithPhoneNumberNormalizer: @unchecked Sendable {
    private let utility: PhoneNumberUtility

    public init() {
        self.utility = PhoneNumberUtility(metadataCallback: Self.loadMetadata)
    }

    public func normalize(_ input: String, region: String) -> String {
        do {
            let number = try utility.parse(input, withRegion: region, ignoreType: true)
            return utility.format(number, toType: .e164)
        } catch {
            return input
        }
    }

    /// Resolve `PhoneNumberMetadata.json`. Tries (in order):
    ///   1. `Bundle.main.resourceURL/PhoneNumberKit_PhoneNumberKit.bundle/…`
    ///      — matches an `.app` install: agent inside Kith.app finds the
    ///      bundle in `Contents/Resources/`.
    ///   2. `Bundle.main.bundleURL/PhoneNumberKit_PhoneNumberKit.bundle/…`
    ///      — matches the standalone-CLI layout: kith binary in libexec/
    ///      finds the bundle as a sibling.
    ///   3. The class's own bundle's `resourceURL` — covers test runs and
    ///      framework-style distribution.
    ///   4. Falls through to PhoneNumberKit's own default callback (which
    ///      uses `Bundle.module`) so dev builds running directly from
    ///      `.build/release/` still work without changes.
    private static func loadMetadata() throws -> Data? {
        let bundleName = "PhoneNumberKit_PhoneNumberKit.bundle"
        let metadataName = "PhoneNumberMetadata.json"

        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName).appendingPathComponent(metadataName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName).appendingPathComponent(metadataName),
            Bundle(for: BundleFinder.self).resourceURL?.appendingPathComponent(bundleName).appendingPathComponent(metadataName),
        ]

        for candidate in candidates {
            guard let url = candidate else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                return try Data(contentsOf: url)
            }
        }
        // Last resort: PhoneNumberKit's default lookup.
        return try PhoneNumberUtility.defaultMetadataCallback()
    }
}

private final class BundleFinder {}

import Testing
@testable import ContactsCore

@Suite("LabelNormalizer")
struct LabelNormalizerTests {
    @Test("strips _$!<...>!$_ wrapper and lowercases")
    func wrapperStripped() {
        #expect(LabelNormalizer.normalize("_$!<Mobile>!$_") == "mobile")
        #expect(LabelNormalizer.normalize("_$!<Home>!$_") == "home")
        #expect(LabelNormalizer.normalize("_$!<Work>!$_") == "work")
    }

    @Test("unknown labels pass through lowercased")
    func unknownPassthrough() {
        #expect(LabelNormalizer.normalize("Custom") == "custom")
        #expect(LabelNormalizer.normalize("iPhone") == "iphone")
    }

    @Test("nil and empty become nil")
    func emptyInputs() {
        #expect(LabelNormalizer.normalize(nil) == nil)
        #expect(LabelNormalizer.normalize("") == nil)
        #expect(LabelNormalizer.normalize("   ") == nil)
    }

    @Test("malformed wrapper still passes through")
    func malformedWrapper() {
        // Missing closing — fall back to lowercased.
        #expect(LabelNormalizer.normalize("_$!<NoCloser") == "_$!<nocloser")
    }
}

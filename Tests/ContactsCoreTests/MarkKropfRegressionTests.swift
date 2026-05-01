import Foundation
import Testing
@testable import ContactsCore

@Suite("Mark Kropf regression — JSON round-trip with tabs and newlines")
struct MarkKropfRegressionTests {
    @Test("Contact with tab in address and newline in nickname survives JSON encode + decode")
    func tabAndNewlineRoundTrip() throws {
        let contact = Contact(
            id: "0AB81E1A-DEAD-BEEF-CAFE-000000000001",
            givenName: "Mark",
            familyName: "Kropf",
            fullName: "Mark Kropf",
            nickname: "Mark\nthe second",   // newline
            emails: [LabeledEmail(label: "work", value: "mark@example.com")],
            phones: [LabeledPhone(label: "mobile", value: "+14155551212", raw: "(415) 555-1212")],
            organization: "Supaku",
            jobTitle: "Founder",
            birthday: PartialDate(year: nil, month: 4, day: 12),
            addresses: [LabeledAddress(
                label: "home",
                street: "1\tMain St",   // tab
                city: "SF",
                state: "CA",
                postalCode: "94110",
                country: "USA",
                isoCountryCode: "us"
            )]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(contact)
        let decoder = JSONDecoder()
        let round = try decoder.decode(Contact.self, from: data)
        #expect(round == contact)
        // The encoded payload must not contain a literal tab character —
        // it must escape to \t. (CoreFoundation's JSON encoder does this
        // by default but assert it explicitly so a regression breaks
        // loudly.)
        let s = String(decoding: data, as: UTF8.self)
        #expect(!s.contains("\t"))
        #expect(s.contains("\\t"))
        #expect(!s.contains("\n"))
        #expect(s.contains("\\n"))
    }
}

import Foundation

public struct Contact: Sendable, Equatable, Codable {
    public let id: String
    public let givenName: String?
    public let familyName: String?
    public let fullName: String
    public let nickname: String?
    public let emails: [LabeledEmail]
    public let phones: [LabeledPhone]
    public let organization: String?
    public let jobTitle: String?
    public let birthday: PartialDate?
    public let addresses: [LabeledAddress]

    public init(
        id: String,
        givenName: String? = nil,
        familyName: String? = nil,
        fullName: String,
        nickname: String? = nil,
        emails: [LabeledEmail] = [],
        phones: [LabeledPhone] = [],
        organization: String? = nil,
        jobTitle: String? = nil,
        birthday: PartialDate? = nil,
        addresses: [LabeledAddress] = []
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.fullName = fullName
        self.nickname = nickname
        self.emails = emails
        self.phones = phones
        self.organization = organization
        self.jobTitle = jobTitle
        self.birthday = birthday
        self.addresses = addresses
    }
}

public struct LabeledEmail: Sendable, Equatable, Codable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

public struct LabeledPhone: Sendable, Equatable, Codable {
    public let label: String?
    public let value: String
    public let raw: String

    public init(label: String?, value: String, raw: String) {
        self.label = label
        self.value = value
        self.raw = raw
    }
}

public struct LabeledAddress: Sendable, Equatable, Codable {
    public let label: String?
    public let street: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let country: String?
    public let isoCountryCode: String?

    public init(
        label: String?,
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?,
        country: String?,
        isoCountryCode: String?
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }
}

/// Birthday with optional year (professional contacts often store month+day
/// without a year).
public struct PartialDate: Sendable, Equatable, Codable {
    public let year: Int?
    public let month: Int
    public let day: Int

    public init(year: Int?, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

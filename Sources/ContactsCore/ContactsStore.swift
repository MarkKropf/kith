import Contacts
import Foundation

public enum ContactsAuthorizationStatus: String, Sendable, Codable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case granted
}

public enum ContactsError: Error, Sendable {
    case permissionDenied
    case notFound(String)
    case ambiguous(String, candidates: [Contact])
}

public struct ContactsQuery: Sendable {
    public var name: String?
    public var email: String?
    public var phone: String?
    public var organization: String?
    /// When non-nil, performs an exact-full-name match (case-insensitive,
    /// NFC-normalized, trimmed). Other filters are ignored.
    public var exactFullName: String?
    public var region: String
    public var limit: Int

    public init(
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        organization: String? = nil,
        exactFullName: String? = nil,
        region: String = "US",
        limit: Int = 25
    ) {
        self.name = name
        self.email = email
        self.phone = phone
        self.organization = organization
        self.exactFullName = exactFullName
        self.region = region
        self.limit = limit
    }
}

public protocol ContactsStore: Sendable {
    func authorizationStatus() -> ContactsAuthorizationStatus
    func requestAccess() throws
    var totalContacts: Int { get throws }
    func get(byID id: String) throws -> Contact?
    func find(query: ContactsQuery) throws -> [Contact]
    func listGroups() throws -> [ContactGroup]
    func members(ofGroupID id: String, limit: Int) throws -> [Contact]
    func groups(named name: String) throws -> [ContactGroup]
}

// MARK: - CNContactStore-backed implementation

public final class CNBackedContactsStore: ContactsStore, @unchecked Sendable {
    public let normalizer: PhoneNumberNormalizing
    private let store: CNContactStore

    public init(normalizer: PhoneNumberNormalizing) {
        self.normalizer = normalizer
        self.store = CNContactStore()
    }

    public func authorizationStatus() -> ContactsAuthorizationStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        @unknown default: return .denied
        }
    }

    public func requestAccess() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let thrownBox = ErrorBox()
        store.requestAccess(for: .contacts) { _, error in
            thrownBox.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let err = thrownBox.error { throw err }
    }

    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    static var keysToFetch: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
        ]
    }

    public var totalContacts: Int {
        get throws {
            var count = 0
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            do {
                try store.enumerateContacts(with: request) { _, _ in count += 1 }
            } catch {
                throw mapError(error)
            }
            return count
        }
    }

    public func get(byID id: String) throws -> Contact? {
        do {
            let cn = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keysToFetch)
            return makeContact(from: cn, region: "US")
        } catch CNError.recordDoesNotExist {
            return nil
        } catch let err as CNError where err.code == .recordDoesNotExist {
            return nil
        } catch {
            throw mapError(error)
        }
    }

    public func find(query: ContactsQuery) throws -> [Contact] {
        let region = query.region
        // Pre-normalize phone query if possible so we can do exact comparison.
        let normalizedPhone = query.phone.map { normalizer.normalize($0, region: region) }
        let phoneRawDigits = query.phone.map { $0.filter { $0.isNumber } }

        let nameNeedle = query.name?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let emailNeedle = query.email?.lowercased()
        let orgNeedle = query.organization?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let exactFull = query.exactFullName.map { normalizeFullName($0) }

        var results: [Contact] = []
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.sortOrder = .userDefault
        do {
            try store.enumerateContacts(with: request) { cn, stop in
                guard results.count < query.limit else {
                    stop.pointee = true
                    return
                }
                if let exactFull {
                    let candidate = self.normalizeFullName(self.fullNameRaw(from: cn))
                    guard candidate == exactFull else { return }
                    if let contact = self.makeContact(from: cn, region: region) {
                        results.append(contact)
                    }
                    return
                }
                // Standard query: each filter is AND-ed; absent filters always match.
                if let nameNeedle {
                    let combined = ([cn.givenName, cn.familyName, cn.nickname].joined(separator: " "))
                        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    guard combined.contains(nameNeedle) else { return }
                }
                if let emailNeedle {
                    let any = cn.emailAddresses.contains { ($0.value as String).lowercased().contains(emailNeedle) }
                    guard any else { return }
                }
                if let normalizedPhone, let phoneRawDigits, !phoneRawDigits.isEmpty {
                    let any = cn.phoneNumbers.contains { entry in
                        let raw = entry.value.stringValue
                        let cnNormalized = self.normalizer.normalize(raw, region: region)
                        if cnNormalized == normalizedPhone { return true }
                        // Fallback: substring match against raw digits.
                        let rawDigits = raw.filter { $0.isNumber }
                        return rawDigits.contains(phoneRawDigits)
                    }
                    guard any else { return }
                }
                if let orgNeedle {
                    let org = cn.organizationName
                        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    guard org.contains(orgNeedle) else { return }
                }
                if let contact = self.makeContact(from: cn, region: region) {
                    results.append(contact)
                }
            }
        } catch {
            throw mapError(error)
        }
        return results
    }

    public func listGroups() throws -> [ContactGroup] {
        do {
            let groups = try store.groups(matching: nil)
            // Single enumeration pass for membership counts: build identifier
            // → count by enumerating all contacts once, recording the groups
            // each contact belongs to via CNContactStore.containers/groups
            // membership predicate. Cheaper version: use unifiedContacts +
            // predicate per-group, which is one fetch per group.
            var out: [ContactGroup] = []
            for g in groups {
                let predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
                let members = try store.unifiedContacts(
                    matching: predicate,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
                out.append(ContactGroup(id: g.identifier, name: g.name, memberCount: members.count))
            }
            return out
        } catch {
            throw mapError(error)
        }
    }

    public func members(ofGroupID id: String, limit: Int) throws -> [Contact] {
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: id)
        do {
            let cnContacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keysToFetch)
            return Array(cnContacts.prefix(limit)).compactMap { makeContact(from: $0, region: "US") }
        } catch {
            throw mapError(error)
        }
    }

    public func groups(named name: String) throws -> [ContactGroup] {
        do {
            let groups = try store.groups(matching: nil)
            let needle = name.lowercased()
            return groups
                .filter { $0.name.lowercased() == needle }
                .map { g in
                    let predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
                    let members = (try? store.unifiedContacts(
                        matching: predicate,
                        keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                    )) ?? []
                    return ContactGroup(id: g.identifier, name: g.name, memberCount: members.count)
                }
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Mapping

    private func fullNameRaw(from cn: CNContact) -> String {
        return CNContactFormatter.string(from: cn, style: .fullName)
            ?? [cn.givenName, cn.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func normalizeFullName(_ s: String) -> String {
        return s.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func makeContact(from cn: CNContact, region: String) -> Contact? {
        let emails: [LabeledEmail] = cn.emailAddresses.map { entry in
            LabeledEmail(
                label: LabelNormalizer.normalize(entry.label),
                value: entry.value as String
            )
        }
        let phones: [LabeledPhone] = cn.phoneNumbers.map { entry in
            let raw = entry.value.stringValue
            let normalized = normalizer.normalize(raw, region: region)
            return LabeledPhone(
                label: LabelNormalizer.normalize(entry.label),
                value: normalized.isEmpty ? raw : normalized,
                raw: raw
            )
        }
        let addresses: [LabeledAddress] = cn.postalAddresses.map { entry in
            let v = entry.value
            return LabeledAddress(
                label: LabelNormalizer.normalize(entry.label),
                street: v.street.isEmpty ? nil : v.street,
                city: v.city.isEmpty ? nil : v.city,
                state: v.state.isEmpty ? nil : v.state,
                postalCode: v.postalCode.isEmpty ? nil : v.postalCode,
                country: v.country.isEmpty ? nil : v.country,
                isoCountryCode: v.isoCountryCode.isEmpty ? nil : v.isoCountryCode
            )
        }
        let birthday: PartialDate? = {
            guard let comps = cn.birthday else { return nil }
            guard let month = comps.month, let day = comps.day else { return nil }
            return PartialDate(year: comps.year, month: month, day: day)
        }()
        let fullName = fullNameRaw(from: cn)
        return Contact(
            id: cn.identifier,
            givenName: cn.givenName.isEmpty ? nil : cn.givenName,
            familyName: cn.familyName.isEmpty ? nil : cn.familyName,
            fullName: fullName,
            nickname: cn.nickname.isEmpty ? nil : cn.nickname,
            emails: emails,
            phones: phones,
            organization: cn.organizationName.isEmpty ? nil : cn.organizationName,
            jobTitle: cn.jobTitle.isEmpty ? nil : cn.jobTitle,
            birthday: birthday,
            addresses: addresses
        )
    }

    private func mapError(_ error: Error) -> Error {
        let nsError = error as NSError
        // CNError domain & permission-related code map to ContactsError.permissionDenied
        if nsError.domain == CNErrorDomain {
            if let code = CNError.Code(rawValue: nsError.code), code == .authorizationDenied {
                return ContactsError.permissionDenied
            }
        }
        return error
    }
}

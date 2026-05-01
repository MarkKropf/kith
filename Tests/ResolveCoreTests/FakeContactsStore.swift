import ContactsCore
import Foundation

/// In-memory ContactsStore for resolver tests. Searches are case-insensitive
/// substring across the same fields the CN-backed impl considers.
final class FakeContactsStore: ContactsStore, @unchecked Sendable {
    var contacts: [Contact] = []
    var groups: [ContactGroup] = []
    var groupMembers: [String: [Contact]] = [:]
    var permission: ContactsAuthorizationStatus = .granted

    func authorizationStatus() -> ContactsAuthorizationStatus { permission }
    func requestAccess() throws {}
    var totalContacts: Int { get throws { contacts.count } }

    func get(byID id: String) throws -> Contact? {
        return contacts.first { $0.id == id }
    }

    func find(query: ContactsQuery) throws -> [Contact] {
        if let exact = query.exactFullName {
            let needle = exact.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return contacts.filter {
                $0.fullName.precomposedStringWithCanonicalMapping
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
        }
        var out: [Contact] = []
        for c in contacts {
            if let n = query.name, !c.fullName.lowercased().contains(n.lowercased()) { continue }
            if let e = query.email, !c.emails.contains(where: { $0.value.lowercased().contains(e.lowercased()) }) { continue }
            if let p = query.phone {
                let want = p.filter { $0.isNumber }
                let any = c.phones.contains { $0.value.contains(p) || $0.raw.filter({ $0.isNumber }).contains(want) }
                if !any { continue }
            }
            out.append(c)
            if out.count >= query.limit { break }
        }
        return out
    }

    func listGroups() throws -> [ContactGroup] { groups }
    func members(ofGroupID id: String, limit: Int) throws -> [Contact] {
        let m = groupMembers[id] ?? []
        return Array(m.prefix(limit))
    }
    func groups(named name: String) throws -> [ContactGroup] {
        return groups.filter { $0.name.lowercased() == name.lowercased() }
    }
}

import ContactsCore
import Foundation
import MessagesCore

public struct ResolvedContact: Sendable, Equatable {
    public let id: String
    public let fullName: String
    public let phones: [String]   // E.164
    public let emails: [String]   // lowercased

    public init(id: String, fullName: String, phones: [String], emails: [String]) {
        self.id = id
        self.fullName = fullName
        self.phones = phones
        self.emails = emails
    }
}

public struct ResolvedTarget: Sendable, Equatable {
    public let chatIDs: [Int64]
    public let resolvedFromContact: ResolvedContact?
    public let candidates: [ChatCandidate]

    public init(chatIDs: [Int64], resolvedFromContact: ResolvedContact?, candidates: [ChatCandidate]) {
        self.chatIDs = chatIDs
        self.resolvedFromContact = resolvedFromContact
        self.candidates = candidates
    }
}

public enum ResolverError: Error, Sendable, Equatable {
    case invalidWithArg(String)
    case contactNotFound(String)
    case contactAmbiguous(String, candidateIDs: [String], candidateFullNames: [String])
}

/// Cross-domain `--with` resolver. See §4 of docs/PLAN.md.
public final class Resolver: @unchecked Sendable {
    public let region: String
    public let normalizer: PhoneNumberNormalizing
    public let contacts: ContactsStore
    public let messages: MessageStore

    public init(
        contacts: ContactsStore,
        messages: MessageStore,
        normalizer: PhoneNumberNormalizing,
        region: String = "US"
    ) {
        self.contacts = contacts
        self.messages = messages
        self.normalizer = normalizer
        self.region = region
    }

    /// Resolve a `--with` value to one or more chat IDs (with candidates for
    /// disambiguation).
    public func resolve(_ raw: String) throws -> ResolvedTarget {
        let parsed = WithArgParser.parse(raw)
        switch parsed {
        case .invalid(let s):
            throw ResolverError.invalidWithArg(s)

        case .chatID(let ns):
            // Verify each chat-id exists; drop unknown ones.
            var valid: [Int64] = []
            for n in ns {
                if let info = try messages.chatInfo(chatID: n), info.id == n {
                    valid.append(n)
                }
            }
            let candidates = try messages.chatCandidates(chatIDs: valid).map(toCandidate)
            return ResolvedTarget(chatIDs: valid, resolvedFromContact: nil, candidates: candidates)

        case .chatGUID(let g):
            if let id = try messages.chatID(forGUID: g) {
                let candidates = try messages.chatCandidates(chatIDs: [id]).map(toCandidate)
                return ResolvedTarget(chatIDs: [id], resolvedFromContact: nil, candidates: candidates)
            }
            return ResolvedTarget(chatIDs: [], resolvedFromContact: nil, candidates: [])

        case .cnContactID(let id):
            guard let contact = try contacts.get(byID: id) else {
                throw ResolverError.contactNotFound(raw)
            }
            return try resolveFromContact(contact)

        case .phone(let p):
            let identities = phoneIdentities(p)
            return try buildTarget(identities: identities, fromContact: nil)

        case .email(let e):
            return try buildTarget(identities: [e.lowercased()], fromContact: nil)

        case .name(let n):
            let matches = try contacts.find(query: ContactsQuery(exactFullName: n, region: region, limit: 50))
            if matches.isEmpty {
                throw ResolverError.contactNotFound(raw)
            }
            if matches.count > 1 {
                throw ResolverError.contactAmbiguous(
                    raw,
                    candidateIDs: matches.map { $0.id },
                    candidateFullNames: matches.map { $0.fullName }
                )
            }
            return try resolveFromContact(matches[0])
        }
    }

    // MARK: - Helpers

    private func resolveFromContact(_ contact: Contact) throws -> ResolvedTarget {
        var identities = Set<String>()
        var phones: [String] = []
        var emails: [String] = []
        for p in contact.phones {
            phones.append(p.value)
            for id in phoneIdentities(p.value) {
                identities.insert(id)
            }
        }
        for e in contact.emails {
            let lower = e.value.lowercased()
            emails.append(lower)
            identities.insert(lower)
        }
        let resolved = ResolvedContact(
            id: contact.id,
            fullName: contact.fullName,
            phones: phones,
            emails: emails
        )
        return try buildTarget(identities: identities, fromContact: resolved)
    }

    private func buildTarget(identities: Set<String>, fromContact: ResolvedContact?) throws -> ResolvedTarget {
        let chatIDs = try messages.chatsForIdentities(identities)
        let candidates = try messages.chatCandidates(chatIDs: chatIDs).map(toCandidate)
        return ResolvedTarget(
            chatIDs: chatIDs,
            resolvedFromContact: fromContact,
            candidates: candidates
        )
    }

    private func toCandidate(_ row: MessageStore.ChatCandidateRow) -> ChatCandidate {
        return ChatCandidate(
            chatId: row.chatID,
            chatIdentifier: row.chatIdentifier,
            displayName: row.displayName.isEmpty ? nil : row.displayName,
            service: row.service,
            participants: row.participants,
            handleCount: row.handleCount,
            lastMessageAt: row.lastMessageAt
        )
    }

    /// Identity set for a phone input: the E.164 normalized form, the form
    /// without the leading `+`, the raw input, and `tel:` + E.164.
    func phoneIdentities(_ raw: String) -> Set<String> {
        let normalized = normalizer.normalize(raw, region: region)
        var set: Set<String> = [raw]
        if !normalized.isEmpty {
            set.insert(normalized)
            if normalized.hasPrefix("+") {
                set.insert(String(normalized.dropFirst()))
            }
            set.insert("tel:\(normalized)")
        }
        return set
    }
}

// Conform the public MessagesCore wrapper to the ContactsCore protocol so a
// single instance can be shared by ContactsStore and Resolver.
extension KithPhoneNumberNormalizer: PhoneNumberNormalizing {}

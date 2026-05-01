import ContactsCore
import Foundation
import KithAgentProtocol
import MessagesCore
import ResolveCore

/// Pure in-process implementation of the messages.* + contacts.* pipelines.
///
/// The agent registers thin XPC handlers that call straight into these
/// functions; the CLI's `KITH_DB_PATH` test/dev path also calls them
/// directly, bypassing XPC. Keeping the logic here means the resolver +
/// canonical-1:1 filter + cleanup logic stays in exactly one place.
///
/// All functions throw `KithWireError` so the agent's XPC layer can
/// re-emit them verbatim and the CLI's local-mode error mapping reuses the
/// same envelope formatter as the XPC path.
public enum KithMessagesService {

    // MARK: - contacts.*

    public static func contactsFind(
        contacts: ContactsStore,
        query: ContactsQuery
    ) throws -> [Contact] {
        do {
            return try contacts.find(query: query)
        } catch {
            throw mapContactsError(error)
        }
    }

    public static func contactsGet(
        contacts: ContactsStore,
        id: String
    ) throws -> Contact? {
        do {
            return try contacts.get(byID: id)
        } catch {
            throw mapContactsError(error)
        }
    }

    public static func contactsListGroups(
        contacts: ContactsStore
    ) throws -> [ContactGroup] {
        do {
            return try contacts.listGroups()
        } catch {
            throw mapContactsError(error)
        }
    }

    public static func contactsGroupMembers(
        contacts: ContactsStore,
        groupID: String,
        limit: Int
    ) throws -> [Contact] {
        do {
            return try contacts.members(ofGroupID: groupID, limit: limit)
        } catch {
            throw mapContactsError(error)
        }
    }

    public static func contactsGroupsByName(
        contacts: ContactsStore,
        name: String
    ) throws -> [ContactGroup] {
        do {
            return try contacts.groups(named: name)
        } catch {
            throw mapContactsError(error)
        }
    }

    // MARK: - messages.*

    public static func messagesChats(
        contacts: ContactsStore,
        messages: MessageStore,
        normalizer: KithPhoneNumberNormalizer,
        query q: MessagesChatsQuery
    ) throws -> [KithChat] {
        var identities: Set<String> = []
        if let participant = q.participant {
            identities.formUnion(phoneOrEmailIdentities(participant, region: q.region, normalizer: normalizer))
        }

        if let with = q.with {
            let resolver = Resolver(contacts: contacts, messages: messages, normalizer: normalizer, region: q.region)
            let target: ResolvedTarget
            do { target = try resolver.resolve(with) }
            catch let err as ResolverError { throw mapResolverError(err) }
            catch { throw KithWireError.internal(String(describing: error)) }
            if target.chatIDs.isEmpty {
                throw KithWireError.notFound("no chats matched --with \"\(with)\"")
            }
            do {
                let rows = try messages.chatCandidates(chatIDs: target.chatIDs)
                return try rows.compactMap { row -> KithChat? in
                    guard let info = try messages.chatInfo(chatID: row.chatID) else { return nil }
                    return KithChat(
                        id: info.id,
                        guid: info.guid,
                        identifier: info.identifier,
                        name: info.name,
                        service: info.service,
                        participants: row.participants,
                        lastMessageAt: row.lastMessageAt
                    )
                }
            } catch {
                throw KithWireError.dbUnavailable(String(describing: error))
            }
        }

        do {
            let chats = try messages.listChatsForIdentities(identities, limit: q.limit)
            var out: [KithChat] = []
            for c in chats {
                let participants = (try? messages.participants(chatID: c.id)) ?? []
                let info = try messages.chatInfo(chatID: c.id)
                out.append(KithChat(
                    id: c.id,
                    guid: info?.guid ?? "",
                    identifier: c.identifier,
                    name: c.name,
                    service: c.service,
                    participants: participants,
                    lastMessageAt: c.lastMessageAt
                ))
            }
            return out
        } catch {
            throw KithWireError.dbUnavailable(String(describing: error))
        }
    }

    public static func messagesHistory(
        contacts: ContactsStore,
        messages: MessageStore,
        normalizer: KithPhoneNumberNormalizer,
        query q: MessagesHistoryQuery
    ) throws -> MessagesHistoryResult {
        if q.limit < 1 || q.limit > 5000 {
            throw KithWireError.invalidInput("--limit must be in 1..5000")
        }

        let resolver = Resolver(contacts: contacts, messages: messages, normalizer: normalizer, region: q.region)
        let target: ResolvedTarget
        do { target = try resolver.resolve(q.with) }
        catch let err as ResolverError { throw mapResolverError(err) }
        catch let err as ContactsError { throw mapContactsError(err) }
        catch { throw KithWireError.internal(String(describing: error)) }

        if target.chatIDs.isEmpty {
            throw KithWireError.noChatFound(q.with)
        }

        let parsed = WithArgParser.parse(q.with)
        let enforceCanonical1to1: Bool
        switch parsed {
        case .chatID, .chatGUID: enforceCanonical1to1 = false
        default: enforceCanonical1to1 = true
        }

        var streamChatIDs: [Int64] = target.chatIDs
        var autoSelect: AutoSelectNote? = nil

        if enforceCanonical1to1 {
            let identities = mergeIdentities(target: target)
            let result: MessageStore.MergeableResult
            do { result = try messages.kithMergeable(chatIDs: target.chatIDs, identities: identities) }
            catch { throw KithWireError.dbUnavailable(String(describing: error)) }
            if result.merged.isEmpty {
                let candidates = target.candidates.map { c -> KithChatCandidate in
                    let reason = result.reasons[c.chatId]
                    return KithChatCandidate(
                        chatId: c.chatId,
                        chatIdentifier: c.chatIdentifier.isEmpty ? nil : c.chatIdentifier,
                        displayName: c.displayName,
                        service: c.service.isEmpty ? nil : c.service,
                        participants: c.participants,
                        handleCount: c.handleCount,
                        lastMessageAt: c.lastMessageAt,
                        mergeRejectionReason: reason?.rawValue
                    )
                }
                throw KithWireError.noCanonical1to1("no canonical 1:1 chat with \(q.with); only group/named chats matched.", candidates: candidates)
            }
            streamChatIDs = result.merged
            if result.merged.count > 1 || !result.leftover.isEmpty {
                autoSelect = AutoSelectNote(merged: result.merged, leftover: result.leftover)
            }
        }

        let chatID = streamChatIDs[0]
        let filter = MessageFilter(participants: [], startDate: q.start, endDate: q.end)
        let chatService = (try? messages.chatInfo(chatID: chatID)?.service) ?? ""

        let raw: [Message]
        do {
            if streamChatIDs.count > 1 {
                raw = try messages.messagesAcrossChats(streamChatIDs, limit: q.limit, filter: filter, includeReactions: q.includeReactions)
            } else {
                raw = try messages.messagesIncludingReactions(chatID: chatID, limit: q.limit, filter: filter, includeReactions: q.includeReactions)
            }
        } catch {
            throw KithWireError.dbUnavailable(String(describing: error))
        }

        var out: [KithMessage] = []
        out.reserveCapacity(raw.count)
        for m in raw {
            let metas: [AttachmentMeta]?
            if q.attachments {
                metas = (try? messages.attachments(for: m.rowID)) ?? []
            } else {
                metas = nil
            }
            out.append(makeKithMessage(
                m,
                chatService: chatService,
                attachments: q.attachments ? metas : nil,
                cleanText: q.cleanText,
                cleanupAttachments: metas
            ))
        }

        return MessagesHistoryResult(messages: out, autoSelect: autoSelect)
    }

    // MARK: - Helpers (also used by the agent's main.swift)

    public static func mapContactsError(_ error: Error) -> KithWireError {
        if let cerr = error as? ContactsError {
            switch cerr {
            case .permissionDenied:
                return .permissionDenied("Contacts access denied. Grant Kith permission in System Settings → Privacy & Security → Contacts.")
            case .notFound(let m):
                return .notFound(m)
            case .ambiguous(let m, let candidates):
                return .ambiguous(m, candidates: candidates)
            }
        }
        return .internal(String(describing: error))
    }

    public static func mapResolverError(_ error: ResolverError) -> KithWireError {
        switch error {
        case .invalidWithArg(let s):
            return .resolverInvalidWith(s)
        case .contactNotFound(let s):
            return .resolverContactNotFound(s)
        case .contactAmbiguous(let s, let ids, let names):
            return .resolverContactAmbiguous(s, candidateIDs: ids, candidateFullNames: names)
        }
    }

    public static func phoneOrEmailIdentities(_ raw: String, region: String, normalizer: KithPhoneNumberNormalizer) -> Set<String> {
        if raw.contains("@") { return [raw.lowercased()] }
        let normalized = normalizer.normalize(raw, region: region)
        var set: Set<String> = [raw]
        if !normalized.isEmpty {
            set.insert(normalized)
            if normalized.hasPrefix("+") { set.insert(String(normalized.dropFirst())) }
            set.insert("tel:\(normalized)")
        }
        return set
    }

    public static func mergeIdentities(target: ResolvedTarget) -> Set<String> {
        if let c = target.resolvedFromContact {
            var ids: Set<String> = []
            for p in c.phones { ids.insert(p) }
            for e in c.emails { ids.insert(e) }
            return ids
        }
        return Set(target.candidates.flatMap { $0.participants.map { $0.lowercased() } })
    }
}

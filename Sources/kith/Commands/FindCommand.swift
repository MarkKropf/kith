import ArgumentParser
import ContactsCore
import Foundation
import KithAgentClient

struct FindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Search local Apple Contacts."
    )

    @Option(name: .long, help: "Substring on givenName + familyName + nickname (case- and diacritic-insensitive).")
    var name: String?

    @Option(name: .long, help: "Substring against any email value (case-insensitive).")
    var email: String?

    @Option(name: .long, help: "Phone (normalized to E.164 via --region; falls back to raw-digit substring).")
    var phone: String?

    @Option(name: .long, help: "Substring on organizationName.")
    var org: String?

    @Option(name: .long, help: "ISO-2 region for phone normalization.")
    var region: String = "US"

    @Option(name: .long, help: "Maximum results (max 500).")
    var limit: Int = 25

    @Option(name: .long, help: "Comma-separated field projection.")
    var fields: String?

    @Flag(name: .long, help: "Emit JSONL.")
    var jsonl: Bool = false

    @OptionGroup var common: CommonOutputOptions

    func run() async throws {
        common.applyStyle()
        if name == nil, email == nil, phone == nil, org == nil {
            _ = ErrorReporter.emit(.usage, message: "at least one of --name, --email, --phone, --org is required", machine: jsonl)
            throw ExitCode(KithExitCode.usage.rawValue)
        }
        if limit < 1 || limit > 500 {
            _ = ErrorReporter.emit(.invalidInput, message: "--limit must be in 1..500", machine: jsonl)
            throw ExitCode(KithExitCode.invalidInput.rawValue)
        }
        // v0.2.0: route Contacts access through the agent. The CLI itself
        // never asks TCC for anything — Kith.app holds the grant and the
        // agent is the responsible process.
        let client: KithAgentClient
        do {
            client = try KithAgentClient()
        } catch {
            _ = ErrorReporter.emit(
                .generic,
                message: "could not construct kith-agent client: \(error)",
                hint: "Bug: file an issue with the full error.",
                machine: jsonl
            )
            throw ExitCode(KithExitCode.generic.rawValue)
        }
        let query = ContactsQuery(
            name: name,
            email: email,
            phone: phone,
            organization: org,
            region: region,
            limit: limit
        )
        let results: [Contact]
        do {
            results = try await client.find(query: query)
        } catch let err as KithAgentClientError {
            switch err {
            case .agentUnreachable:
                _ = ErrorReporter.emit(
                    .generic,
                    message: "kith-agent isn't running.",
                    hint: "In v0.2.0 dev: `bash scripts/dev-agent.sh load && bash scripts/dev-agent.sh kickstart`. In v0.2.0 production: launch /Applications/Kith.app once to register the agent.",
                    machine: jsonl
                )
                throw ExitCode(KithExitCode.generic.rawValue)
            case .clientNotAccepted:
                _ = ErrorReporter.emit(
                    .generic,
                    message: "kith-agent rejected this client (code-signature mismatch).",
                    hint: "Make sure the kith CLI and kith-agent are signed with the same Apple Team ID.",
                    machine: jsonl
                )
                throw ExitCode(KithExitCode.generic.rawValue)
            case .agentReturnedError(let underlying):
                if String(describing: underlying).contains("permissionDenied") {
                    throw ExitCode(KithCommandError.permissionDenied("Contacts access denied. The Kith app needs Contacts permission — see `kith doctor`.").emit(machine: jsonl))
                }
                _ = ErrorReporter.emit(.generic, message: String(describing: underlying), machine: jsonl)
                throw ExitCode(KithExitCode.generic.rawValue)
            }
        } catch {
            _ = ErrorReporter.emit(.generic, message: String(describing: error), machine: jsonl)
            throw ExitCode(KithExitCode.generic.rawValue)
        }
        let projected = projectFields(results)
        if jsonl {
            try JSONLEmitter.emit(projected)
        } else {
            for c in projected {
                print(HumanRenderer.render(contact: c))
                print("")
            }
        }
    }

    private func projectFields(_ contacts: [Contact]) -> [Contact] {
        guard let fields = fields else { return contacts }
        let want = Set(fields.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        // For v1 simplicity: return same Contact but blank out unselected
        // multi-value arrays. Required core fields (id, fullName) always
        // present.
        return contacts.map { c in
            Contact(
                id: c.id,
                givenName: want.contains("givenName") ? c.givenName : nil,
                familyName: want.contains("familyName") ? c.familyName : nil,
                fullName: c.fullName,
                nickname: want.contains("nickname") ? c.nickname : nil,
                emails: want.contains("emails") ? c.emails : [],
                phones: want.contains("phones") ? c.phones : [],
                organization: want.contains("organization") ? c.organization : nil,
                jobTitle: want.contains("jobTitle") ? c.jobTitle : nil,
                birthday: want.contains("birthday") ? c.birthday : nil,
                addresses: want.contains("addresses") ? c.addresses : []
            )
        }
    }
}

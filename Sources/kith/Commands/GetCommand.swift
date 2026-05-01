import ArgumentParser
import ContactsCore
import Foundation
import KithAgentClient

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Resolve one canonical contact by id or exact full name.",
        discussion: "The id is the local CN-record UUID and is not portable across Apple accounts or devices."
    )

    @Argument(help: "CNContact UUID or exact full name.")
    var target: String

    @Flag(name: .long, help: "Emit only {id, fullName}.")
    var resolveOnly: Bool = false

    @Option(name: .long, help: "Comma-separated field projection.")
    var fields: String?

    @Flag(name: .long, help: "Emit JSON (default human).")
    var json: Bool = false

    @OptionGroup var common: CommonOutputOptions

    private static let uuidRegex = try! NSRegularExpression(pattern: "^[0-9A-F-]{36}$")

    func run() async throws {
        common.applyStyle()
        let client = RunHelpers.makeClient(machine: json)

        let isUUID = Self.uuidRegex.firstMatch(
            in: target, options: [], range: NSRange(location: 0, length: target.utf16.count)
        ) != nil

        let resolved: Contact?
        if isUUID {
            do {
                resolved = try await client.get(id: target)
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: json))
            }
        } else {
            let matches: [Contact]
            do {
                matches = try await client.find(query: ContactsQuery(exactFullName: target, limit: 50))
            } catch {
                throw ExitCode(RunHelpers.emitClientError(error, machine: json))
            }
            if matches.isEmpty {
                _ = ErrorReporter.emit(.notFound, message: "no contact matches \"\(target)\"", machine: json)
                throw ExitCode(KithExitCode.notFound.rawValue)
            }
            if matches.count > 1 {
                var stderr = StderrStream()
                for m in matches {
                    print("\(m.fullName)\t\(m.id)", to: &stderr)
                }
                _ = ErrorReporter.emit(.ambiguous, message: "\(matches.count) contacts match \"\(target)\"", hint: "Re-run with the contact id (printed on stderr above).", machine: json)
                throw ExitCode(KithExitCode.ambiguous.rawValue)
            }
            resolved = matches[0]
        }

        guard let c = resolved else {
            _ = ErrorReporter.emit(.notFound, message: "no contact matches \"\(target)\"", machine: json)
            throw ExitCode(KithExitCode.notFound.rawValue)
        }

        if resolveOnly {
            struct Slim: Encodable { let id: String; let fullName: String }
            let slim = Slim(id: c.id, fullName: c.fullName)
            if json {
                let data = try KithJSON.encoder().encode(slim)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("\(c.fullName)\t\(c.id)")
            }
            return
        }

        let projected = projectFields(c)
        if json {
            let data = try KithJSON.encoder().encode(projected)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(HumanRenderer.render(contact: projected))
        }
    }

    private func projectFields(_ c: Contact) -> Contact {
        guard let fields = fields else { return c }
        let want = Set(fields.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        return Contact(
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

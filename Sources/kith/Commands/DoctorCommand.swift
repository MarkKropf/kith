import ArgumentParser
import Foundation
import KithAgentClient
import KithAgentProtocol

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that kith can read Contacts and the Messages database."
    )

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    @OptionGroup var common: CommonOutputOptions

    struct PermissionState: Encodable {
        let status: String
        let hint: String?
    }

    struct DoctorReport: Encodable {
        struct KithMeta: Encodable {
            let version: String
            let commit: String
        }
        struct PlatformMeta: Encodable {
            let macOS: String
            let binaryArch: String
        }
        struct Permissions: Encodable {
            let contacts: PermissionState
            let fullDiskAccess: PermissionState
            let automationMessages: PermissionState
        }
        struct AgentMeta: Encodable {
            let reachable: Bool
            let version: String?
            let bootstrapAppPath: String
        }
        struct MessagesDb: Encodable {
            let path: String
            let openable: Bool
            let schemaFlags: [String: Bool]
        }
        struct ContactsStoreMeta: Encodable {
            let openable: Bool
            let totalContacts: Int
        }
        struct ColorMeta: Encodable {
            let useColor: Bool
            /// One of: `flag` | `kith-color` | `no-color` | `clicolor-force`
            /// | `isatty` | `piped`. Tells an agent which signal won.
            let source: String
        }

        let kith: KithMeta
        let platform: PlatformMeta
        let agent: AgentMeta
        let permissions: Permissions
        let messagesDb: MessagesDb
        let contactsStore: ContactsStoreMeta
        let color: ColorMeta
        let ok: Bool
    }

    func run() async throws {
        common.applyStyle()

        // The agent owns the Contacts grant + the FDA grant for chat.db, so
        // we ask it for its own perspective on permissions/openability and
        // augment with CLI-side metadata.
        let client = KithAgentClient()
        let health: AgentHealthReport
        do {
            health = try await client.health()
        } catch {
            // Either the agent isn't running and bootstrap failed, or the
            // agent threw. Print a degraded report and exit with the same
            // code paths as before.
            renderUnreachable(reason: String(describing: error))
            throw ExitCode(KithExitCode.generic.rawValue)
        }

        let contactsPerm: PermissionState
        switch health.contactsAuthStatus {
        case "granted":
            contactsPerm = PermissionState(status: "granted", hint: nil)
        case "denied":
            contactsPerm = PermissionState(
                status: "denied",
                hint: "Grant Contacts access to Kith.app in System Settings → Privacy & Security → Contacts."
            )
        case "restricted":
            contactsPerm = PermissionState(status: "restricted", hint: "Contacts access is restricted by policy on this device.")
        case "not-determined":
            contactsPerm = PermissionState(status: "not-determined", hint: "Run `kith find` once to trigger the macOS permission prompt for Kith.app.")
        default:
            contactsPerm = PermissionState(status: health.contactsAuthStatus, hint: nil)
        }

        let fdaPerm: PermissionState
        if !FileManager.default.fileExists(atPath: health.messagesDbPath) {
            fdaPerm = PermissionState(
                status: "restricted",
                hint: "chat.db not found at \(health.messagesDbPath). Open Messages.app and sign in once to create it."
            )
        } else if health.messagesDbOpenable {
            fdaPerm = PermissionState(status: "granted", hint: nil)
        } else {
            fdaPerm = PermissionState(
                status: "denied",
                hint: "Add Kith.app to System Settings → Privacy & Security → Full Disk Access. The agent inside Kith.app reads ~/Library/Messages/chat.db on your behalf; the kith CLI itself never opens chat.db."
            )
        }

        let automationPerm = PermissionState(status: "n/a-in-v1", hint: nil)

        let report = DoctorReport(
            kith: .init(version: BuildInfo.version, commit: BuildInfo.commit),
            platform: .init(macOS: ProcessInfo.processInfo.operatingSystemVersionString, binaryArch: currentArch()),
            agent: .init(reachable: true, version: health.agentVersion, bootstrapAppPath: KithAgentClient.bootstrapAppPath),
            permissions: .init(contacts: contactsPerm, fullDiskAccess: fdaPerm, automationMessages: automationPerm),
            messagesDb: .init(path: health.messagesDbPath, openable: health.messagesDbOpenable, schemaFlags: health.schemaFlags),
            contactsStore: .init(openable: contactsPerm.status == "granted", totalContacts: health.totalContacts),
            color: .init(useColor: AnsiStyle.auto.useColor, source: AnsiStyle.auto.source.rawValue),
            ok: contactsPerm.status == "granted" && fdaPerm.status == "granted"
        )

        if json {
            let data = try KithJSON.encoder(pretty: true).encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            renderHuman(report)
        }
        if !report.ok {
            throw ExitCode(KithExitCode.permissionDenied.rawValue)
        }
    }

    private func renderUnreachable(reason: String) {
        if json {
            struct Degraded: Encodable {
                let kith: DoctorReport.KithMeta
                let agent: DoctorReport.AgentMeta
                let error: String
                let ok: Bool
            }
            let payload = Degraded(
                kith: .init(version: BuildInfo.version, commit: BuildInfo.commit),
                agent: .init(reachable: false, version: nil, bootstrapAppPath: KithAgentClient.bootstrapAppPath),
                error: reason,
                ok: false
            )
            if let data = try? KithJSON.encoder(pretty: true).encode(payload) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            let style = AnsiStyle.auto
            print("\(style.bold("kith")) \(BuildInfo.version) \(style.dim("(commit \(BuildInfo.commit))"))")
            print("\(style.boldRed("[!!]")) kith-agent unreachable: \(reason)")
            print("  \(style.yellow("hint:")) Install Kith.app via `brew install --cask kith`, then launch it once. Bootstrap path: \(KithAgentClient.bootstrapAppPath)")
            print(style.boldRed("FAIL"))
        }
    }

    private func renderHuman(_ r: DoctorReport) {
        let style = AnsiStyle.auto
        func bullet(_ ok: Bool) -> String {
            return ok ? style.boldGreen("[ok]") : style.boldRed("[!!]")
        }
        print("\(style.bold("kith")) \(r.kith.version) \(style.dim("(commit \(r.kith.commit))"))")
        print("\(style.dim("platform:")) \(r.platform.macOS) \(style.dim("(\(r.platform.binaryArch))"))")
        if let v = r.agent.version {
            print("\(bullet(r.agent.reachable)) \(style.bold("kith-agent:")) reachable (\(v))")
        }
        print("\(bullet(r.permissions.contacts.status == "granted")) \(style.bold("contacts:")) \(r.permissions.contacts.status)")
        if let hint = r.permissions.contacts.hint { print("  \(style.yellow("hint:")) \(hint)") }
        print("\(bullet(r.permissions.fullDiskAccess.status == "granted")) \(style.bold("full disk access:")) \(r.permissions.fullDiskAccess.status)")
        if let hint = r.permissions.fullDiskAccess.hint { print("  \(style.yellow("hint:")) \(hint)") }
        print("\(style.dim("[--]")) \(style.bold("automation (messages):")) \(r.permissions.automationMessages.status)")
        print("\(style.dim("messages db:")) \(r.messagesDb.path) \(style.dim("openable=\(r.messagesDb.openable)"))")
        print("\(style.dim("contacts store:")) \(style.dim("openable=\(r.contactsStore.openable) total=\(r.contactsStore.totalContacts)"))")
        print(r.ok ? style.boldGreen("OK") : style.boldRed("FAIL"))
    }

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

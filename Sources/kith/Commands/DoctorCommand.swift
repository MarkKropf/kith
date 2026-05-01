import ArgumentParser
import ContactsCore
import Foundation
import MessagesCore

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
        let permissions: Permissions
        let messagesDb: MessagesDb
        let contactsStore: ContactsStoreMeta
        let color: ColorMeta
        let ok: Bool
    }

    func run() async throws {
        common.applyStyle()
        let normalizer = KithPhoneNumberNormalizer()
        let store = CNBackedContactsStore(normalizer: normalizer)

        // Contacts permission
        let contactsPerm: PermissionState
        var contactsOpenable = false
        var totalContacts = 0
        switch store.authorizationStatus() {
        case .granted:
            contactsPerm = PermissionState(status: "granted", hint: nil)
            contactsOpenable = true
            totalContacts = (try? store.totalContacts) ?? 0
        case .denied:
            contactsPerm = PermissionState(
                status: "denied",
                hint: "Grant Contacts access to your terminal in System Settings → Privacy & Security → Contacts; the binary inherits its parent process's TCC grant."
            )
        case .restricted:
            contactsPerm = PermissionState(status: "restricted", hint: "Contacts access is restricted by policy on this device.")
        case .notDetermined:
            contactsPerm = PermissionState(status: "not-determined", hint: "Run `kith find` once to trigger the macOS permission prompt.")
        }

        // Full Disk Access — try to open chat.db read-only.
        let dbPath = MessageStore.kithDefaultPath
        var dbOpenable = false
        var schemaFlags: [String: Bool] = [:]
        var fdaPerm: PermissionState
        if !FileManager.default.fileExists(atPath: dbPath) {
            fdaPerm = PermissionState(
                status: "restricted",
                hint: "chat.db not found at \(dbPath). Open Messages.app and sign in once to create it."
            )
        } else {
            do {
                let mstore = try MessageStore(path: dbPath)
                dbOpenable = true
                let flags = mstore.kithSchemaFlags
                schemaFlags = [
                    "hasAttributedBody": flags.hasAttributedBody,
                    "hasReactionColumns": flags.hasReactionColumns,
                    "hasThreadOriginatorGUIDColumn": flags.hasThreadOriginatorGUIDColumn,
                    "hasDestinationCallerID": flags.hasDestinationCallerID,
                ]
                fdaPerm = PermissionState(status: "granted", hint: nil)
            } catch {
                let msg = String(describing: error).lowercased()
                let isAuth = msg.contains("authorization denied") || msg.contains("unable to open") || msg.contains("out of memory (14)")
                fdaPerm = PermissionState(
                    status: isAuth ? "denied" : "denied",
                    hint: "FDA grants are per-binary AND inherited by child processes. Add your TERMINAL (Terminal.app, iTerm, ghostty, etc.) — not the kith binary itself — to System Settings → Privacy & Security → Full Disk Access. Restart the terminal afterward. If kith is being launched by an agent harness, that harness's process is the one needing FDA."
                )
            }
        }

        let automationPerm = PermissionState(status: "n/a-in-v1", hint: nil)

        let report = DoctorReport(
            kith: .init(version: BuildInfo.version, commit: BuildInfo.commit),
            platform: .init(macOS: ProcessInfo.processInfo.operatingSystemVersionString, binaryArch: currentArch()),
            permissions: .init(contacts: contactsPerm, fullDiskAccess: fdaPerm, automationMessages: automationPerm),
            messagesDb: .init(path: dbPath, openable: dbOpenable, schemaFlags: schemaFlags),
            contactsStore: .init(openable: contactsOpenable, totalContacts: totalContacts),
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

    private func renderHuman(_ r: DoctorReport) {
        let style = AnsiStyle.auto
        func bullet(_ ok: Bool) -> String {
            return ok ? style.boldGreen("[ok]") : style.boldRed("[!!]")
        }
        print("\(style.bold("kith")) \(r.kith.version) \(style.dim("(commit \(r.kith.commit))"))")
        print("\(style.dim("platform:")) \(r.platform.macOS) \(style.dim("(\(r.platform.binaryArch))"))")
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

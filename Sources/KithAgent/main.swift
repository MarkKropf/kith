import ContactsCore
import Foundation
import KithAgentProtocol
import MessagesCore
import ResolveCore   // pulls in `KithPhoneNumberNormalizer: PhoneNumberNormalizing`
import SecureXPC

// kith-agent
//
// Long-lived process that holds the user-facing TCC grants (Contacts,
// eventually FDA via the Messages.app entitlement chain) and vends the
// underlying ContactsStore/MessageStore APIs to the CLI over XPC.
//
// Phase 1 (this file): listens on the Mach service `com.supaku.kith.agent`,
// registers the `contacts.find` route, blocks. The CLI (`kith find ...`)
// connects via `KithAgentClient`.
//
// Mach service binding requires the running process to be launchd-managed
// with this name in the plist's `MachServices` key. For development:
//
//   bash scripts/dev-agent.sh load     # writes a LaunchAgent plist + loads
//   bash scripts/dev-agent.sh kickstart
//   bash scripts/dev-agent.sh log      # tail stderr
//   bash scripts/dev-agent.sh unload
//
// In v0.2.0 production this binary lives at
//   Kith.app/Contents/MacOS/KithAgent
// and is registered via `SMAppService.agent(plistName:).register()` from
// the Kith.app GUI bootstrap target.

let normalizer = KithPhoneNumberNormalizer()
let store = CNBackedContactsStore(normalizer: normalizer)

let server: XPCServer
do {
    let criteria = try XPCServer.MachServiceCriteria(
        machServiceName: kithAgentMachServiceName,
        clientRequirement: XPCServer.ClientRequirement.sameTeamIdentifier
    )
    server = try XPCServer.forMachService(withCriteria: criteria)
} catch {
    FileHandle.standardError.write(Data("kith-agent: bind \(kithAgentMachServiceName) failed: \(error)\n".utf8))
    exit(1)
}

server.registerRoute(AgentRoutes.find) { (query: ContactsQuery) async throws -> [Contact] in
    do {
        return try store.find(query: query)
    } catch ContactsError.permissionDenied {
        throw KithWireError.permissionDenied("Contacts access denied. Grant Kith.app permission in System Settings → Privacy & Security → Contacts.")
    } catch let ContactsError.notFound(m) {
        throw KithWireError.notFound(m)
    } catch let ContactsError.ambiguous(m, candidates) {
        throw KithWireError.ambiguous(m, candidates: candidates)
    } catch {
        throw KithWireError.internal(String(describing: error))
    }
}

// SecureXPC's setErrorHandler closure is `@isolated(any) async` and
// crashes under Swift 6 strict concurrency when invoked from arbitrary
// queues. Letting SecureXPC use its default (logs to stderr) is fine for
// now; revisit if we need richer error propagation.

FileHandle.standardError.write(Data("kith-agent: listening on \(kithAgentMachServiceName)\n".utf8))
server.startAndBlock()

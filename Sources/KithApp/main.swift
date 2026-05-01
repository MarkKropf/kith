import Foundation
import ServiceManagement

// KithApp
//
// One-shot bootstrap that registers `com.supaku.kith.agent` as a LaunchAgent
// embedded in this same .app bundle, then exits. Run by:
//
//   - `open -a /Applications/Kith.app`         (manual)
//   - `kith` CLI on first invoke when the Mach service isn't yet registered
//   - Cask postflight (`brew install --cask kith` triggers a one-time launch)
//
// Has no UI, no Dock icon (LSUIElement=true in Info.plist). The actual TCC
// prompt fires later, when the agent makes its first CNContactStore call —
// the prompt is named "Kith" and reads the NSContactsUsageDescription from
// this .app's Info.plist.

let plistName = "com.supaku.kith.agent.plist"
let agent = SMAppService.agent(plistName: plistName)

let action = CommandLine.arguments.dropFirst().first ?? "register"

switch action {
case "register":
    do {
        try agent.register()
        FileHandle.standardError.write(Data("Kith: registered \(plistName); status=\(agent.status.rawValue)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Kith: registration failed: \(error)\n".utf8))
        exit(1)
    }

case "unregister":
    do {
        try agent.unregister()
        FileHandle.standardError.write(Data("Kith: unregistered \(plistName)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Kith: unregister failed: \(error)\n".utf8))
        exit(1)
    }

case "status":
    let label: String = switch agent.status {
    case .notRegistered:    "not-registered"
    case .enabled:          "enabled"
    case .requiresApproval: "requires-approval"
    case .notFound:         "not-found"
    @unknown default:       "unknown"
    }
    print(label)

default:
    FileHandle.standardError.write(Data("Kith: unknown action '\(action)' (expected: register | unregister | status)\n".utf8))
    exit(2)
}

exit(0)

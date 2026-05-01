import AppKit
import Contacts
import Foundation
import ServiceManagement

// Initialize AppKit with .accessory activation policy. CNContactStore's
// `requestAccess` displays its prompt via the AppKit run-loop machinery —
// without an NSApplication infrastructure to host the dialog, macOS fails
// fast with "Access Denied" instead of presenting the prompt. `.accessory`
// gives us the AppKit context needed to display the prompt, but doesn't
// add a Dock icon or menu bar (consistent with LSUIElement=true). Activate
// with `ignoringOtherApps: true` so the prompt actually surfaces above
// whatever the user is currently focused on.
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
nsApp.activate(ignoringOtherApps: true)

// KithApp
//
// One-shot bootstrap that registers `com.supaku.kith.agent` as a LaunchAgent
// embedded in this same .app bundle, then exits. Run by:
//
//   - `open -a /Applications/Kith.app`         (manual)
//   - `kith` CLI on first invoke when the Mach service isn't yet registered
//   - Cask postflight (`brew install --cask kith` triggers a one-time launch)
//
// Has no Dock icon (LSUIElement=true in Info.plist). It does, however, fire
// the TCC prompt for Contacts during `register` — the prompt comes from the
// .app's own context (where Bundle.main is Kith.app and the
// NSContactsUsageDescription string is found), not from the agent's. A
// background LaunchAgent has no foreground UI to host the system prompt, so
// running it from there silently gets `.denied` even with the right Info.plist
// — that's the difference between v0.2.1 and v0.2.2.

let plistName = "com.supaku.kith.agent.plist"
let agent = SMAppService.agent(plistName: plistName)

let action = CommandLine.arguments.dropFirst().first ?? "register"

/// Request Contacts access from this .app's UI context. Blocks until the
/// user clicks Allow / Don't Allow, or returns immediately if the system
/// already has a recorded answer (.granted or .denied). Logs the outcome
/// to stderr so the calling shell sees what happened.
func requestContactsAccess() {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    let pre: String = {
        switch status {
        case .notDetermined:     return "not-determined"
        case .restricted:        return "restricted"
        case .denied:            return "denied"
        case .authorized:        return "authorized"
        @unknown default:        return "unknown"
        }
    }()
    FileHandle.standardError.write(Data("Kith: contacts auth pre-prompt = \(pre)\n".utf8))

    guard status == .notDetermined else {
        // Either already granted (nothing to do) or already denied (prompt
        // won't fire — user must enable in System Settings). Surface the
        // current status and let the caller act.
        return
    }

    // Pump the AppKit run loop while the request is in flight. A blocking
    // semaphore.wait() would freeze the main thread and the system's
    // prompt would never display — TCC prompts ride on the run loop.
    var done = false
    let store = CNContactStore()
    store.requestAccess(for: .contacts) { granted, error in
        let outcome = granted ? "granted" : "denied"
        let detail = error.map { " (\($0.localizedDescription))" } ?? ""
        FileHandle.standardError.write(Data("Kith: contacts auth post-prompt = \(outcome)\(detail)\n".utf8))
        done = true
    }
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    if !done {
        FileHandle.standardError.write(Data("Kith: contacts prompt timed out after 60s\n".utf8))
    }
}

switch action {
case "register":
    do {
        try agent.register()
        FileHandle.standardError.write(Data("Kith: registered \(plistName); status=\(agent.status.rawValue)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Kith: registration failed: \(error)\n".utf8))
        exit(1)
    }
    // Trigger the Contacts TCC prompt from this .app's UI context. This is
    // the right side of the responsibility chain to host the prompt; the
    // background agent can't display one. Skipped silently if status is
    // already granted/denied.
    requestContactsAccess()

case "request-contacts":
    // Standalone path the CLI can invoke (`open -a Kith.app --args
    // request-contacts`) to re-prompt without re-registering. Useful when
    // the user wants to grant access after dismissing the initial prompt.
    requestContactsAccess()

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
    FileHandle.standardError.write(Data("Kith: unknown action '\(action)' (expected: register | request-contacts | unregister | status)\n".utf8))
    exit(2)
}

exit(0)

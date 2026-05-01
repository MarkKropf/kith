# Security policy

## Reporting a vulnerability

Use [GitHub's private security advisory](https://github.com/supaku/kith/security/advisories/new) to report any security concern. We'll triage within 5 business days.

Please do not file public issues for security-sensitive problems.

## Scope

`kith` is a read-only CLI that talks to local macOS subsystems (`CNContactStore`, the user's `~/Library/Messages/chat.db`). Issues we'd like to know about:

- Output that leaks data outside what the user explicitly requested (e.g., a contact's data appearing in a query that shouldn't have matched).
- Crashes, hangs, or infinite loops triggered by attacker-controlled message content (a malicious sender could craft a message `attributedBody` blob).
- Path-traversal or command-injection paths via filenames in the attachments table.
- Issues in the vendored `MessagesCore` (originally from [imsg](https://github.com/steipete/imsg), MIT) — we'll coordinate disclosure upstream where appropriate.
- Supply-chain concerns about transitive dependencies (`SQLite.swift`, `PhoneNumberKit`, `swift-argument-parser`).

## Out of scope

- Anything that requires the attacker to already have local code execution as the user.
- Findings that depend on the user voluntarily granting Full Disk Access to a malicious binary.
- Reports against the macOS TCC subsystem itself.

## Supported versions

Latest minor release on `main` only. We don't backport security fixes to prior versions during the 0.x series.

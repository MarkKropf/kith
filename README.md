# kith

[![CI](https://github.com/supaku/kith/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/supaku/kith/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/supaku/kith?label=release&sort=semver)](https://github.com/supaku/kith/releases)
[![License: MIT](https://img.shields.io/github/license/supaku/kith)](./LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://github.com/supaku/kith#permissions)

> A macOS CLI that bridges Apple Contacts and iMessage for terminal users and AI agents.

`kith` resolves a name to a person to a chat. The killer flow:

```sh
kith history --with "Mark Kropf"
```

…walks `CNContactStore` to find Mark, collects all his phones (E.164) and emails,
joins them against `~/Library/Messages/chat.db` to find the canonical 1:1
conversation, and streams messages newest-first. Group chats and named threads
are auto-excluded so "messages with Mark" actually means messages with Mark.

Read-only. macOS 14+. arm64.

---

## Install

### Homebrew (recommended)

Phase A — the formula lives in this repo, so you tap the source directly:

```sh
brew tap supaku/kith https://github.com/supaku/kith
brew install kith
```

Builds from source via your Swift toolchain. No signed-binary downloads in
this phase. Phase B will migrate the formula to a `supaku/tools` tap with
signed/notarized bottles:

```sh
# Phase B (not yet shipped)
brew tap supaku/tools
brew install kith
```

### Manual

```sh
git clone https://github.com/supaku/kith.git
cd kith
swift build -c release
cp .build/release/kith ~/bin/   # or anywhere on $PATH
```

Or use the bundled script — it stamps `BuildInfo.swift` with the current commit
SHA + ISO build timestamp:

```sh
scripts/build.sh
```

To codesign with a Developer ID Application certificate (hardened runtime):

```sh
KITH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh
```

---

## Permissions

`kith` needs two macOS permission grants. Run `kith doctor` first — it tells
you exactly what's missing and how to fix it.

### 1. Contacts

Granted via the standard TCC prompt the first time you run `kith find`. If your
terminal isn't pre-listed in **System Settings → Privacy & Security → Contacts**:

- Click `+`, navigate to your terminal app (Ghostty, iTerm, Terminal, etc.), add it.
- For Electron apps (VS Code), you must `+`-add manually since they don't declare
  `NSContactsUsageDescription`.
- **Cmd+Q to fully quit your terminal**, then relaunch — TCC grants only inherit
  on a fresh process tree.

### 2. Full Disk Access

Required to read `~/Library/Messages/chat.db`. There is no programmatic prompt:

- **System Settings → Privacy & Security → Full Disk Access**.
- Add your *terminal* (not the `kith` binary itself — FDA is inherited by child
  processes).
- Restart the terminal.

If `kith doctor --json` reports `permissions.fullDiskAccess.status: "denied"`,
the most common fix is the quit-and-relaunch step — toggling the switch while
the terminal is running won't take effect.

---

## Usage

### Find people

```sh
kith find --name "Mark"
kith find --email "@acme.com"
kith find --phone "(415) 555-1212"
kith find --org "Rensei" --jsonl
```

### Resolve canonically

```sh
kith get "Mark Kropf"
kith get 0AB81E1A-DEAD-BEEF-CAFE-000000000001 --json
```

### List chats

```sh
kith chats --limit 20
kith chats --with "Mark Kropf"          # cross-domain: name → all chats
kith chats --participant "+14155551212"  # by handle
```

### Stream message history

```sh
kith history --with "Mark Kropf"                     # canonical 1:1 (default)
kith history --with chat-id:158                       # explicit chat
kith history --with "Mark Kropf" --limit 200 --jsonl
kith history --with "Mark Kropf" --start 2026-01-01T00:00:00Z
kith history --with "Mark Kropf" --inline            # render images in supported terminals
kith history --with "Mark Kropf" --raw-text          # skip the U+FFFC/U+FFFD/U+0000 cleanup
kith history --with "Mark Kropf" --include-reactions
kith history --with "Mark Kropf" --attachments       # add metadata array per message
```

`--with` accepts: `name | phone | email | chat-id:<n> | chat-guid:<g> | <CNContact-uuid>`.
Chat-id and chat-guid forms **require** the prefix; bare integers are never
interpreted as chat IDs. Multiple chat-ids can be unioned via
`--with chat-id:1,4,7`.

The default behavior auto-prefers the canonical 1:1 conversation (chat where
`chat_identifier` matches an identity, no `display_name`, exactly one other
participant) — group chats and named threads are excluded. When the resolution
spans multiple 1:1 shards (chat-id rotation), they're unioned silently. When
only group chats match, kith exits 4 with the candidate list so you can pick
explicitly.

### Diagnostics

```sh
kith doctor               # human report
kith doctor --json        # machine-readable
```

### Agent introspection

```sh
kith tools manifest --style kith        # native shape (source of truth)
kith tools manifest --style anthropic   # input_schema-style tools array
kith tools manifest --style openai      # function-tool array
kith tools manifest --style json-schema # full JSON Schema 2020-12

kith tools schema --type Message        # any of: Contact, ContactGroup, Chat,
                                        # Message, Handle, Attachment, Error,
                                        # DoctorReport
kith tools help                         # full command surface in one stream
```

---

## Output

### Modes

| flag | applies to | format |
|------|-----------|--------|
| (none) | all commands | TTY-friendly human output, ANSI-styled |
| `--json` | single-record commands (`get`, `doctor`, `version`) | one JSON object |
| `--jsonl` | streaming commands (`find`, `chats`, `history`, `groups …`) | newline-delimited objects |

Errors emit a JSON envelope to stderr in machine mode (`code`, `exit`,
`message`, `hint`, `candidates`); in human mode, a single-line error + indented
hint + a candidate list when relevant.

Color is automatic when stdout is a TTY. Override via `--color {auto,always,never}`,
`KITH_COLOR=always|never`, `NO_COLOR`, or `CLICOLOR_FORCE=1` env vars.

### Inline images

`kith history --inline` renders attachment images directly in the terminal
when one of these is detected:

- **iTerm2** (`TERM_PROGRAM=iTerm.app`) — iTerm2 inline image protocol.
- **VS Code's integrated terminal** (`TERM_PROGRAM=vscode`) — same protocol.
- **WezTerm** (`TERM_PROGRAM=WezTerm`) — same protocol.
- **Ghostty** (any of `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`,
  `GHOSTTY_VERSION`, `TERM_PROGRAM=ghostty`) — Kitty graphics protocol.
- **Kitty / KITTY_WINDOW_ID set** — Kitty graphics protocol.

If none match, `--inline` silently falls back to `[attachment: <name>]` text.
Force the protocol with `KITH_INLINE_PROTOCOL=kitty|iterm2|none` (helpful inside
tmux, where outer-terminal env vars sometimes get masked). Set `KITH_DEBUG=1`
to see why a particular attachment didn't render.

HEIC / HEIF / WEBP attachments are converted to PNG via `/usr/bin/sips` before
transmission. Animated GIFs render as a still on Kitty-protocol terminals.

`--inline` is mutually exclusive with `--jsonl`.

### Exit codes

| code | meaning |
|------|---------|
| 0 | OK |
| 1 | GENERIC_ERROR |
| 2 | USAGE |
| 3 | NOT_FOUND |
| 4 | AMBIGUOUS_MATCH (caller must disambiguate) |
| 5 | PERMISSION_DENIED (TCC: Contacts or FDA) |
| 6 | DB_UNAVAILABLE |
| 7 | INVALID_INPUT |

---

## Agent integration

`kith` is built so an LLM agent can ingest the entire CLI surface with one
tool call:

```sh
# Native shape — ideal for an in-house tool registry.
kith tools manifest --style kith

# Drop straight into an Anthropic Messages API tools[] array.
kith tools manifest --style anthropic

# OpenAI tool-calling shape.
kith tools manifest --style openai

# Or, if your agent prefers reading help text rather than JSON schemas:
kith tools help                  # 200-ish lines, every command + flag
```

For BI/observability use cases, the typical recipe is:

1. `kith doctor --json` once, gate on `ok: true`.
2. `kith find --name "<query>" --jsonl --limit 5` to surface candidate contacts.
3. `kith get "<exact-full-name>" --resolve-only --json` to lock in `id` +
   `fullName` (the CNContact UUID is stable; a future-proof handle).
4. `kith history --with <id> --jsonl --limit 200` to stream messages.

Pin the contact UUID in your records — it survives renames and contact merges
better than a phone number.

---

## Layout

| path | what |
|------|------|
| `Sources/kith` | the executable + manifest projections |
| `Sources/ContactsCore` | `CNContactStore` wrapper + `Contact`/`ContactGroup` models |
| `Sources/MessagesCore` | vendored from [imsg](https://github.com/steipete/imsg) (MIT) — sync via `scripts/vendor-sync.sh` |
| `Sources/ResolveCore` | the `--with` parser + cross-domain `Resolver` |
| `Tests/*Tests` | Swift Testing test suites |
| `Formula/kith.rb` | Homebrew formula (build-from-source) |
| `.github/workflows/` | CI + release |
| `.claude/PLAN.md` | v1 architecture plan (single source of truth) |

`THIRD_PARTY_NOTICES.md` carries the MIT attribution + full license text for
vendored sources.

---

## Tests

```sh
swift test
```

79+ Swift Testing tests across 4 targets. The non-CN-dependent suites use
in-memory SQLite fixtures; `kithTests` shells the built binary against an
on-disk fixture DB via `KITH_DB_PATH`. None of the tests require real Contacts
or FDA grants.

---

## License

MIT — see `LICENSE`. Vendored MessagesCore is also MIT (Peter Steinberger);
see `THIRD_PARTY_NOTICES.md` for attribution.

A [Supaku Labs](https://github.com/supaku) project.

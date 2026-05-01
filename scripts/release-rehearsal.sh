#!/usr/bin/env bash
# Local end-to-end release rehearsal — run before pushing a tag.
#
# Three modes, picked by env var (cheapest first):
#
#   default                       fast: build, package, smoke. No signing,
#                                 no notarize. Catches packaging bugs but
#                                 NOT TCC / first-run / Gatekeeper bugs.
#
#   KITH_REHEARSE_DEV_SIGN=1      adds Developer ID signing in place. Lets
#                                 us register the LaunchAgent (SecureXPC's
#                                 MachService rejects ad-hoc-signed) but
#                                 the .app is still spctl-rejected, so TCC
#                                 prompts auto-deny.
#
#   KITH_REHEARSE_NOTARIZE=1      runs the FULL release pipeline: dev
#                                 sign + scripts/sign-and-notarize.sh
#                                 (which submits to Apple's notary +
#                                 staples the .app). 5–15 min round trip.
#                                 Sources .env.local for the secrets.
#                                 After staple, asserts spctl reports
#                                 "Notarized Developer ID". This is the
#                                 only mode that reproduces production-
#                                 install behavior — use it when you've
#                                 touched TCC, the bundle layout, signing
#                                 identifiers, or anything around the
#                                 first-run UX. Implies KITH_REHEARSE_AGENT
#                                 unless the caller turns it off
#                                 explicitly.
#
#   KITH_REHEARSE_SIGN=1          legacy alias for "run sign-and-notarize
#                                 with KITH_SKIP_NOTARIZE=1" — exercises
#                                 the inside-out codesign flow without the
#                                 network round-trip. Kept because the CI
#                                 dry-run uses it.
#
#   KITH_REHEARSE_AGENT=1         install the staged Kith.app to
#                                 ~/Applications, register its LaunchAgent,
#                                 verify XPC round-trip via `kith doctor`.
#                                 Independent of the signing modes.
#
# The phone-parse smoke ("kith chats --jsonl …") catches missing SwiftPM
# resource bundles — the failure mode that made it past v0.1.0. Keep it.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source version.env

STAGE="$REPO_ROOT/dist/staging"
ARCHIVE="dist/kith-${KITH_VERSION}-macos-arm64.tar.gz"

DEV_ID="${KITH_DEV_IDENTITY:-Developer ID Application: Mark Kropf (BDJC7XF394)}"

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64

echo "==> stage Kith.app + CLI to $STAGE"
bash scripts/package.sh stage "$STAGE"

if [[ "${KITH_REHEARSE_DEV_SIGN:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_DEV_SIGN=1 — sign Kith.app + CLI with local Developer ID"
  echo "    identity: $DEV_ID"
  # Unified identifier: see scripts/sign-and-notarize.sh for the why.
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --sign "$DEV_ID" \
    "$STAGE/Kith.app/Contents/MacOS/KithAgent"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --sign "$DEV_ID" \
    "$STAGE/Kith.app/Contents/MacOS/KithApp"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --sign "$DEV_ID" \
    "$STAGE/Kith.app"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith --sign "$DEV_ID" \
    "$STAGE/libexec/kith"
  codesign --verify --deep --strict "$STAGE/Kith.app"
  codesign --verify "$STAGE/libexec/kith"
fi

if [[ "${KITH_REHEARSE_SIGN:-0}" == "1" ]]; then
  echo "==> rehearse full sign (KITH_SKIP_NOTARIZE=1, no network round-trip)"
  KITH_SKIP_NOTARIZE=1 bash scripts/sign-and-notarize.sh "$STAGE"
fi

if [[ "${KITH_REHEARSE_NOTARIZE:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_NOTARIZE=1 — full sign + notarize + staple"
  if [[ ! -f "$REPO_ROOT/.env.local" ]]; then
    echo "FAIL: $REPO_ROOT/.env.local missing — that's where the Apple notary" >&2
    echo "      secrets live (APPLE_DEVELOPER_ID, APPLE_PASSWORD, APPLE_TEAM_ID," >&2
    echo "      APPLE_DEVELOPER_ID_CERT_BASE64, APPLE_DEVELOPER_ID_CERT_PASSWORD)." >&2
    exit 1
  fi
  # Source .env.local with auto-export so scripts/sign-and-notarize.sh's
  # subprocess inherits the secrets. Keep the variables out of the parent
  # shell's history by running this in a subshell-style block.
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.env.local"
  set +a
  for var in APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD \
             APPLE_DEVELOPER_ID APPLE_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!var:-}" ]]; then
      echo "FAIL: $var not set after sourcing .env.local — check the file" >&2
      exit 1
    fi
  done

  echo "==> running sign-and-notarize.sh end-to-end (5–15 min for notarytool)"
  bash scripts/sign-and-notarize.sh "$STAGE"

  echo "==> assert spctl recognizes Kith.app as notarized"
  spctl_out="$(spctl --assess --type execute --verbose "$STAGE/Kith.app" 2>&1)"
  echo "$spctl_out"
  if ! echo "$spctl_out" | grep -q "Notarized Developer ID"; then
    echo "FAIL: post-staple Kith.app not seen as notarized by spctl. Above is the assess output." >&2
    exit 1
  fi
  echo "    spctl: $(echo "$spctl_out" | head -1)"

  # KITH_REHEARSE_NOTARIZE implies the agent path — the whole point of
  # notarizing is to verify TCC prompts fire from a real notarized .app.
  # Caller can set KITH_REHEARSE_AGENT=0 explicitly if they want to skip.
  if [[ -z "${KITH_REHEARSE_AGENT+x}" ]]; then
    KITH_REHEARSE_AGENT=1
  fi
fi

echo "==> tarball"
bash scripts/package.sh tarball "$STAGE" "$ARCHIVE"

EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
tar -C "$EXTRACT" -xzf "$ARCHIVE"

# Verify the layout the cask installs.
for needed in kith libexec/kith Kith.app/Contents/Info.plist \
              Kith.app/Contents/MacOS/KithApp Kith.app/Contents/MacOS/KithAgent \
              Kith.app/Contents/Library/LaunchAgents/com.supaku.kith.agent.plist \
              Kith.app/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle \
              Kith.app/Contents/Resources/SQLite.swift_SQLite.bundle; do
  if [[ ! -e "$EXTRACT/$needed" ]]; then
    echo "FAIL: tarball missing $needed" >&2
    exit 1
  fi
done

# Different-prefix symlink mimics the brew install layout: the user invokes
# kith via /opt/homebrew/bin/kith, which is a symlink into the cask's
# staged_path. Bundle.main resolves relative to argv[0] — i.e. relative to
# the symlink path, NOT the resolved target. The wrapper script handles this
# by chasing the symlink chain itself before exec'ing the real binary.
ln -s "$EXTRACT/kith" "$EXTRACT/kith-link"

echo "==> kith version (basic launch through the wrapper)"
"$EXTRACT/kith-link" version

echo "==> kith chats --jsonl with bogus KITH_DB_PATH (forces local-mode resource load)"
out="$(KITH_DB_PATH="/tmp/kith-rehearsal-nonexistent-$$.db" "$EXTRACT/kith-link" chats --jsonl 2>&1 || true)"
if echo "$out" | grep -q "could not load resource bundle"; then
  echo
  echo "FAIL: a SwiftPM resource bundle is missing from the package." >&2
  echo "      look at scripts/package.sh's REQUIRED_BUNDLES list and the .build/release/ dir." >&2
  echo
  echo "raw output:"
  echo "$out" >&2
  exit 1
fi

# ---- Optional: bootstrap Kith.app + verify against the live agent -----------
if [[ "${KITH_REHEARSE_AGENT:-0}" == "1" ]]; then
  echo "==> KITH_REHEARSE_AGENT=1 — installing Kith.app to ~/Applications"
  USER_APPS="$HOME/Applications"
  mkdir -p "$USER_APPS"
  # Boot out any prior registration so we exercise the full register path.
  /bin/launchctl bootout "gui/$UID/com.supaku.kith.agent" 2>/dev/null || true
  rm -rf "$USER_APPS/Kith.app"
  cp -R "$STAGE/Kith.app" "$USER_APPS/Kith.app"

  echo "==> launching Kith.app (register LaunchAgent)"
  # KithApp.register fires a Contacts TCC prompt as part of its register
  # flow on macOS 14+. The local-dev-signed (unnotarized) build is
  # spctl-rejected, so the prompt is auto-denied and the .app exits
  # quickly — that's expected here. In production (notarized) the prompt
  # actually shows. We only care about whether the agent registered.
  /usr/bin/open -a "$USER_APPS/Kith.app" --args register

  # Poll launchctl print up to ~10s — SMAppService.register() can take a
  # second on busy systems, and we don't want a flaky 3s sleep.
  registered=0
  for _ in $(seq 1 20); do
    if /bin/launchctl print "gui/$UID/com.supaku.kith.agent" >/dev/null 2>&1; then
      registered=1
      break
    fi
    sleep 0.5
  done
  if [[ "$registered" != "1" ]]; then
    echo "FAIL: com.supaku.kith.agent not registered with launchd within 10s." >&2
    echo "      Common cause: Kith.app isn't signed with a Developer ID. Re-run with" >&2
    echo "      KITH_REHEARSE_DEV_SIGN=1 to sign locally." >&2
    exit 1
  fi
  echo "    com.supaku.kith.agent registered."

  # The CLI's auto-bootstrap targets /Applications/Kith.app by default;
  # KITH_BOOTSTRAP_APP_PATH overrides that for the rehearsal.
  echo "==> kith doctor --json (verifies XPC reachability, ignores perm grants)"
  doctor_json="$(KITH_BOOTSTRAP_APP_PATH="$USER_APPS/Kith.app" "$EXTRACT/kith-link" doctor --json 2>/dev/null || true)"
  if ! echo "$doctor_json" | grep -q '"reachable"[[:space:]]*:[[:space:]]*true'; then
    echo "FAIL: agent not reachable per kith doctor --json" >&2
    echo "$doctor_json" | head -40 >&2
    exit 1
  fi
  if ! echo "$doctor_json" | grep -q "\"version\"[[:space:]]*:[[:space:]]*\"${KITH_VERSION}\""; then
    echo "WARN: agent's reported version doesn't match KITH_VERSION=${KITH_VERSION} (stale install?)" >&2
  fi
  echo "    agent reachable; XPC round-trip OK."

  # Notarized .app should be able to display TCC prompts. We can't fully
  # automate "the user clicks Allow," but we CAN verify that `kith find`
  # returns either success (already granted) or contactsNotDetermined
  # (auto-bootstrap fired the prompt) — what we DON'T want to see is
  # PERMISSION_DENIED with the bare message, which means macOS auto-denied
  # the prompt request (the v0.2.1 bug). Only run this assertion in
  # NOTARIZE mode since dev-signed builds always auto-deny.
  if [[ "${KITH_REHEARSE_NOTARIZE:-0}" == "1" ]]; then
    echo "==> verify TCC prompt path is reachable on notarized .app"
    echo "    (If a system prompt appears asking about Contacts, click Allow"
    echo "    to verify the full first-run flow. Otherwise the rehearsal"
    echo "    confirms the agent is at least reaching the TCC layer cleanly.)"
    find_out="$(KITH_BOOTSTRAP_APP_PATH="$USER_APPS/Kith.app" "$EXTRACT/kith-link" find --name "kith-rehearsal-impossible-name-$$" --jsonl --limit 1 2>&1 || true)"
    if echo "$find_out" | grep -q "Contacts access denied"; then
      echo "FAIL: notarized .app got Contacts access auto-denied — TCC prompt path is broken." >&2
      echo "      stderr was:" >&2
      echo "$find_out" >&2
      exit 1
    fi
    echo "    TCC prompt path OK (no auto-deny)."
  fi
else
  echo
  echo "skip: agent round-trip rehearsal (set KITH_REHEARSE_AGENT=1 to run; mutates your LaunchAgent registry)"
  echo "      For the agent path to actually work you'll need KITH_REHEARSE_DEV_SIGN=1"
  echo "      so Kith.app + CLI are signed with a Developer ID identity."
  echo "      To verify TCC prompts (first-run UX), use KITH_REHEARSE_NOTARIZE=1 —"
  echo "      slow (5–15 min), but the only mode that exercises Gatekeeper / TCC."
fi

echo
echo "==> rehearsal passed for kith ${KITH_VERSION}"
echo "    OK to: git tag -a v${KITH_VERSION} -m 'kith ${KITH_VERSION}' && git push origin v${KITH_VERSION}"

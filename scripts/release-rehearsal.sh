#!/usr/bin/env bash
# Local end-to-end release rehearsal — run before pushing a tag.
#
# What it does:
#   1. swift build -c release --arch arm64
#   2. scripts/package.sh stage dist/staging
#   3. (optional, gated by KITH_REHEARSE_DEV_SIGN=1) sign Kith.app + CLI
#      with the local Developer ID identity. No notarization. Required for
#      the agent path because SecureXPC's MachService binding rejects
#      ad-hoc-signed binaries.
#   4. (optional, gated by KITH_REHEARSE_SIGN=1) full sign + notarize
#      rehearsal via scripts/sign-and-notarize.sh with KITH_SKIP_NOTARIZE=1.
#   5. scripts/package.sh tarball dist/staging dist/kith-<v>-macos-arm64.tar.gz
#   6. extract the tarball into a temp dir and smoke-test the wrapper +
#      libexec layout (catches missing SwiftPM resource bundles).
#   7. (optional, gated by KITH_REHEARSE_AGENT=1) install Kith.app to
#      ~/Applications, register its LaunchAgent, run `kith doctor` against
#      the live agent, and assert the JSON report says agent.reachable=true.
#      Skips on a fresh install if Contacts/FDA aren't granted yet — the
#      reachability bit is what matters here, not perms.
#
# The phone-parse smoke (step 6 chats --participant) catches missing SwiftPM
# resource bundles, which is the failure mode that made it past v0.1.0.
# Don't drop it.

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
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith.agent --sign "$DEV_ID" \
    "$STAGE/Kith.app/Contents/MacOS/KithAgent"
  codesign --options runtime --force --timestamp \
    --identifier com.supaku.kith.app --sign "$DEV_ID" \
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
  /usr/bin/open -a "$USER_APPS/Kith.app" --args register
  # SMAppService.register() returns ~immediately; give launchd a moment.
  sleep 3

  if ! /bin/launchctl print "gui/$UID/com.supaku.kith.agent" >/dev/null 2>&1; then
    echo "FAIL: com.supaku.kith.agent not registered with launchd after Kith.app launch." >&2
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
else
  echo
  echo "skip: agent round-trip rehearsal (set KITH_REHEARSE_AGENT=1 to run; mutates your LaunchAgent registry)"
  echo "      For the agent path to actually work you'll also need KITH_REHEARSE_DEV_SIGN=1"
  echo "      so Kith.app + CLI are signed with a Developer ID identity."
fi

echo
echo "==> rehearsal passed for kith ${KITH_VERSION}"
echo "    OK to: git tag -a v${KITH_VERSION} -m 'kith ${KITH_VERSION}' && git push origin v${KITH_VERSION}"

#!/usr/bin/env bash
# Sign + notarize a kith release staging directory.
#
# Designed to run in CI on a macOS runner with no preexisting keychain. Imports
# the Developer ID Application cert into a fresh ephemeral keychain, codesigns
# the CLI + Kith.app (inside-out), and notarizes both via `xcrun notarytool`.
#
# Required env (matches the org-level secrets stored in supaku):
#   APPLE_DEVELOPER_ID_CERT_BASE64    base64-encoded .p12 of the Developer ID
#                                     Application certificate.
#   APPLE_DEVELOPER_ID_CERT_PASSWORD  password protecting the .p12.
#   APPLE_DEVELOPER_ID                Apple ID email (used by notarytool).
#   APPLE_PASSWORD                    app-specific password.
#   APPLE_TEAM_ID                     10-char Apple team identifier.
#
# Usage:
#   scripts/sign-and-notarize.sh [<staging-dir>]    # default: dist/staging
#
# Optional env to skip the network round-trip during local rehearsal:
#   KITH_SKIP_NOTARIZE=1   sign only — don't submit to notarytool / staple.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${1:-$REPO_ROOT/dist/staging}"

if [[ ! -d "$STAGE" ]]; then
  echo "error: staging directory not found: $STAGE" >&2
  echo "       run: scripts/package.sh stage [<dir>]" >&2
  exit 1
fi

CLI_BIN="$STAGE/libexec/kith"
APP_BUNDLE="$STAGE/Kith.app"

if [[ ! -x "$CLI_BIN" ]]; then
  echo "error: $CLI_BIN missing or not executable" >&2
  exit 1
fi
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: $APP_BUNDLE not present" >&2
  exit 1
fi

for var in APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD \
           APPLE_DEVELOPER_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: missing required env var: $var" >&2
    exit 1
  fi
done

WORK_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN_PATH="$WORK_DIR/kith-build.keychain-db"
KEYCHAIN_PASS="$(uuidgen)"
CERT_PATH="$WORK_DIR/kith-cert.p12"
CLI_ZIP="$WORK_DIR/kith-cli-notarize.zip"
APP_ZIP="$WORK_DIR/kith-app-notarize.zip"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  rm -f "$CERT_PATH" "$CLI_ZIP" "$APP_ZIP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> create ephemeral build keychain at $KEYCHAIN_PATH"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

echo "==> import Developer ID Application cert"
echo -n "$APPLE_DEVELOPER_ID_CERT_BASE64" | base64 --decode > "$CERT_PATH"
security import "$CERT_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
  -T /usr/bin/codesign

# Make the imported cert visible to codesign without an interactive prompt.
security list-keychains -d user -s "$KEYCHAIN_PATH" \
  $(security list-keychains -d user | tr -d '"')
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASS" \
  "$KEYCHAIN_PATH"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [[ -z "$IDENTITY" ]]; then
  echo "error: no Developer ID Application identity present after cert import" >&2
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" >&2
  exit 1
fi

# ---- Sign the CLI binary ------------------------------------------------------
echo "==> codesign $CLI_BIN with $IDENTITY"
codesign \
  --options runtime \
  --force \
  --timestamp \
  --identifier com.supaku.kith \
  --sign "$IDENTITY" \
  "$CLI_BIN"
codesign -dvvv "$CLI_BIN"

# ---- Sign Kith.app inside-out -------------------------------------------------
# Embedded executables MUST be signed before the parent .app, because the
# .app's seal computes hashes over its contents. Otherwise the parent's
# signature breaks the moment we re-sign the children.
echo "==> codesign embedded KithAgent"
codesign \
  --options runtime \
  --force \
  --timestamp \
  --identifier com.supaku.kith.agent \
  --sign "$IDENTITY" \
  "$APP_BUNDLE/Contents/MacOS/KithAgent"

echo "==> codesign embedded KithApp"
codesign \
  --options runtime \
  --force \
  --timestamp \
  --identifier com.supaku.kith.app \
  --sign "$IDENTITY" \
  "$APP_BUNDLE/Contents/MacOS/KithApp"

# SwiftPM resource bundles in Contents/Resources/ are sealed into the .app's
# resource-hash chain by the parent codesign — they're plain data
# directories, not nested code bundles, so we don't sign them individually.

echo "==> codesign Kith.app (hardened runtime, bundle identifier com.supaku.kith)"
codesign \
  --options runtime \
  --force \
  --timestamp \
  --identifier com.supaku.kith \
  --sign "$IDENTITY" \
  "$APP_BUNDLE"
codesign -dvvv "$APP_BUNDLE"

if [[ "${KITH_SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> KITH_SKIP_NOTARIZE=1 — skipping notarytool / stapler"
  exit 0
fi

# ---- Notarize the .app --------------------------------------------------------
echo "==> zip Kith.app for notarytool"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"

echo "==> notarytool submit Kith.app (--wait blocks until accepted or timeout)"
xcrun notarytool submit "$APP_ZIP" \
  --apple-id "$APPLE_DEVELOPER_ID" \
  --team-id  "$APPLE_TEAM_ID" \
  --password "$APPLE_PASSWORD" \
  --wait \
  --timeout 20m

echo "==> stapler staple Kith.app (works on .app bundles, unlike bare CLI)"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# ---- Notarize the bare CLI binary --------------------------------------------
# Bare-binary stapling isn't supported (`stapler staple` rejects Mach-O
# files); for an unzipped CLI, Gatekeeper does an online ticket lookup the
# first time the binary is executed. We still notarize so that ticket is
# registered with Apple.
echo "==> zip kith CLI for notarytool"
ditto -c -k --keepParent "$CLI_BIN" "$CLI_ZIP"

echo "==> notarytool submit kith CLI"
xcrun notarytool submit "$CLI_ZIP" \
  --apple-id "$APPLE_DEVELOPER_ID" \
  --team-id  "$APPLE_TEAM_ID" \
  --password "$APPLE_PASSWORD" \
  --wait \
  --timeout 20m

echo "==> attempt stapler on bare CLI (expected to fail; fine to skip)"
xcrun stapler staple "$CLI_BIN" 2>&1 \
  || echo "note: bare-binary staple is expected to fail; Gatekeeper does an online ticket lookup on first run."

echo "==> final spctl assess"
spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 \
  || echo "note: spctl on Kith.app should succeed post-notarize/staple; investigate if this fails."

echo "==> done."

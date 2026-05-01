#!/usr/bin/env bash
# Sign + notarize a kith release binary.
#
# Designed to run in CI on a macOS runner with no preexisting keychain. Imports
# the Developer ID Application cert into a fresh ephemeral keychain, codesigns
# the binary with hardened runtime, then notarizes via `xcrun notarytool`.
#
# Required env (matches the org-level secrets stored in supaku):
#   APPLE_DEVELOPER_ID_CERT_BASE64    base64-encoded .p12 of the Developer ID
#                                     Application certificate.
#   APPLE_DEVELOPER_ID_CERT_PASSWORD  password protecting the .p12.
#   APPLE_DEVELOPER_ID                Apple ID email (used by notarytool).
#   APPLE_PASSWORD                    app-specific password (NOT the Apple ID
#                                     account password).
#   APPLE_TEAM_ID                     10-char Apple team identifier.
#
# Usage: scripts/sign-and-notarize.sh [path/to/binary]
#   default binary path: .build/release/kith

set -euo pipefail

BIN="${1:-.build/release/kith}"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found or not executable: $BIN" >&2
  echo "       run 'swift build -c release --arch arm64' first" >&2
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
ZIP_PATH="$WORK_DIR/kith-notarize.zip"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  rm -f "$CERT_PATH" "$ZIP_PATH" 2>/dev/null || true
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

echo "==> codesign $BIN with $IDENTITY"
codesign \
  --options runtime \
  --force \
  --timestamp \
  --identifier com.supaku.kith \
  --sign "$IDENTITY" \
  "$BIN"

codesign -dvvv "$BIN"

echo "==> zip for notarytool (notarytool only accepts .zip / .pkg / .dmg)"
ditto -c -k --keepParent "$BIN" "$ZIP_PATH"

echo "==> notarytool submit (--wait blocks until accepted or timeout)"
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_DEVELOPER_ID" \
  --team-id  "$APPLE_TEAM_ID" \
  --password "$APPLE_PASSWORD" \
  --wait \
  --timeout 20m

# Stapling a bare CLI binary is not supported by `stapler staple`; only
# .app/.dmg/.pkg containers can be stapled. For a bare binary, Gatekeeper
# fetches the notarization ticket from Apple's CDN on first execution.
echo "==> attempt stapler (expected to fail on bare CLI; fine to skip)"
xcrun stapler staple "$BIN" 2>&1 \
  || echo "note: bare-binary staple is expected to fail; Gatekeeper does an online ticket lookup on first run."

echo "==> final codesign verify"
codesign -dvvv "$BIN"
echo "==> spctl assess (informational)"
spctl -a -vvv -t install "$BIN" 2>&1 \
  || echo "note: spctl may reject bare binaries; what matters is online ticket fetch at first run."

echo "==> done."

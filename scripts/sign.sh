#!/usr/bin/env bash
# Codesign the release kith binary with hardened runtime.
#
# Usage: KITH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/sign.sh

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/.build/release/kith"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found — run scripts/build.sh first" >&2
  exit 1
fi

if [[ -z "${KITH_SIGN_IDENTITY:-}" ]]; then
  echo "error: set KITH_SIGN_IDENTITY=\"Developer ID Application: ...\"" >&2
  exit 1
fi

echo "==> codesign --options runtime --sign \"$KITH_SIGN_IDENTITY\" $BIN"
codesign --options runtime --force --timestamp --sign "$KITH_SIGN_IDENTITY" "$BIN"

echo "==> verify"
codesign -dvvv "$BIN"
spctl -a -vvv -t install "$BIN" || {
  echo "note: spctl rejection is expected until the binary is notarized." >&2
}

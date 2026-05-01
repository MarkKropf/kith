#!/usr/bin/env bash
# Release build:
#   1. read version.env
#   2. write Sources/kith/Generated/BuildInfo.swift with version + commit + builtAt
#   3. swift build -c release
#   4. (optional) codesign + verify
#
# Codesigning is opt-in via KITH_SIGN_IDENTITY="Developer ID Application: ...".

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source version.env

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > Sources/kith/Generated/BuildInfo.swift <<EOF
import Foundation

enum BuildInfo {
    static let name = "kith"
    static let version = "${KITH_VERSION}"
    static let commit = "${COMMIT}"
    static let platform = "macOS 14+"
    static let builtAt = "${BUILT_AT}"
}
EOF

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/kith"
echo "built: $BIN ($(file "$BIN" | sed 's/.*: //'))"

if [[ -n "${KITH_SIGN_IDENTITY:-}" ]]; then
  "$REPO_ROOT/scripts/sign.sh"
fi

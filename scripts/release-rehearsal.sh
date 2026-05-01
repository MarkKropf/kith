#!/usr/bin/env bash
# Local end-to-end release rehearsal — run before pushing a tag.
#
# What it does:
#   1. swift build -c release --arch arm64
#   2. scripts/package.sh — package the libexec/wrapper tarball
#   3. extract the tarball into a temp dir
#   4. symlink the wrapper from a different prefix (mimics
#      /opt/homebrew/bin/kith → cask staged_path/kith)
#   5. run smoke commands through the symlinked wrapper
#
# The crucial smoke is a phone-parse command — that's what catches missing
# SwiftPM resource bundles, which is the failure mode that made it past
# v0.1.0. Don't drop this step "to save time."

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source version.env

ARCHIVE="dist/kith-${KITH_VERSION}-macos-arm64.tar.gz"

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64

echo "==> package"
bash scripts/package.sh "$ARCHIVE"

EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
tar -C "$EXTRACT" -xzf "$ARCHIVE"

# Different-prefix symlink mimics the brew install layout: the user invokes
# kith via /opt/homebrew/bin/kith, which is a symlink into the cask's
# staged_path. Bundle.main resolves relative to argv[0] — i.e. relative to
# the symlink path, NOT the resolved target. The wrapper script handles this
# by chasing the symlink chain itself before exec'ing the real binary.
ln -s "$EXTRACT/kith" "$EXTRACT/kith-link"

echo "==> kith version (basic launch through the wrapper)"
"$EXTRACT/kith-link" version

echo "==> kith chats --participant '+14155551212' (forces PhoneNumberKit load)"
out="$("$EXTRACT/kith-link" chats --participant "+14155551212" 2>&1 || true)"
if echo "$out" | grep -q "could not load resource bundle"; then
  echo
  echo "FAIL: a SwiftPM resource bundle is missing from the package." >&2
  echo "      look at scripts/package.sh's REQUIRED_BUNDLES list and the .build/release/ dir." >&2
  echo
  echo "raw output:"
  echo "$out" >&2
  exit 1
fi

echo
echo "==> rehearsal passed for kith ${KITH_VERSION}"
echo "    OK to: git tag -a v${KITH_VERSION} -m 'kith ${KITH_VERSION}' && git push origin v${KITH_VERSION}"

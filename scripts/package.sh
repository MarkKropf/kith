#!/usr/bin/env bash
# Package a kith release tarball with the libexec/wrapper layout the cask
# expects. Shared between .github/workflows/release.yml and
# scripts/release-rehearsal.sh so CI and local rehearsals stay in sync.
#
# Inputs (must already exist in .build/release/):
#   - kith                                          (the binary; signed in CI)
#   - PhoneNumberKit_PhoneNumberKit.bundle/         (PhoneNumberKit resources)
#   - SQLite.swift_SQLite.bundle/                   (SQLite.swift resources)
#
# Output:
#   $1 — path to write the .tar.gz to.

set -euo pipefail

ARCHIVE="${1:?usage: scripts/package.sh <output-tarball-path>}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -x .build/release/kith ]]; then
  echo "error: .build/release/kith not built" >&2
  echo "       run: swift build -c release --arch arm64" >&2
  exit 1
fi

REQUIRED_BUNDLES=(
  PhoneNumberKit_PhoneNumberKit.bundle
  SQLite.swift_SQLite.bundle
)
for bundle in "${REQUIRED_BUNDLES[@]}"; do
  if [[ ! -d ".build/release/$bundle" ]]; then
    echo "error: required SwiftPM resource bundle missing: .build/release/$bundle" >&2
    echo "       (a dep was added or removed without updating this list)" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$ARCHIVE")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/libexec"

cp .build/release/kith "$STAGE/libexec/kith"
for bundle in "${REQUIRED_BUNDLES[@]}"; do
  cp -R ".build/release/$bundle" "$STAGE/libexec/"
done

# /bin/sh wrapper that resolves its own symlink chain so it can find libexec/
# regardless of how it was invoked (directly, through brew's bin symlink, or
# anywhere else). Bundle.main.bundleURL ends up pointing at libexec/, which
# is where SwiftPM looks for resource bundles.
cat > "$STAGE/kith" <<'WRAPPER'
#!/bin/sh
SOURCE="$0"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="$DIR/$SOURCE" ;;
  esac
done
DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
exec "$DIR/libexec/kith" "$@"
WRAPPER
chmod +x "$STAGE/kith"

tar -C "$STAGE" -czf "$ARCHIVE" kith libexec
echo "==> wrote $ARCHIVE ($(du -h "$ARCHIVE" | awk '{print $1}'))"

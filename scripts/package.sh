#!/usr/bin/env bash
# Package a kith release into:
#   1. dist/staging/Kith.app                 — the bundled app + agent
#   2. dist/staging/kith                     — wrapper for the CLI
#   3. dist/staging/libexec/{kith,*.bundle}  — CLI binary + SwiftPM resources
# Then tarball dist/staging/ to <output-tarball-path> for the cask.
#
# Two subcommands:
#   bash scripts/package.sh stage [<staging-dir>]    # default: dist/staging
#   bash scripts/package.sh tarball <staging-dir> <archive-path>
#
# When invoked with a single argument that does not match a subcommand, the
# legacy "stage + tarball in one shot" form runs (backwards compatible with
# the v0.1.x release.yml). New release.yml/release-rehearsal.sh callers use
# the explicit two-step form so the staging dir can be signed in between.
#
# Inputs (must already exist in .build/release/):
#   - kith               (CLI binary)
#   - kith-agent         (KithAgent; SwiftPM names the executable kith-agent)
#   - KithApp            (KithApp bootstrap binary)
#   - PhoneNumberKit_PhoneNumberKit.bundle/
#   - SQLite.swift_SQLite.bundle/

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source version.env

REQUIRED_BUNDLES=(
  PhoneNumberKit_PhoneNumberKit.bundle
  SQLite.swift_SQLite.bundle
)

REQUIRED_BINARIES=(
  kith
  kith-agent
  KithApp
)

verify_inputs() {
  for bin in "${REQUIRED_BINARIES[@]}"; do
    if [[ ! -x ".build/release/$bin" ]]; then
      echo "error: required binary missing: .build/release/$bin" >&2
      echo "       run: swift build -c release --arch arm64" >&2
      exit 1
    fi
  done
  for bundle in "${REQUIRED_BUNDLES[@]}"; do
    if [[ ! -d ".build/release/$bundle" ]]; then
      echo "error: required SwiftPM resource bundle missing: .build/release/$bundle" >&2
      echo "       (a dep was added or removed without updating this list)" >&2
      exit 1
    fi
  done
}

stage() {
  local STAGE="${1:-$REPO_ROOT/dist/staging}"
  verify_inputs

  rm -rf "$STAGE"
  mkdir -p "$STAGE/libexec"

  # --- CLI: wrapper + libexec/ -----------------------------------------------
  cp .build/release/kith "$STAGE/libexec/kith"
  for bundle in "${REQUIRED_BUNDLES[@]}"; do
    cp -R ".build/release/$bundle" "$STAGE/libexec/"
  done

  # /bin/sh wrapper that resolves its own symlink chain so it can find
  # libexec/ regardless of how it was invoked. Bundle.main.bundleURL ends
  # up pointing at libexec/, where SwiftPM looks for resource bundles.
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

  # --- Kith.app bundle -------------------------------------------------------
  local APP="$STAGE/Kith.app"
  mkdir -p "$APP/Contents/MacOS"
  mkdir -p "$APP/Contents/Library/LaunchAgents"
  mkdir -p "$APP/Contents/Resources"

  # KithApp is the GUI bootstrap target; rename its binary at install time
  # to match CFBundleExecutable=KithApp in Info.plist.
  cp .build/release/KithApp     "$APP/Contents/MacOS/KithApp"
  # SwiftPM names the executable target `kith-agent` but the LaunchAgent
  # plist's BundleProgram references Contents/MacOS/KithAgent. Rename on copy.
  cp .build/release/kith-agent  "$APP/Contents/MacOS/KithAgent"
  chmod +x "$APP/Contents/MacOS/KithApp" "$APP/Contents/MacOS/KithAgent"

  # The agent is a fully-fledged binary with its own bundle identifier in
  # codesigning, but it lives under Kith.app/Contents/MacOS rather than
  # XPCServices/ so launchd can run it as a plain LaunchAgent.
  #
  # SwiftPM resource bundles are NOT macOS bundle directories — they're plain
  # directories with a `.bundle` suffix containing raw resource files (no
  # Info.plist, no CFBundleIdentifier). Putting them next to the executable
  # in Contents/MacOS/ makes codesign reject them as "bundle format
  # unrecognized" because it tries to treat them like nested code bundles.
  # The fix is to put them in Contents/Resources/ where they get sealed into
  # the parent .app's normal resource-hash chain. SwiftPM's Bundle.module
  # lookup checks `Bundle.main.resourceURL` first, which for an executable
  # running inside an .app resolves to Contents/Resources/ — so the agent
  # still finds the bundles at runtime.
  for bundle in "${REQUIRED_BUNDLES[@]}"; do
    cp -R ".build/release/$bundle" "$APP/Contents/Resources/"
  done

  # Info.plist + embedded LaunchAgent plist. These two files are excluded
  # from the SwiftPM compile via Package.swift's `exclude:` lists; they live
  # at fixed paths under Sources/KithApp/Resources/ for packaging.
  cp Sources/KithApp/Resources/Info.plist                       "$APP/Contents/Info.plist"
  cp Sources/KithApp/Resources/com.supaku.kith.agent.plist      "$APP/Contents/Library/LaunchAgents/com.supaku.kith.agent.plist"

  # Stamp Info.plist's CFBundleShortVersionString + CFBundleVersion to the
  # current `version.env` value so cask installs always carry a matching
  # advertised version. /usr/bin/plutil exists on every macOS.
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$KITH_VERSION" "$APP/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion           -string "$KITH_VERSION" "$APP/Contents/Info.plist"

  echo "==> staged kith ${KITH_VERSION} to $STAGE"
  echo "    $(du -sh "$STAGE/libexec" | awk '{print $1}')  CLI libexec/"
  echo "    $(du -sh "$APP" | awk '{print $1}')  Kith.app/"
}

tarball() {
  local STAGE="$1"
  local ARCHIVE="$2"
  if [[ ! -d "$STAGE" ]]; then
    echo "error: staging directory not found: $STAGE" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$ARCHIVE")"
  tar -C "$STAGE" -czf "$ARCHIVE" kith libexec Kith.app
  echo "==> wrote $ARCHIVE ($(du -h "$ARCHIVE" | awk '{print $1}'))"
}

case "${1:-}" in
  stage)
    stage "${2:-}"
    ;;
  tarball)
    if [[ -z "${2:-}" || -z "${3:-}" ]]; then
      echo "usage: scripts/package.sh tarball <staging-dir> <archive-path>" >&2
      exit 2
    fi
    tarball "$2" "$3"
    ;;
  "")
    echo "usage: scripts/package.sh {stage [<dir>] | tarball <dir> <archive>}" >&2
    exit 2
    ;;
  *)
    # Legacy single-arg form: "$1" is the output tarball path. Stage to a
    # temp dir, tarball it, clean up.
    LEGACY_STAGE="$(mktemp -d)"
    trap 'rm -rf "$LEGACY_STAGE"' EXIT
    stage "$LEGACY_STAGE"
    tarball "$LEGACY_STAGE" "$1"
    ;;
esac

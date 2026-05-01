#!/usr/bin/env bash
# v0.2.0 dev helper for the kith-agent LaunchAgent.
#
# SecureXPC's MachService binding requires the running process to be
# launchd-managed with the service name in the plist's MachServices key, so
# `swift run kith-agent` won't work directly. This script writes a LaunchAgent
# plist that points at the SwiftPM-built binary, registers it with launchd,
# and gives you the verbs you need to iterate.
#
# Usage:
#   bash scripts/dev-agent.sh build      # swift build + codesign with Developer ID
#   bash scripts/dev-agent.sh load       # write plist + launchctl bootstrap
#   bash scripts/dev-agent.sh kickstart  # force-restart the agent
#   bash scripts/dev-agent.sh log        # tail agent stderr
#   bash scripts/dev-agent.sh unload     # launchctl bootout + remove plist
#   bash scripts/dev-agent.sh status     # is the agent loaded?
#
# In v0.2.0 production this all moves into Kith.app + SMAppService, so
# this script is dev-only.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LABEL="com.supaku.kith.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
AGENT_BIN="$REPO_ROOT/.build/debug/kith-agent"
KITH_BIN="$REPO_ROOT/.build/debug/kith"
LOG_OUT="${TMPDIR:-/tmp}/kith-agent.out.log"
LOG_ERR="${TMPDIR:-/tmp}/kith-agent.err.log"

# Developer ID identity from .env.local — both binaries must be signed by
# the same team so SecureXPC's `.sameTeamIdentifier` requirement matches.
DEV_IDENTITY="Developer ID Application: Mark Kropf (BDJC7XF394)"

build() {
  echo "==> swift build"
  swift build
  if [[ ! -x "$AGENT_BIN" || ! -x "$KITH_BIN" ]]; then
    echo "error: build did not produce expected binaries" >&2
    exit 1
  fi
  echo "==> codesign agent + cli with $DEV_IDENTITY"
  codesign --force --options runtime --sign "$DEV_IDENTITY" \
    --identifier com.supaku.kith       "$KITH_BIN"
  codesign --force --options runtime --sign "$DEV_IDENTITY" \
    --identifier com.supaku.kith.agent "$AGENT_BIN"
}

write_plist() {
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>Program</key>
    <string>${AGENT_BIN}</string>
    <key>MachServices</key>
    <dict>
        <key>${LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
</dict>
</plist>
EOF
  echo "wrote $PLIST_PATH"
}

cmd="${1:-help}"
case "$cmd" in
  build)
    build
    ;;
  load)
    [[ -x "$AGENT_BIN" ]] || build
    write_plist
    # Use bootstrap (modern) with a fallback to load (deprecated but works on
    # older systems if bootstrap fails).
    if launchctl bootstrap "gui/$UID" "$PLIST_PATH" 2>/dev/null; then
      echo "bootstrapped → mach service available: $LABEL"
    else
      launchctl load "$PLIST_PATH"
      echo "loaded (legacy) → mach service available: $LABEL"
    fi
    ;;
  unload)
    if launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null; then
      echo "booted out"
    else
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      echo "unloaded (legacy)"
    fi
    rm -f "$PLIST_PATH"
    ;;
  kickstart)
    launchctl kickstart -k "gui/$UID/${LABEL}"
    echo "kickstarted"
    ;;
  log)
    echo "==> stdout: $LOG_OUT"
    echo "==> stderr: $LOG_ERR"
    touch "$LOG_OUT" "$LOG_ERR"
    tail -F "$LOG_OUT" "$LOG_ERR"
    ;;
  status)
    launchctl print "gui/$UID/${LABEL}" 2>&1 | head -30 || echo "not loaded"
    ;;
  help|*)
    cat <<USAGE
usage: bash scripts/dev-agent.sh <command>
  build      swift build + codesign cli + agent with Developer ID
  load       write plist + launchctl bootstrap (auto-builds if needed)
  kickstart  force-restart the agent
  log        tail agent stdout + stderr
  status     show launchctl print output
  unload     launchctl bootout + remove plist
USAGE
    ;;
esac

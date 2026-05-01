#!/usr/bin/env bash
# Sync vendored MessagesCore sources from upstream `imsg`.
#
# Usage: scripts/vendor-sync.sh
#   KITH_IMSG_PATH=/path/to/imsg overrides default upstream.
#
# Behavior:
#   - Copies the hard-coded file list from <upstream>/Sources/IMsgCore/ to
#     Sources/MessagesCore/, prepending the MIT-attribution header.
#   - The per-file header is NOT considered a local edit; it is added on
#     every sync.
#   - Refuses if `git status -s Sources/MessagesCore` shows uncommitted
#     edits to vendored files (substantive edits beyond the header).
#   - Idempotent: prints "nothing to do" if upstream is byte-identical.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${KITH_IMSG_PATH:-$HOME/Developer/lib/imsg}"
DEST="$REPO_ROOT/Sources/MessagesCore"

VENDORED_FILES=(
  "MessageStore.swift"
  "MessageStore+Messages.swift"
  "MessageStore+Helpers.swift"
  "MessageStore+ReactionEvents.swift"
  "Models.swift"
  "PhoneNumberNormalizer.swift"
  "TypedStreamParser.swift"
  "AttachmentResolver.swift"
  "MessageFilter.swift"
  "ISO8601.swift"
  "Errors.swift"
)

if [[ ! -d "$UPSTREAM" ]]; then
  echo "error: upstream not found at $UPSTREAM" >&2
  echo "       set KITH_IMSG_PATH to override" >&2
  exit 1
fi

UPSTREAM_SRC="$UPSTREAM/Sources/IMsgCore"
if [[ ! -d "$UPSTREAM_SRC" ]]; then
  echo "error: $UPSTREAM_SRC missing — wrong upstream layout?" >&2
  exit 1
fi

# Refuse if there are uncommitted edits to vendored files.
# Strip the per-file header before diffing so re-running on a fresh
# vendor-sync isn't flagged.
HEADER='// Vendored from https://github.com/steipete/imsg (MIT)
// Original copyright © Peter Steinberger. See THIRD_PARTY_NOTICES.md.
// Do not edit in-place; see scripts/vendor-sync.sh for upstream syncs.
'

cd "$REPO_ROOT"
DIRTY=0
if git status -s -- Sources/MessagesCore 2>/dev/null | grep -E '^[ MARCDU]M? Sources/MessagesCore/[A-Z][^/]+\.swift$' >/dev/null; then
  while IFS= read -r line; do
    file="${line:3}"
    [[ "$file" == Sources/MessagesCore/Extensions/* ]] && continue
    [[ "$file" == Sources/MessagesCore/README.md ]] && continue
    [[ "$file" == Sources/MessagesCore/MessagesCore.swift ]] && continue
    base="$(basename "$file")"
    upstream_file="$UPSTREAM_SRC/$base"
    [[ ! -f "$upstream_file" ]] && continue
    # Compare current file (minus header) against upstream
    if ! diff -q <(tail -n +4 "$file") "$upstream_file" >/dev/null 2>&1; then
      DIRTY=1
      echo "uncommitted edit to vendored file: $file" >&2
    fi
  done < <(git status -s -- Sources/MessagesCore)
fi

if [[ "$DIRTY" -eq 1 ]]; then
  echo "error: refusing to sync — commit or revert the edits above first." >&2
  exit 1
fi

mkdir -p "$DEST"

CHANGED=0
for f in "${VENDORED_FILES[@]}"; do
  src="$UPSTREAM_SRC/$f"
  dst="$DEST/$f"
  if [[ ! -f "$src" ]]; then
    echo "error: upstream file missing: $src" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  printf '%s' "$HEADER" > "$tmp"
  cat "$src" >> "$tmp"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    continue
  fi
  mv "$tmp" "$dst"
  CHANGED=$((CHANGED + 1))
  echo "synced $f"
done

# Resolve upstream sha + ISO date and rewrite the vendor README.
UPSTREAM_SHA="$(git -C "$UPSTREAM" rev-parse HEAD 2>/dev/null || echo unknown)"
SYNC_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$DEST/README.md" <<EOF
# MessagesCore (vendored)

Files in this directory are vendored from [imsg](https://github.com/steipete/imsg) (MIT). Do not edit in place; run \`scripts/vendor-sync.sh\` to pull updates from the upstream repo.

Original copyright © Peter Steinberger. See \`THIRD_PARTY_NOTICES.md\` at the repo root for the full license text.

Local-only files (kith-specific helpers, safe to edit directly) live under \`Extensions/\`.

vendored from imsg @ ${UPSTREAM_SHA}; sync date ${SYNC_DATE}
EOF

if [[ "$CHANGED" -eq 0 ]]; then
  echo "nothing to do (already in sync with $UPSTREAM_SHA)"
else
  echo "synced $CHANGED file(s) from $UPSTREAM_SHA"
fi

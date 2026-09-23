#!/usr/bin/env bash
# install.sh — install the pt-cmux hooks into Polytoken's global hooks.json.
#
# * Copies bin/pt-cmux-status and bin/pt-cmux-watcher into
#   ${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/pt-cmux/ (matching the path
#   baked into hooks/hooks.json).
# * Creates the global hooks.json (copying verbatim) or merges the cmux-*
#   entries into an existing one with jq, preserving unrelated hooks and
#   stripping any previous cmux-* entries (idempotent reinstall).
# * Backs up any pre-existing hooks.json before writing, and refuses to
#   touch a target that is not a valid non-empty JSON array.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOKS_SRC="$SCRIPT_DIR/hooks/hooks.json"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/polytoken"
PTCMUX_DIR="$CONFIG_DIR/pt-cmux"
TARGET="$CONFIG_DIR/hooks.json"

for f in "$HOOKS_SRC" "$SCRIPT_DIR/bin/pt-cmux-status" "$SCRIPT_DIR/bin/pt-cmux-watcher"; do
  if [ ! -f "$f" ]; then
    echo "error: required file missing: $f" >&2
    exit 1
  fi
done

# Locate jq (PATH first, then the Homebrew location).
jq_bin="$(command -v jq 2>/dev/null || true)"
if [ -z "$jq_bin" ] && [ -x /opt/homebrew/bin/jq ]; then
  jq_bin=/opt/homebrew/bin/jq
fi
if [ -z "$jq_bin" ]; then
  echo "error: jq is required to install/merge hooks.json (brew install jq)" >&2
  exit 1
fi
if ! "$jq_bin" empty "$HOOKS_SRC" 2>/dev/null; then
  echo "error: $HOOKS_SRC is not valid JSON" >&2
  exit 1
fi

if [ -f "$TARGET" ]; then
  # An existing target must be a valid JSON array before we touch it — an
  # empty or malformed file is an error, not "no hooks" (jq on empty input
  # succeeds with no output, which would otherwise truncate the file).
  if [ ! -s "$TARGET" ] || ! "$jq_bin" -e 'type == "array"' "$TARGET" >/dev/null 2>&1; then
    echo "error: $TARGET exists but is not a valid JSON array; refusing to modify it" >&2
    exit 1
  fi
fi

# Register the hooks first; only copy the scripts if that succeeds, so a
# failed install never leaves scripts without registered hooks.
mkdir -p "$CONFIG_DIR"

if [ ! -f "$TARGET" ]; then
  cp "$HOOKS_SRC" "$TARGET"
  echo "installed hooks to $TARGET (new file)"
else
  ts="$(date +%Y%m%d%H%M%S)"
  backup="$TARGET.$ts.$$.bak"
  cp "$TARGET" "$backup"
  tmp="$TARGET.tmp.$$"
  # Drop any previous cmux-* entries (idempotent reinstall), then append ours.
  if ! "$jq_bin" --slurpfile new "$HOOKS_SRC" \
      'map(select(((.name // "") | startswith("cmux-")) | not)) + $new[0]' \
      "$TARGET" >"$tmp"; then
    rm -f "$tmp"
    echo "error: merge failed; $TARGET left untouched (backup: $backup)" >&2
    exit 1
  fi
  if ! "$jq_bin" -e 'type == "array" and length > 0' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "error: merge produced an empty or invalid array; $TARGET left untouched" >&2
    exit 1
  fi
  mv "$tmp" "$TARGET"
  echo "merged cmux-* hooks into $TARGET (backup: $backup)"
fi

mkdir -p "$PTCMUX_DIR"
cp "$SCRIPT_DIR/bin/pt-cmux-status" "$PTCMUX_DIR/pt-cmux-status"
cp "$SCRIPT_DIR/bin/pt-cmux-watcher" "$PTCMUX_DIR/pt-cmux-watcher"
chmod +x "$PTCMUX_DIR/pt-cmux-status" "$PTCMUX_DIR/pt-cmux-watcher"
echo "installed scripts to $PTCMUX_DIR/"

echo "note: Polytoken loads global hooks at startup or after a config"
echo "reload — restart existing sessions (or reload config) for the hooks"
echo "to take effect."

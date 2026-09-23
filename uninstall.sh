#!/usr/bin/env bash
# uninstall.sh — remove the pt-cmux hooks from Polytoken's global config.
#
# * Strips cmux-* entries from ${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/hooks.json
#   (deleting the file if no hooks remain).
# * Removes the polytoken/pt-cmux/ script directory.
# * Best-effort: un-pins the current cmux workspace status (honors
#   PTCMUX_CMUX_BIN).

set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/polytoken"
TARGET="$CONFIG_DIR/hooks.json"

# Locate jq (PATH first, then the Homebrew location).
jq_bin="$(command -v jq 2>/dev/null || true)"
if [ -z "$jq_bin" ] && [ -x /opt/homebrew/bin/jq ]; then
  jq_bin=/opt/homebrew/bin/jq
fi

if [ -f "$TARGET" ]; then
  if [ -n "$jq_bin" ]; then
    # Refuse to mangle a target that is empty or not a valid JSON array
    # (jq on empty input succeeds with no output and would truncate it).
    if [ ! -s "$TARGET" ] || ! "$jq_bin" -e 'type == "array"' "$TARGET" >/dev/null 2>&1; then
      echo "warning: $TARGET is not a valid JSON array; left untouched" >&2
    else
      tmp="$TARGET.tmp.$$"
      if ! "$jq_bin" 'map(select(((.name // "") | startswith("cmux-")) | not))' \
          "$TARGET" >"$tmp"; then
        rm -f "$tmp"
        echo "error: filter failed; $TARGET left untouched" >&2
        exit 1
      fi
      remaining="$("$jq_bin" -r 'length' "$tmp" 2>/dev/null || true)"
      case "$remaining" in
        ''|*[!0-9]*)
          rm -f "$tmp"
          echo "error: could not count remaining hooks; $TARGET left untouched" >&2
          exit 1
          ;;
      esac
      if [ "$remaining" = "0" ]; then
        rm -f "$TARGET" "$tmp"
        echo "removed all hooks from $TARGET (file deleted — no hooks left)"
      else
        mv "$tmp" "$TARGET"
        echo "removed cmux-* hooks from $TARGET ($remaining hook(s) remain)"
      fi
    fi
  else
    echo "warning: jq not found; $TARGET left untouched — remove the cmux-* entries manually" >&2
  fi
else
  echo "no $TARGET present; nothing to strip"
fi

rm -rf "$CONFIG_DIR/pt-cmux"
echo "removed $CONFIG_DIR/pt-cmux/"

# Best-effort: un-pin the current workspace. PTCMUX_CMUX_BIN is honored
# with the same authoritative semantics as the hook handler, so tests (and
# users) never hit a real cmux installation by accident.
cmux_bin=""
if [ -n "${PTCMUX_CMUX_BIN:-}" ]; then
  if [ -x "$PTCMUX_CMUX_BIN" ]; then
    cmux_bin="$PTCMUX_CMUX_BIN"
  fi
else
  cmux_bin="$(command -v cmux 2>/dev/null || true)"
  if [ -z "$cmux_bin" ] && [ -x /Applications/cmux.app/Contents/Resources/bin/cmux ]; then
    cmux_bin=/Applications/cmux.app/Contents/Resources/bin/cmux
  fi
fi
if [ -n "$cmux_bin" ]; then
  "$cmux_bin" workspace status set auto >/dev/null 2>&1 || true
  echo "workspace status reset to auto"
fi

echo "uninstalled."

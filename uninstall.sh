#!/usr/bin/env bash
# uninstall.sh — remove the pt-cmux hooks and arrangement commands.
#
# * Strips cmux-* entries from ${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/hooks.json
#   (deleting the file if no hooks remain).
# * Removes the polytoken/pt-cmux/ script directory (which holds the two
#   arrangement commands as well as the two hook handlers).
# * Drops the pt-cmux-* entries from the cmux.json action registry, so the
#   Command Palette stops offering them. Foreign actions are preserved, and
#   a config with nothing of ours in it is not rewritten at all.
# * Best-effort: clears the cmux sidebar status pill for Polytoken, scrubs
#   any legacy workspace lane pin left by an older version, and reloads the
#   cmux configuration (honors PTCMUX_CMUX_BIN).

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

# ---- drop the pt-cmux-* entries from the cmux action registry ------------
#
# cmux.json is JSONC, so it cannot go through jq. The reader below is the
# same minimal string-aware one install.sh carries (keep the two in sync):
# it tracks string/escape state so a `//` inside a URL survives, drops
# comments, tolerates trailing commas, then hands the text to the json
# module. When there is nothing of ours to remove the file is never
# rewritten, so a config that never had our entries keeps its exact bytes,
# comments included.
CMUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cmux/cmux.json"

jsonc_strip() {
  python3 - "$@" <<'PY'
import json, os, stat, sys

def strip_comments(text):
    out = []
    i = 0
    n = len(text)
    in_string = False
    line_comment = False
    block_comment = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if line_comment:
            if c == "\n":
                line_comment = False
                out.append(c)
            i += 1
            continue
        if block_comment:
            if c == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            out.append(c)
            if c == "\\" and nxt:
                out.append(nxt)
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)

def strip_trailing_commas(text):
    out = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)

target = sys.argv[1]
tmp = sys.argv[2]

try:
    with open(target, "r", encoding="utf-8") as fh:
        original = fh.read()
except OSError as exc:
    sys.stderr.write("cannot read %s: %s\n" % (target, exc))
    sys.exit(2)

try:
    data = json.loads(strip_trailing_commas(strip_comments(original)))
except ValueError as exc:
    sys.stderr.write("%s is not parseable as JSONC: %s\n" % (target, exc))
    sys.exit(3)

if not isinstance(data, dict):
    sys.stderr.write("%s: top level is not a JSON object\n" % target)
    sys.exit(3)

existing = data.get("actions")
removed = 0
if isinstance(existing, dict):
    for key in [k for k in existing if k.startswith("pt-cmux-")]:
        del existing[key]
        removed += 1
    if removed:
        if existing:
            data["actions"] = existing
        else:
            data.pop("actions", None)
elif existing is not None:
    sys.stderr.write('%s: "actions" is present but is not an object\n' % target)
    sys.exit(4)

if removed:
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    # Carry the target's permissions over: cmux.json is commonly 0600, and a
    # freshly created file would otherwise land at 0644.
    try:
        os.chmod(tmp, stat.S_IMODE(os.stat(target).st_mode))
    except OSError:
        pass

sys.stdout.write("removed=%d\n" % removed)
sys.exit(0)
PY
}

if [ -f "$CMUX_CONFIG" ]; then
  if command -v python3 >/dev/null 2>&1; then
    tmp="$CMUX_CONFIG.tmp.$$"
    if strip_result="$(jsonc_strip "$CMUX_CONFIG" "$tmp")"; then
      if [ "$strip_result" = "removed=0" ]; then
        rm -f "$tmp"
        echo "no pt-cmux-* actions in $CMUX_CONFIG; left untouched"
      else
        count="${strip_result#removed=}"
        backup="$CMUX_CONFIG.$(date +%Y%m%d%H%M%S).$$.bak"
        cp "$CMUX_CONFIG" "$backup"
        if python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$tmp" 2>/dev/null; then
          mv "$tmp" "$CMUX_CONFIG"
          echo "removed $count pt-cmux-* action(s) from $CMUX_CONFIG (backup: $backup)"
        else
          rm -f "$tmp"
          echo "warning: the stripped config failed to reparse; $CMUX_CONFIG left untouched" >&2
        fi
      fi
    else
      rm -f "$tmp"
      echo "warning: $CMUX_CONFIG is not valid JSONC; left untouched" >&2
    fi
  else
    echo "warning: python3 not found; remove the pt-cmux-* actions from $CMUX_CONFIG by hand" >&2
  fi
else
  echo "no $CMUX_CONFIG present; nothing to strip"
fi

# Best-effort cleanup of both status surfaces. PTCMUX_CMUX_BIN is honored
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
  if "$cmux_bin" clear-status polytoken >/dev/null 2>&1; then
    echo "cleared the Polytoken status pill"
  else
    echo "warning: could not clear the Polytoken status pill" >&2
  fi
  # Legacy scrub: a lane pin left by the previously installed version of
  # this repo auto-clears per cmux's own override expiry; this just makes
  # it immediate.
  if "$cmux_bin" workspace status set auto >/dev/null 2>&1; then
    echo "scrubbed legacy workspace lane pin (if any)"
  else
    echo "warning: could not scrub the legacy workspace lane pin" >&2
  fi
  # Reload so the dropped actions stop showing up in the Command Palette
  # without an app restart.
  if "$cmux_bin" reload-config >/dev/null 2>&1; then
    echo "reloaded cmux configuration"
  else
    echo "warning: could not reload cmux config; run 'cmux reload-config'" >&2
  fi
fi

echo "uninstalled."

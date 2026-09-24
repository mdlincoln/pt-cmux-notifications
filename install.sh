#!/usr/bin/env bash
# install.sh — install the pt-cmux hooks and arrangement commands.
#
# * Copies bin/pt-cmux-status, bin/pt-cmux-watcher, bin/pt-cmux-spread and
#   bin/pt-cmux-gather into ${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/
#   pt-cmux/ (matching the path baked into hooks/hooks.json).
# * Creates the global hooks.json (copying verbatim) or merges the cmux-*
#   entries into an existing one with jq, preserving unrelated hooks and
#   stripping any previous cmux-* entries (idempotent reinstall).
# * Backs up any pre-existing hooks.json before writing, and refuses to
#   touch a target that is not a valid non-empty JSON array.
# * Registers the two arrangement commands in the cmux.json `actions`
#   registry (the Command Palette / shortcuts / surface tab bar surface).
#   cmux.json is JSONC, so it is parsed by a small string-aware reader
#   (python3) instead of jq (see the comments note in the README). That file
#   is fully validated — parse, shape, merged result, and cmux's own
#   `config check` — before the hooks or scripts are touched, and the merged
#   result is only swapped in at the end, so a cmux.json problem aborts the
#   install with nothing installed.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOKS_SRC="$SCRIPT_DIR/hooks/hooks.json"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/polytoken"
PTCMUX_DIR="$CONFIG_DIR/pt-cmux"
TARGET="$CONFIG_DIR/hooks.json"
CMUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cmux/cmux.json"

for f in "$HOOKS_SRC" \
         "$SCRIPT_DIR/bin/pt-cmux-status" \
         "$SCRIPT_DIR/bin/pt-cmux-watcher" \
         "$SCRIPT_DIR/bin/pt-cmux-spread" \
         "$SCRIPT_DIR/bin/pt-cmux-gather"; do
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

# ---- cmux.json (JSONC) actions registry ----------------------------------
#
# cmux.json is JSON with comments and trailing commas, so it cannot go
# through jq. jsonc_write below is a minimal string-aware reader: it tracks
# string/escape state so a `//` inside a URL is left alone, drops `//` and
# `/* */` comments, tolerates trailing commas, and then hands the result to
# the json module. Mode "check" parses and validates the `actions` shape;
# "merge" replaces every pt-cmux-* action with the entries in <actions-json>;
# "strip" drops them (removing the whole `actions` key if nothing is left).
# "merge" and "strip" write the result to <tmp> and print "changed=1|0" — 0
# means the file is already in the requested shape, in which case nothing is
# written and the caller leaves the file untouched.
jsonc_write() {
  python3 - "$@" <<'PY'
import copy, json, os, stat, sys

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

mode = sys.argv[1]
target = sys.argv[2]

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

if mode == "check":
    # check also validates the shape merge would need, so the caller can
    # refuse up front rather than after touching anything.
    if data.get("actions") is not None and not isinstance(data.get("actions"), dict):
        sys.stderr.write('%s: "actions" is present but is not an object\n' % target)
        sys.exit(4)
    sys.exit(0)

existing = data.get("actions")
if existing is not None and not isinstance(existing, dict):
    sys.stderr.write('%s: "actions" is present but is not an object\n' % target)
    sys.exit(4)

before = copy.deepcopy(existing)

if mode == "merge":
    actions = existing if existing is not None else {}
    for key in [k for k in actions if k.startswith("pt-cmux-")]:
        del actions[key]
    actions.update(json.loads(sys.argv[4]))
    data["actions"] = actions
elif mode == "strip":
    if existing is not None:
        for key in [k for k in existing if k.startswith("pt-cmux-")]:
            del existing[key]
        if existing:
            data["actions"] = existing
        else:
            data.pop("actions", None)
else:
    sys.stderr.write("unknown mode: %s\n" % mode)
    sys.exit(2)

changed = 1 if before != data.get("actions") else 0
if changed:
    with open(sys.argv[3], "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    # Carry the target's permissions over: cmux.json is commonly 0600, and a
    # freshly created file would otherwise land at 0644.
    try:
        os.chmod(sys.argv[3], stat.S_IMODE(os.stat(target).st_mode))
    except OSError:
        pass

sys.stdout.write("changed=%d\n" % changed)
sys.exit(0)
PY
}

# ---- cmux.json: prepare and validate it BEFORE anything is written --------
#
# Everything about cmux.json that can be checked is checked here, ahead of the
# hooks and the scripts: parse, shape, the merged result, and cmux's own
# validator. The merged file is then held aside as a tmp and swapped in at the
# very end, so a failure anywhere in this block leaves a system where nothing
# was touched at all.

cmux_bin=""
if [ -n "${PTCMUX_CMUX_BIN:-}" ]; then
  # Same authoritative semantics as the scripts: a broken override means
  # "cmux absent", never a PATH lookup.
  if [ -x "$PTCMUX_CMUX_BIN" ]; then
    cmux_bin="$PTCMUX_CMUX_BIN"
  fi
else
  cmux_bin="$(command -v cmux 2>/dev/null || true)"
  if [ -z "$cmux_bin" ] && [ -x /Applications/cmux.app/Contents/Resources/bin/cmux ]; then
    cmux_bin=/Applications/cmux.app/Contents/Resources/bin/cmux
  fi
fi

cmux_config_note=""
cmux_tmp=""
cmux_changed=""

cleanup_cmux_tmp() {
  if [ -n "$cmux_tmp" ]; then
    rm -f "$cmux_tmp"
  fi
}
trap cleanup_cmux_tmp EXIT

if [ -f "$CMUX_CONFIG" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to merge the cmux actions into" >&2
    echo "       $CMUX_CONFIG (install the Xcode command line tools, or" >&2
    echo "       edit that file by hand)" >&2
    exit 1
  fi
  if ! jsonc_write check "$CMUX_CONFIG" >/dev/null; then
    echo "error: $CMUX_CONFIG is not valid JSONC, or its \"actions\" is not an" >&2
    echo "       object; refusing to modify it (nothing was installed)" >&2
    exit 1
  fi

  # --close-when-done makes the tab cmux opens for the action close itself
  # once the command succeeds, so triggering it from the palette leaves no
  # tab behind (cmux would otherwise keep a terminal for every invocation).
  actions_json="$("$jq_bin" -n \
    --arg spread_cmd "'$PTCMUX_DIR/pt-cmux-spread' --close-when-done" \
    --arg gather_cmd "'$PTCMUX_DIR/pt-cmux-gather' --close-when-done" \
    '{
       "pt-cmux-spread": {
         "type": "command",
         "title": "Spread: split lg/croft right of polytoken",
         "command": $spread_cmd
       },
       "pt-cmux-gather": {
         "type": "command",
         "title": "Gather: merge workspace panes",
         "command": $gather_cmd
       }
     }')"

  cmux_tmp="$CMUX_CONFIG.tmp.$$"
  if ! cmux_changed="$(jsonc_write merge "$CMUX_CONFIG" "$cmux_tmp" "$actions_json")"; then
    echo "error: could not merge the actions into $CMUX_CONFIG; left untouched" >&2
    exit 1
  fi
  if [ "$cmux_changed" = "changed=0" ]; then
    # Already exactly as we would write it: nothing to swap in later.
    rm -f "$cmux_tmp"
    cmux_tmp=""
  else
    # The tmp comes straight out of json.dumps, so this reparse can only
    # catch I/O trouble; the load-bearing check is cmux's own validator.
    if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$cmux_tmp"; then
      echo "error: the merged config failed to reparse; $CMUX_CONFIG left untouched" >&2
      exit 1
    fi
    if [ -n "$cmux_bin" ]; then
      if ! "$cmux_bin" config check --path "$cmux_tmp" >/dev/null 2>&1; then
        echo "error: cmux rejected the merged config (cmux config check);" >&2
        echo "       $CMUX_CONFIG left untouched (nothing was installed)" >&2
        exit 1
      fi
    fi
  fi
else
  cmux_config_note="skipped"
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
for s in pt-cmux-status pt-cmux-watcher pt-cmux-spread pt-cmux-gather; do
  cp "$SCRIPT_DIR/bin/$s" "$PTCMUX_DIR/$s"
done
chmod +x "$PTCMUX_DIR/pt-cmux-status" "$PTCMUX_DIR/pt-cmux-watcher" \
         "$PTCMUX_DIR/pt-cmux-spread" "$PTCMUX_DIR/pt-cmux-gather"
echo "installed scripts to $PTCMUX_DIR/"

# ---- swap in the prepared cmux.json --------------------------------------
#
# Nothing has been written yet: the tmp was built and validated above, so this
# step can only fail on I/O. The backup is taken immediately before the swap,
# the same way the hooks.json merge backs up before it writes — a re-install
# that changes nothing leaves no extra .bak behind.

if [ "$cmux_config_note" = "skipped" ]; then
  echo "note: no $CMUX_CONFIG yet — cmux writes that template on first launch."
  echo "      Re-run ./install.sh afterwards to register the"
  echo "      pt-cmux-spread / pt-cmux-gather Command Palette entries."
elif [ -z "$cmux_tmp" ]; then
  echo "cmux actions already registered in $CMUX_CONFIG (unchanged)"
else
  ts="$(date +%Y%m%d%H%M%S)"
  backup="$CMUX_CONFIG.$ts.$$.bak"
  cp "$CMUX_CONFIG" "$backup"
  mv "$cmux_tmp" "$CMUX_CONFIG"
  cmux_tmp=""
  echo "registered pt-cmux-spread / pt-cmux-gather in $CMUX_CONFIG (backup: $backup)"
  echo "note: the merged file is written as plain JSON, so the template's hint"
  echo "      comments are gone; the backup above still has them."
fi

# Best effort: pick the actions up without an app restart.
if [ -n "$cmux_bin" ]; then
  if "$cmux_bin" reload-config >/dev/null 2>&1; then
    echo "reloaded cmux configuration"
  else
    echo "warning: could not reload cmux config; run 'cmux reload-config' so the" >&2
    echo "         new actions appear in the Command Palette" >&2
  fi
fi

echo "note: Polytoken loads global hooks at startup or after a config"
echo "reload — restart existing sessions (or reload config) for the hooks"
echo "to take effect."

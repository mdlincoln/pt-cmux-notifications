#!/usr/bin/env bash
# tests/run_tests.sh — unit tests for pt-cmux hooks.
#
# Everything runs against a fake cmux shim and temp dirs; the real cmux
# binary, the real Polytoken config, and the real HOME are never touched.
#
# Run: bash tests/run_tests.sh   (nonzero exit on any failure)
#
# Case numbering follows the plan:
#   1–9   script cases (pt-cmux-status handler contract + pill values)
#   10–13 install/uninstall cases
#   14–18 notification and watcher cases
#   19–21 idempotency, watcher tolerance, styled-pill fallback
#   S1–S12 pt-cmux-spread (arrangement, guards, convergence, dry run, debug,
#          --close-when-done)
#   G1–G4 pt-cmux-gather (collapse, single-pane no-op, leftover panes,
#          --close-when-done)
#   I1–I2b install: cmux.json action merge and its refusal paths
#   U1    uninstall: pt-cmux-* actions stripped, foreign actions kept

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STATUS="$ROOT/bin/pt-cmux-status"
WATCHER="$ROOT/bin/pt-cmux-watcher"
SPREAD="$ROOT/bin/pt-cmux-spread"
GATHER="$ROOT/bin/pt-cmux-gather"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
BASE_TMP="${TMPDIR:-/tmp}"

# Make sure no ambient variables leak in from the caller's environment.
unset PTCMUX_CMUX_BIN PTCMUX_LOG PTCMUX_NOTIFY PTCMUX_NO_WATCHER \
      PTCMUX_WATCHER_BIN PTCMUX_WATCH_INTERVAL PTCMUX_TEST_ANCESTOR_PIDS \
      PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE PTCMUX_TEST_SHIM_EXIT \
      PTCMUX_TEST_SHIM_FAIL_ICON PTCMUX_TEST_SHIM_FAIL_CONFIG_CHECK \
      PTCMUX_PS_BIN PTCMUX_TEST_PS_FIXTURE PTCMUX_OWN_TTY SHIM_STATE \
      CMUX_WORKSPACE_ID CMUX_SURFACE_ID TEST_CMUX_SURFACE_ID TEST_OWN_TTY \
      POLYTOKEN_SESSION_ID POLYTOKEN_GOAL_ACTIVE 2>/dev/null

if ! command -v jq >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/jq ]; then
  echo "jq is required by these tests (and by install.sh)" >&2
  exit 1
fi

# install.sh/uninstall.sh parse cmux.json (JSONC) with python3. Without it
# the I/U cases report a skip instead of failing the suite.
HAVE_PYTHON3=0
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON3=1

PASS=0
FAIL=0
ALL_TMP=""
TEST_TMP=""
TEST_LOG_DIR=""
CALLS=""
CALLS_ARGS=""
SHIM=""
RECORDED_CALLS=""

note() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

setup() {
  TEST_TMP="$(mktemp -d "$BASE_TMP/ptcmux-test.XXXXXX")"
  ALL_TMP="$ALL_TMP $TEST_TMP"
  TEST_LOG_DIR="$TEST_TMP/log"
  CALLS="$TEST_TMP/calls.log"
  CALLS_ARGS="$TEST_TMP/calls.args"
  SHIM="$TEST_TMP/cmux"
  SHIM_STATE="$TEST_TMP/cmux-state.json"
  FAKE_PS="$TEST_TMP/fake-ps"
  PS_FIXTURE="$TEST_TMP/ps-fixture.txt"
  mkdir -p "$TEST_TMP/tmp" "$TEST_TMP/home" "$TEST_TMP/xdg" "$TEST_LOG_DIR"
  : >"$CALLS"
  : >"$CALLS_ARGS"
  cat >"$SHIM" <<EOF
#!/usr/bin/env bash
# Fake cmux. Every call is logged to the \$CALLS side log. It is a pure
# recorder unless \$SHIM_STATE names a state file: with state it models
# panes (ordered surface lists) so the arrangement commands can be tested
# end to end. The empty-pane-dies rule modelled here matches the assumption
# the scripts document, and is verified against real cmux by the README's
# live checklist rather than by this harness.
printf '%s\n' "\$*" >> "$CALLS"
printf '%s\n' "\$#" >> "$CALLS_ARGS"
# PTCMUX_TEST_SHIM_FAIL_ICON=1: fail only styling-capable calls (any
# argv containing --icon), after logging — mimics an older cmux build
# that rejects the styling flags.
if [ "\${PTCMUX_TEST_SHIM_FAIL_ICON:-0}" = "1" ]; then
  for a in "\$@"; do
    if [ "\$a" = "--icon" ]; then
      exit 1
    fi
  done
fi
# PTCMUX_TEST_SHIM_FAIL_CONFIG_CHECK=1: reject 'config check', so the
# installer's validate-before-replace gate can be exercised.
if [ "\${PTCMUX_TEST_SHIM_FAIL_CONFIG_CHECK:-0}" = "1" ] && [ "\${1:-}" = "config" ]; then
  exit 1
fi

STATE="\${SHIM_STATE:-}"
if [ -z "\$STATE" ] || [ ! -f "\$STATE" ]; then
  exit \${PTCMUX_TEST_SHIM_EXIT:-0}
fi

apply() {
  # apply <jq args...>: rewrite the state in place with jq's output.
  if jq "\$@" "\$STATE" > "\$STATE.tmp"; then
    mv "\$STATE.tmp" "\$STATE"
  else
    rm -f "\$STATE.tmp"
    exit 1
  fi
}

prune_state() {
  # A pane whose last surface left is closed. That is the assumption both
  # scripts document, and it is what makes spread's re-run converge; a
  # fixture can set "keep_empty_panes": true to model a cmux that leaves the
  # emptied pane behind, which is what gather's leftover report is for.
  if [ "\$(jq -r '.keep_empty_panes // false' "\$STATE")" = "true" ]; then
    return 0
  fi
  apply '.panes = (.panes | map(select((.surfaces | length) > 0)))'
}

case "\${1:-}" in
  identify)
    jq -r '{socket_path: "/tmp/fake-cmux.sock",
            focused: {
              workspace_ref: .workspace_ref,
              pane_ref: ([.panes[] | select(.focused) | .ref][0] // .panes[0].ref),
              surface_ref: ([.panes[] | select(.focused) | .surfaces[0]][0] // ""),
              surface_type: "terminal",
              is_browser_surface: false
            }}' "\$STATE"
    exit 0 ;;
  tree)
    # tree_lag (fixture-only): after a mutating call, this many tree reads
    # are served the pre-mutation snapshot, modelling cmux's asynchronous
    # commit (measured live: a read right after split-off still sees the
    # old layout ~0.1-0.3 s in). The arrangement scripts must poll instead
    # of racing a single re-read.
    serve="\$STATE"
    if [ -f "\$STATE.lagcount" ]; then
      n="\$(cat "\$STATE.lagcount" 2>/dev/null || echo 0)"
      case "\$n" in ''|*[!0-9]*) n=0 ;; esac
      if [ "\$n" -gt 0 ]; then
        printf '%s\n' "\$((n - 1))" > "\$STATE.lagcount"
        serve="\$STATE.pre"
      else
        rm -f "\$STATE.lagcount" "\$STATE.pre"
      fi
    fi
    jq '. as \$root | {
          active: {
            workspace_ref: \$root.workspace_ref,
            pane_ref: ([\$root.panes[] | select(.focused) | .ref][0] // \$root.panes[0].ref),
            surface_ref: "",
            surface_type: "terminal",
            is_browser_surface: false
          },
          windows: [ {
            ref: "window:1",
            current: true,
            selected_workspace_ref: \$root.workspace_ref,
            workspaces: [ {
              ref: \$root.workspace_ref,
              id: (\$root.workspace_id // "FAKE-WORKSPACE-ID"),
              index: (\$root.workspace_index // 1),
              selected: true,
              title: "test workspace",
              panes: [ \$root.panes | to_entries[] | .key as \$i | .value as \$p | {
                ref: \$p.ref,
                focused: \$p.focused,
                index: \$i,
                surface_count: (\$p.surfaces | length),
                surface_refs: \$p.surfaces,
                selected_surface_ref: (\$p.surfaces[0] // null),
                surfaces: [ \$p.surfaces[] as \$s | (\$root.surfaces[\$s] // {}) + {
                  ref: \$s,
                  pane_ref: \$p.ref,
                  index_in_pane: (\$p.surfaces | index(\$s))
                } ]
              } ]
            } ]
          } ]
        }' "\$serve"
    exit 0 ;;
  split-off)
    shift
    surf=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --surface|--panel) surf="\$2"; shift 2 ;;
        --focus|--workspace|--window) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "\$surf" ] || exit 1
    if [ "\$(jq -r '.tree_lag // 0' "\$STATE")" -gt 0 ]; then
      cp "\$STATE" "\$STATE.pre"
      jq -r '.tree_lag' "\$STATE" > "\$STATE.lagcount"
    fi
    np_id="\$(jq -r '.next_pane' "\$STATE")"
    apply --arg s "\$surf" --arg np "pane:\$np_id" --argjson next "\$((np_id + 1))" '
      (.panes | to_entries | map(select(.value.surfaces | index(\$s))) | .[0].key) as \$si
      | .panes = (.panes | map(.surfaces |= map(select(. != \$s))))
      | .panes = (.panes[0:(\$si + 1)] + [ {ref: \$np, focused: false, surfaces: [\$s]} ] + .panes[(\$si + 1):])
      | .next_pane = \$next'
    prune_state
    exit 0 ;;
  move-surface)
    shift
    surf=""; pane=""; after=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --surface) surf="\$2"; shift 2 ;;
        --pane) pane="\$2"; shift 2 ;;
        --after|--after-surface) after="\$2"; shift 2 ;;
        --focus) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "\$surf" ] && [ -n "\$pane" ] || exit 1
    if [ "\$(jq -r '.tree_lag // 0' "\$STATE")" -gt 0 ]; then
      cp "\$STATE" "\$STATE.pre"
      jq -r '.tree_lag' "\$STATE" > "\$STATE.lagcount"
    fi
    apply --arg s "\$surf" --arg p "\$pane" --arg a "\$after" '
      .panes = (.panes | map(.surfaces |= map(select(. != \$s))))
      | .panes = (.panes | map(
          if .ref == \$p then
            (if (\$a != "" and ((.surfaces | index(\$a)) != null))
             then (.surfaces | index(\$a)) as \$i
                  | .surfaces = (.surfaces[0:(\$i + 1)] + [\$s] + .surfaces[(\$i + 1):])
             else .surfaces = (.surfaces + [\$s])
             end)
          else . end))'
    prune_state
    exit 0 ;;
  close-surface)
    shift
    surf=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --surface) surf="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "\$surf" ] || exit 1
    apply --arg s "\$surf" '
      .panes = (.panes | map(.surfaces |= map(select(. != \$s))))'
    prune_state
    exit 0 ;;
esac

exit \${PTCMUX_TEST_SHIM_EXIT:-0}
EOF
  chmod +x "$SHIM"
  # Fake ps for the arrangement commands' `ps -t <tty> -o pid=,comm=`
  # classification. An unknown tty exits 1, like the real ps.
  cat >"$FAKE_PS" <<'EOF'
#!/usr/bin/env bash
tty=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tty="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
fixture="${PTCMUX_TEST_PS_FIXTURE:-}"
[ -n "$tty" ] || exit 1
[ -n "$fixture" ] || exit 1
[ -f "$fixture" ] || exit 1
line="$(grep -m 1 "^${tty}:" "$fixture" 2>/dev/null)"
[ -n "$line" ] || exit 1
n=9000
for comm in $(printf '%s' "${line#*:}"); do
  n=$((n + 1))
  printf ' %s %s\n' "$n" "$comm"
done
exit 0
EOF
  chmod +x "$FAKE_PS"
}

remember_calls() {
  # Record the current case's call log for the negative lane assertion at
  # the end of the suite. Install/uninstall cases are NOT recorded: the
  # only lane command in the whole suite is uninstall's legacy scrub,
  # which is pinned to exactly one occurrence by case 13's own assertion.
  RECORDED_CALLS="$RECORDED_CALLS $CALLS"
}

run_status() (
  # run_status <lane> [VAR=VAL ...]
  # Runs the handler with the shim and standard test env; the caller
  # captures stdout and exit code.
  lane="$1"; shift
  export PTCMUX_CMUX_BIN="$SHIM" PTCMUX_LOG="$TEST_LOG_DIR/error.log"
  export TMPDIR="$TEST_TMP/tmp" POLYTOKEN_SESSION_ID=test-session
  for kv in "$@"; do
    export "$kv"
  done
  exec bash "$STATUS" "$lane"
)

run_watcher() (
  # run_watcher [VAR=VAL ...] [pid ...]
  # Arguments containing "=" are env vars; numeric arguments are PIDs.
  export PTCMUX_CMUX_BIN="$SHIM" PTCMUX_LOG="$TEST_LOG_DIR/error.log"
  export TMPDIR="$TEST_TMP/tmp"
  pids=""
  for arg in "$@"; do
    case "$arg" in
      *=*) export "$arg" ;;
      *) pids="$pids $arg" ;;
    esac
  done
  pids="${pids# }"
  exec bash "$WATCHER" $pids
)

count() {
  grep -c -- "$1" "$CALLS" 2>/dev/null || true
}

# Argument-count side log: how many argv words each shim call received.
# `set-status polytoken "Needs input" --icon bell.fill --color '#FF9500'`
# logs 7 (the multi-word pill is still ONE of them); a word-split
# `set-status polytoken Needs input ...` would log 8. The "$*" call log
# renders both identically, so the argv-integrity assertions below use
# this side log to pin the quoting of multi-word pill texts.
count_args() {
  grep -c -- "$1" "$CALLS_ARGS" 2>/dev/null || true
}

lines() {
  wc -l <"$CALLS" 2>/dev/null | tr -d ' ' || printf '0'
}

assert_handler_contract() {
  # assert_handler_contract <rc> <stdout> <desc>
  if [ "$1" -eq 0 ] && [ -z "$2" ]; then
    note "$3 (exit 0, silent)"
  else
    bail "$3 — expected exit 0 and empty stdout, got rc=$1 out='$2'"
  fi
}

cleanup() {
  for t in $ALL_TMP; do
    for flag in "$t"/tmp/pt-cmux-status/watcher-*; do
      [ -f "$flag" ] || continue
      wpid="$(cat "$flag" 2>/dev/null)"
      if [ -n "$wpid" ]; then
        kill "$wpid" 2>/dev/null
      fi
    done
  done
  for t in $ALL_TMP; do
    rm -rf "$t" 2>/dev/null
  done
}
trap cleanup EXIT

# ------------------------------------------------------- script cases -----

# 1. working on a fresh session -> one Running pill (styled).
setup
remember_calls
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 1: working on fresh session"
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 1 ]; then
  note "case 1: pill set to Running (bolt.fill / #4C8DFF) exactly once"
else
  bail "case 1: expected one styled Running set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Running$')" -eq 0 ]; then
  note "case 1: no plain fallback fired on the happy path"
else
  bail "case 1: unexpected plain Running retry, log: $(cat "$CALLS")"
fi

# 2. working again -> set again (re-set on every invocation).
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 2: Working set again"
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 2 ]; then
  note "case 2: repeat invocation re-sets Running (no dedup)"
else
  bail "case 2: expected two styled Running sets, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Running$')" -eq 0 ]; then
  note "case 2: still no plain fallback"
else
  bail "case 2: unexpected plain Running retry, log: $(cat "$CALLS")"
fi

# 3. needs-attention after working.
args3_before="$(count_args '^7$')"
out="$(run_status needs-attention 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 3: needs-attention"
if [ "$(count '^set-status polytoken Needs input --icon bell.fill --color #FF9500$')" -eq 1 ]; then
  note "case 3: pill set to Needs input (bell.fill / #FF9500)"
else
  bail "case 3: expected a styled Needs input set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Needs input$')" -eq 0 ]; then
  note "case 3: no plain Needs input fallback"
else
  bail "case 3: unexpected plain Needs input retry, log: $(cat "$CALLS")"
fi
args3_after="$(count_args '^7$')"
if [ "$((args3_after - args3_before))" -eq 1 ]; then
  note "case 3: set-status received exactly 7 argv (quoted multi-word pill)"
else
  bail "case 3: expected one 7-argv set-status call, got $((args3_after - args3_before)) (word-split?)"
fi

# 4. reset -> clear-status; a following working still fires a new set.
out="$(run_status reset 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 4: reset"
if [ "$(count '^clear-status polytoken$')" -eq 1 ]; then
  note "case 4: reset clears the pill"
else
  bail "case 4: expected one clear-status, log: $(cat "$CALLS")"
fi
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 4b: working after reset"
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 3 ]; then
  note "case 4b: working after reset fires a new styled Running set"
else
  bail "case 4b: expected a fresh styled Running set, log: $(cat "$CALLS")"
fi

# 5. done with an active goal -> no cmux call at all.
before="$(lines)"
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=true 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 5: done while goal active"
after="$(lines)"
if [ "$before" -eq "$after" ]; then
  note "case 5: goal-active stop does not touch the pill"
else
  bail "case 5: expected no shim calls, log: $(cat "$CALLS")"
fi

# 6. done with no goal -> Idle pill + notification.
args3_before="$(count_args '^7$')"
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=false 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 6: done with no goal"
if [ "$(count '^set-status polytoken Idle --icon pause.circle.fill --color #8E8E93$')" -eq 1 ]; then
  note "case 6: pill set to Idle (pause.circle.fill / #8E8E93)"
else
  bail "case 6: expected a styled Idle set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Idle$')" -eq 0 ]; then
  note "case 6: no plain Idle fallback"
else
  bail "case 6: unexpected plain Idle retry, log: $(cat "$CALLS")"
fi
args3_after="$(count_args '^7$')"
if [ "$((args3_after - args3_before))" -eq 1 ]; then
  note "case 6: set-status received exactly 7 argv"
else
  bail "case 6: expected one 7-argv set-status call, got $((args3_after - args3_before)) (word-split?)"
fi
if [ "$(count '^notify --title Polytoken --body Loop finished')" -eq 1 ]; then
  note "case 6: done posts its notification"
else
  bail "case 6: expected a done notification, log: $(cat "$CALLS")"
fi

# 6b. escape hatch: done while goal active with PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE=1.
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=true PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 6b: SET_DONE_WHEN_GOAL_ACTIVE escape hatch"
if [ "$(count '^set-status polytoken Idle --icon pause.circle.fill --color #8E8E93$')" -eq 2 ]; then
  note "case 6b: styled Idle set despite the active goal"
else
  bail "case 6b: expected a styled Idle set, log: $(cat "$CALLS")"
fi

# 7. cmux missing entirely (override dead, no cmux on PATH) -> exit 0, silent.
setup
remember_calls
out="$(run_status working PATH=/usr/bin:/bin PTCMUX_CMUX_BIN="$TEST_TMP/no-such-cmux" 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 7: cmux missing"
if [ "$(lines)" -eq 0 ]; then
  note "case 7: no cmux call attempted"
else
  bail "case 7: expected an empty call log, log: $(cat "$CALLS")"
fi

# 8. cmux errors (shim exits 1) -> handler still exits 0, silent.
setup
remember_calls
out="$(run_status working PTCMUX_TEST_SHIM_EXIT=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 8: cmux exits nonzero"
if [ -s "$TEST_LOG_DIR/error.log" ]; then
  note "case 8: failure logged to error.log"
else
  bail "case 8: expected the failure to be logged"
fi
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 1 ] \
   && [ "$(count '^set-status polytoken Running$')" -eq 1 ] \
   && [ "$(count '^notify --clear$')" -eq 1 ]; then
  note "case 8: exactly one styled attempt, one plain retry, one notify — all failed, none repeated"
else
  bail "case 8: unexpected call counts, log: $(cat "$CALLS")"
fi

# 9. arbitrary JSON on stdin is ignored.
setup
remember_calls
out="$(printf '{"session_id":"s","tool_input":{"q":"hi"}}' | run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 9: stdin JSON ignored"
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 1 ]; then
  note "case 9: styled Running set despite (unrelated) stdin payload"
else
  bail "case 9: expected a styled Running set, log: $(cat "$CALLS")"
fi

# ----------------------------------------------------- install cases -----

run_install() {
  # PTCMUX_CMUX_BIN points at the shim so the real cmux (and its config
  # check / reload-config) is never touched by the suite, and so the
  # installer's validate-before-replace gate can be exercised.
  ( export XDG_CONFIG_HOME="$TEST_TMP/xdg" HOME="$TEST_TMP/home" \
           PTCMUX_CMUX_BIN="$SHIM"
    for kv in "$@"; do
      export "$kv"
    done
    bash "$INSTALL" )
}
run_uninstall() {
  # PTCMUX_CMUX_BIN keeps uninstall.sh away from any real cmux install.
  ( export XDG_CONFIG_HOME="$TEST_TMP/xdg" HOME="$TEST_TMP/home" PTCMUX_CMUX_BIN="$SHIM"
    bash "$UNINSTALL" )
}
seed_third_party() {
  mkdir -p "$TEST_TMP/xdg/polytoken"
  cat >"$TEST_TMP/xdg/polytoken/hooks.json" <<'EOF'
[
  {
    "name": "third-party-hook",
    "event": "post_tool_use",
    "handler": { "bash": "echo hi" }
  }
]
EOF
}

# 10. fresh install -> exactly 6 cmux-* entries, valid JSON, script copied.
setup
if run_install >/dev/null 2>&1; then
  hooks_json="$TEST_TMP/xdg/polytoken/hooks.json"
  if [ -f "$hooks_json" ] \
     && [ "$(jq '[.[] | select((.name // "") | startswith("cmux-"))] | length' "$hooks_json")" -eq 6 ] \
     && [ "$(jq 'length' "$hooks_json")" -eq 6 ] \
     && jq -e 'all(.[]; (.handler.bash | contains("pt-cmux/pt-cmux-status")))' "$hooks_json" >/dev/null; then
    note "case 10: fresh install writes 6 cmux-* entries with correct paths"
  else
    bail "case 10: unexpected hooks.json: $(cat "$hooks_json" 2>/dev/null)"
  fi
  if [ -x "$TEST_TMP/xdg/polytoken/pt-cmux/pt-cmux-status" ] \
     && [ -x "$TEST_TMP/xdg/polytoken/pt-cmux/pt-cmux-watcher" ]; then
    note "case 10: scripts installed and executable"
  else
    bail "case 10: scripts missing under pt-cmux/"
  fi
else
  bail "case 10: install.sh failed"
fi

# 11. merge into pre-existing third-party hooks.json.
setup
seed_third_party
if run_install >/dev/null 2>&1; then
  hooks_json="$TEST_TMP/xdg/polytoken/hooks.json"
  if [ "$(jq '[.[] | select((.name // "") | startswith("cmux-"))] | length' "$hooks_json")" -eq 6 ] \
     && [ "$(jq 'length' "$hooks_json")" -eq 7 ] \
     && jq -e 'any(.[]; .name == "third-party-hook")' "$hooks_json" >/dev/null; then
    note "case 11: install merges, preserving third-party hooks (6 cmux-* + 1)"
  else
    bail "case 11: unexpected merge result: $(cat "$hooks_json")"
  fi
else
  bail "case 11: install.sh failed on merge"
fi

# 12. existing hooks.json is backed up before modification.
setup
seed_third_party
run_install >/dev/null 2>&1
backup=""
for f in "$TEST_TMP/xdg/polytoken/"hooks.json.*.bak; do
  [ -f "$f" ] || continue
  backup="$f"
  break
done
if [ -n "$backup" ] && jq -e 'length == 1 and .[0].name == "third-party-hook"' "$backup" >/dev/null 2>&1; then
  note "case 12: pre-existing hooks.json backed up unmodified"
else
  bail "case 12: no backup found or backup content wrong (found: ${backup:-none})"
fi

# 13. uninstall removes cmux-* entries, keeps third-party, deletes pt-cmux/,
#     and cleans up both status surfaces via the shim.
setup
seed_third_party
run_install >/dev/null 2>&1
if run_uninstall >/dev/null 2>&1; then
  hooks_json="$TEST_TMP/xdg/polytoken/hooks.json"
  if [ "$(jq 'length' "$hooks_json")" -eq 1 ] \
     && jq -e '.[0].name == "third-party-hook"' "$hooks_json" >/dev/null \
     && [ ! -e "$TEST_TMP/xdg/polytoken/pt-cmux" ]; then
    note "case 13: uninstall strips cmux-*, keeps third-party, removes pt-cmux/"
  else
    bail "case 13: unexpected uninstall state ($(cat "$hooks_json" 2>/dev/null))"
  fi
  if [ "$(count '^clear-status polytoken$')" -eq 1 ] \
     && [ "$(count '^workspace status set auto$')" -eq 1 ]; then
    note "case 13: uninstall cleared the pill and scrubbed the legacy lane exactly once each"
  else
    bail "case 13: expected one clear-status polytoken and one legacy lane scrub, log: $(cat "$CALLS")"
  fi
else
  bail "case 13: uninstall.sh failed"
fi

# 13b. uninstall after fresh install deletes hooks.json entirely.
setup
run_install >/dev/null 2>&1
run_uninstall >/dev/null 2>&1
if [ ! -e "$TEST_TMP/xdg/polytoken/hooks.json" ] && [ ! -e "$TEST_TMP/xdg/polytoken/pt-cmux" ]; then
  note "case 13b: empty hooks.json removed on uninstall"
else
  bail "case 13b: expected hooks.json and pt-cmux/ gone"
fi

# 13c. uninstall leaves an invalid hooks.json untouched (warning path).
setup
mkdir -p "$TEST_TMP/xdg/polytoken"
printf '%s\n' '{"invalid":true}' >"$TEST_TMP/xdg/polytoken/hooks.json"
seed_content="$(cat "$TEST_TMP/xdg/polytoken/hooks.json")"
if run_uninstall >/dev/null 2>&1; then
  hooks_json="$TEST_TMP/xdg/polytoken/hooks.json"
  if [ -f "$hooks_json" ] && [ "$(cat "$hooks_json")" = "$seed_content" ]; then
    note "case 13c: invalid hooks.json left untouched (warning path)"
  else
    bail "case 13c: hooks.json was modified or removed"
  fi
else
  bail "case 13c: uninstall.sh failed"
fi

# ---------------------------------------------- notification/watcher -----

# 14. waiting lanes post notifications; working/reset clear them; each
#     styled set-status call carries exactly 7 argv (quoted multi-word
#     pills) and never falls back to a plain call on the happy path.
setup
remember_calls
args3_before="$(count_args '^7$')"
run_status needs-attention >/dev/null 2>&1
run_status review >/dev/null 2>&1
run_status done POLYTOKEN_GOAL_ACTIVE=false >/dev/null 2>&1
run_status working >/dev/null 2>&1
run_status reset >/dev/null 2>&1
if [ "$(count '^notify --title Polytoken --body A user question is waiting for your answer$')" -eq 1 ] \
   && [ "$(count '^notify --title Polytoken --body A plan is ready for your review$')" -eq 1 ] \
   && [ "$(count '^notify --title Polytoken --body Loop finished')" -eq 1 ] \
   && [ "$(count '^notify --clear$')" -eq 2 ]; then
  note "case 14: waiting lanes notify, working/reset clear notifications"
else
  bail "case 14: unexpected notify log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Needs input --icon bell.fill --color #FF9500$')" -eq 1 ]; then
  note "case 14: needs-attention set its styled Needs input pill"
else
  bail "case 14: expected one styled Needs input set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken In review --icon eye.fill --color #34C759$')" -eq 1 ]; then
  note "case 14: review set its styled In review pill"
else
  bail "case 14: expected one styled In review set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Idle --icon pause.circle.fill --color #8E8E93$')" -eq 1 ] \
   && [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 1 ]; then
  note "case 14: done and working set their styled pills"
else
  bail "case 14: expected one styled Idle and one styled Running set, log: $(cat "$CALLS")"
fi
if [ "$(count '^set-status polytoken Needs input$')" -eq 0 ] \
   && [ "$(count '^set-status polytoken In review$')" -eq 0 ] \
   && [ "$(count '^set-status polytoken Idle$')" -eq 0 ] \
   && [ "$(count '^set-status polytoken Running$')" -eq 0 ]; then
  note "case 14: no plain fallback on any happy-path lane"
else
  bail "case 14: unexpected plain set-status retry, log: $(cat "$CALLS")"
fi
args3_after="$(count_args '^7$')"
if [ "$((args3_after - args3_before))" -eq 4 ]; then
  note "case 14: all four set-status calls carried exactly 7 argv"
else
  bail "case 14: expected four 7-argv set-status calls, got $((args3_after - args3_before)) (word-split?)"
fi

# 15. PTCMUX_NOTIFY=0 -> no notify calls at all.
setup
remember_calls
run_status needs-attention PTCMUX_NOTIFY=0 >/dev/null 2>&1
run_status working PTCMUX_NOTIFY=0 >/dev/null 2>&1
run_status reset PTCMUX_NOTIFY=0 >/dev/null 2>&1
if [ "$(count '^notify')" -eq 0 ]; then
  note "case 15: PTCMUX_NOTIFY=0 disables all notify calls"
else
  bail "case 15: expected no notify calls, log: $(cat "$CALLS")"
fi

# 16. watcher spawns on reset and clears the pill when the watched PID dies.
setup
remember_calls
sleep 60 & spid=$!
out="$(run_status reset PTCMUX_TEST_ANCESTOR_PIDS="$spid" PTCMUX_WATCH_INTERVAL=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 16: reset with test ancestor"
flag="$TEST_TMP/tmp/pt-cmux-status/watcher-test-session"
i=0
while [ "$i" -lt 50 ] && [ ! -f "$flag" ]; do
  i=$((i + 1)); sleep 0.1
done
if [ -f "$flag" ]; then
  note "case 16: watcher flag file created"
else
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  bail "case 16: watcher flag file never appeared"
fi
wpid="$(cat "$flag")"
if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
  note "case 16: flag contains a live watcher PID ($wpid)"
else
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  bail "case 16: watcher PID in flag is not live"
fi
clear_before="$(count '^clear-status polytoken$')"
if [ "$clear_before" -eq 1 ]; then
  : # reset already cleared the pill once — expected
else
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  bail "case 16: reset should already have cleared the pill exactly once (got $clear_before)"
fi
kill "$spid" 2>/dev/null
wait "$spid" 2>/dev/null
i=0
clear_after="$clear_before"
while [ "$i" -lt 100 ] && [ "$clear_after" -lt $((clear_before + 1)) ]; do
  i=$((i + 1)); sleep 0.1
  clear_after="$(count '^clear-status polytoken$')"
done
if [ "$clear_after" -eq $((clear_before + 1)) ]; then
  note "case 16: watcher cleared the pill exactly once after watched PID exited"
else
  bail "case 16: expected clear count $((clear_before + 1)), got $clear_after; log: $(cat "$CALLS")"
fi

# 17. PTCMUX_NO_WATCHER=1 -> no watcher, no flag file.
setup
remember_calls
out="$(run_status reset PTCMUX_NO_WATCHER=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 17: reset with watcher disabled"
flag="$TEST_TMP/tmp/pt-cmux-status/watcher-test-session"
if [ ! -e "$flag" ] && [ "$(count '^clear-status polytoken$')" -eq 1 ]; then
  note "case 17: no watcher spawned, pill still cleared"
else
  bail "case 17: watcher was spawned or reset misbehaved (flag: $flag)"
fi

# 18. watcher with no PIDs exits silently; all-dead-at-startup clears once.
setup
remember_calls
before="$(lines)"
out="$(run_watcher 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 18a: watcher with no arguments"
if [ "$(lines)" -eq "$before" ]; then
  note "case 18a: no cmux call without PID arguments"
else
  bail "case 18a: expected no shim calls, log: $(cat "$CALLS")"
fi
sleep 0.3 & dead=$!
wait "$dead" 2>/dev/null   # reap it so the PID is truly gone
if kill -0 "$dead" 2>/dev/null; then
  # PID was instantly recycled — watching it would never terminate.
  note "case 18b: skipped (PID $dead was reused before the check)"
else
  out="$(run_watcher "$dead" 2>/dev/null)"; rc=$?
  assert_handler_contract "$rc" "$out" "case 18b: watcher with already-reaped PID"
  if [ "$(count '^clear-status polytoken$')" -eq 1 ] \
    && [ "$(count '^notify --clear$')" -eq 1 ]; then
    note "case 18b: all-dead-at-startup clears pill and notification exactly once each"
  else
    bail "case 18b: expected one clear-status and one notify --clear, log: $(cat "$CALLS")"
  fi
fi

# 18c. PTCMUX_NOTIFY=0 -> the watcher clears the pill but never touches
#      notifications (this session never posted one, and notify --clear
#      would wipe third-party notifications too).
setup
remember_calls
sleep 0.3 & dead=$!
wait "$dead" 2>/dev/null
if ! kill -0 "$dead" 2>/dev/null; then
  out="$(run_watcher PTCMUX_NOTIFY=0 "$dead" 2>/dev/null)"; rc=$?
  assert_handler_contract "$rc" "$out" "case 18c: watcher with notifications disabled"
  if [ "$(count '^clear-status polytoken$')" -eq 1 ] && [ "$(count '^notify')" -eq 0 ]; then
    note "case 18c: pill cleared, no notify --clear under PTCMUX_NOTIFY=0"
  else
    bail "case 18c: expected one clear-status and no notify calls, log: $(cat "$CALLS")"
  fi
else
  note "case 18c: skipped (PID $dead was reused before the check)"
fi

# 20. watcher tolerates a missing cmux binary (exit 0, silent, no calls).
setup
remember_calls
sleep 0.3 & dead=$!
wait "$dead" 2>/dev/null
if ! kill -0 "$dead" 2>/dev/null; then
  out="$(run_watcher PTCMUX_CMUX_BIN="$TEST_TMP/no-such-cmux" PATH=/usr/bin:/bin "$dead" 2>/dev/null)"; rc=$?
  assert_handler_contract "$rc" "$out" "case 20: watcher with cmux missing"
  if [ "$(lines)" -eq 0 ]; then
    note "case 20: no cmux call attempted"
  else
    bail "case 20: expected an empty call log, log: $(cat "$CALLS")"
  fi
else
  note "case 20: skipped (PID $dead was reused before the check)"
fi

# 20b. watcher tolerates a failing cmux (exit 0, silent).
setup
remember_calls
sleep 0.3 & dead=$!
wait "$dead" 2>/dev/null
if ! kill -0 "$dead" 2>/dev/null; then
  out="$(run_watcher PTCMUX_TEST_SHIM_EXIT=1 "$dead" 2>/dev/null)"; rc=$?
  assert_handler_contract "$rc" "$out" "case 20b: watcher with failing cmux"
  if [ -s "$TEST_LOG_DIR/error.log" ]; then
    note "case 20b: failure logged to error.log"
  else
    bail "case 20b: expected the failure to be logged"
  fi
else
  note "case 20b: skipped (PID $dead was reused before the check)"
fi

# 19. installing twice never duplicates cmux-* entries.
setup
seed_third_party
run_install >/dev/null 2>&1
run_install >/dev/null 2>&1
hooks_json="$TEST_TMP/xdg/polytoken/hooks.json"
if [ "$(jq '[.[] | select((.name // "") | startswith("cmux-"))] | length' "$hooks_json")" -eq 6 ] \
   && [ "$(jq 'length' "$hooks_json")" -eq 7 ] \
   && jq -e 'any(.[]; .name == "third-party-hook")' "$hooks_json" >/dev/null; then
  note "case 19: install twice is idempotent (6 cmux-* + third-party preserved)"
else
  bail "case 19: unexpected double-install result: $(cat "$hooks_json")"
fi

# 21. styled set-status rejected (shim fails any --icon call) -> exactly
#     one failed styled attempt and one plain retry; handler stays silent
#     and exits 0.
setup
remember_calls
out="$(run_status working PTCMUX_TEST_SHIM_FAIL_ICON=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 21: styled set-status rejected"
if [ "$(count '^set-status polytoken Running --icon bolt.fill --color #4C8DFF$')" -eq 1 ] \
   && [ "$(count '^set-status polytoken Running$')" -eq 1 ]; then
  note "case 21: one styled attempt, one plain fallback retry, pill still set"
else
  bail "case 21: expected one styled attempt plus one plain retry, log: $(cat "$CALLS")"
fi
if [ -s "$TEST_LOG_DIR/error.log" ]; then
  note "case 21: fallback failure logged to error.log"
else
  bail "case 21: expected the styled failure to be logged"
fi

# ------------------------------------------ arrangement commands ---------
#
# The arrangement commands talk to cmux through the stateful shim and to ps
# through the fake ps, so every assertion below is about the scripts' own
# logic: classification, ordering, guards, and the calls they make. Real
# cmux mutation semantics (split-off geometry, empty-pane death, palette
# execution) are not reachable from this harness and are covered by the
# README's live checklist.

run_cmd() (
  # run_cmd <script> [args...]: run an arrangement command against the
  # stateful fake cmux, the fake ps, and this case's fixtures. TEST_* vars
  # (deliberately using ${VAR-default} so an explicit empty value stays
  # empty) let a case set CMUX_SURFACE_ID / the caller's tty, which is what
  # --close-when-done keys off.
  script="$1"; shift
  export PTCMUX_CMUX_BIN="$SHIM" PTCMUX_PS_BIN="$FAKE_PS" \
         PTCMUX_TEST_PS_FIXTURE="$PS_FIXTURE" SHIM_STATE="$SHIM_STATE" \
         CMUX_WORKSPACE_ID=workspace:11 TMPDIR="$TEST_TMP/tmp" \
         CMUX_SURFACE_ID="${TEST_CMUX_SURFACE_ID-pt-cmux-test-own}" \
         PTCMUX_OWN_TTY="${TEST_OWN_TTY-}"
  exec bash "$script" "$@"
)

run_cmd_no_ws() (
  # As run_cmd, but with no workspace in the environment, so the script has
  # to fall back to `cmux identify`.
  script="$1"; shift
  export PTCMUX_CMUX_BIN="$SHIM" PTCMUX_PS_BIN="$FAKE_PS" \
         PTCMUX_TEST_PS_FIXTURE="$PS_FIXTURE" SHIM_STATE="$SHIM_STATE" \
         TMPDIR="$TEST_TMP/tmp"
  exec bash "$script" "$@"
)

run_cmd_broken_cmux() (
  # The override is authoritative and names a missing binary, and PATH has no
  # cmux either: the command must refuse without calling anything.
  script="$1"; shift
  export PTCMUX_CMUX_BIN="$TEST_TMP/no-such-cmux" PTCMUX_PS_BIN="$FAKE_PS" \
         PTCMUX_TEST_PS_FIXTURE="$PS_FIXTURE" SHIM_STATE="$SHIM_STATE" \
         CMUX_WORKSPACE_ID=workspace:11 PATH=/usr/bin:/bin TMPDIR="$TEST_TMP/tmp"
  exec bash "$script" "$@"
)

seed_state() { cat >"$SHIM_STATE"; }
seed_ps()    { cat >"$PS_FIXTURE"; }

pane_count()  { jq '.panes | length' "$SHIM_STATE"; }
pane_order()  { jq -r '[.panes[].ref] | join(" ")' "$SHIM_STATE"; }
layout()      { jq -r '.panes[] | "\(.ref):\(.surfaces | join(","))"' "$SHIM_STATE" | tr '\n' ' '; }
surfaces_of() { jq -r --arg p "$1" '([.panes[] | select(.ref == $p) | .surfaces][0] // []) | join(" ")' "$SHIM_STATE"; }
pane_of()     { jq -r --arg s "$1" '([.panes[] | select(.surfaces | index($s)) | .ref][0] // "")' "$SHIM_STATE"; }

mutating_verbs() {
  # The state-changing cmux verbs, in call order. Reads (tree/identify) are
  # deliberately excluded; use unread_calls for "stayed read-only" checks.
  grep -E '^(split-off|move-surface|close-surface)' "$CALLS" 2>/dev/null || true
}
mutating_count() { mutating_verbs | grep -c . || true; }
unread_calls()   { grep -v -E '^(tree|identify)' "$CALLS" 2>/dev/null || true; }

# S1: one pane holding polytoken + lazygit + croft -> keep pane keeps the
#     polytoken tab, one new split to its right holds lazygit then croft.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43", "surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
ttys014: croft -/bin/zsh
EOF
out="$(run_cmd_no_ws "$SPREAD" 2>"$TEST_TMP/s1.err")"; rc=$?
if [ "$rc" -eq 0 ]; then
  note "S1: spread exits 0"
else
  bail "S1: expected exit 0, got $rc (stderr: $(cat "$TEST_TMP/s1.err"))"
fi
if [ "$(surfaces_of pane:13)" = "surface:42" ]; then
  note "S1: keep pane retains the polytoken tab and nothing else"
else
  bail "S1: keep pane is $(surfaces_of pane:13), expected surface:42"
fi
if [ "$(pane_count)" -eq 2 ] && [ "$(surfaces_of "$(pane_of surface:43)")" = "surface:43 surface:44" ]; then
  note "S1: one new pane holds lazygit then croft in that order"
else
  bail "S1: unexpected panes: $(layout)"
fi
if [ "$(pane_order)" = "pane:13 pane:20" ]; then
  # The shim inserts a split-off pane after the source pane, so this pins the
  # script's ordering (one new pane, to the right of the keep pane) rather
  # than real split geometry — that part is the live checklist's job.
  note "S1: the new split sits immediately to the right of the keep pane"
else
  bail "S1: pane order is $(pane_order), expected the new pane right of pane:13"
fi
expected_seq="split-off --surface surface:43 right --focus false
move-surface --surface surface:44 --pane pane:20 --focus false"
if [ "$(mutating_verbs)" = "$expected_seq" ]; then
  note "S1: called split-off(lazygit, right) then move(croft) — and nothing else"
else
  bail "S1: unexpected mutating calls: $(mutating_verbs | tr '\n' '|')"
fi
if grep -q 'surface:42' "$CALLS"; then
  bail "S1: the polytoken surface was addressed by a cmux call: $(cat "$CALLS")"
else
  note "S1: the polytoken surface never appears in a cmux call"
fi
if [ "$(count '^identify --json$')" -eq 1 ]; then
  note "S1: workspace resolved through cmux identify when the env var is absent"
else
  bail "S1: expected one identify call, log: $(cat "$CALLS")"
fi

# S2: only croft is running -> exactly that one moves, and a non-terminal
#     surface (a browser tab) is never classified, let alone moved.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43", "surface:44", "surface:45"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "idle shell" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" },
    "surface:45": { "type": "browser", "url": "https://example.com", "title": "docs" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
ttys014: croft -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s2.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(surfaces_of pane:13)" = "surface:42 surface:43 surface:45" ] \
   && [ "$(surfaces_of "$(pane_of surface:44)")" = "surface:44" ]; then
  note "S2: only the croft tab moves; the idle shell and the browser tab stay put"
else
  bail "S2: unexpected state (rc=$rc): $(layout)"
fi
if [ "$(mutating_verbs)" = "split-off --surface surface:44 right --focus false" ]; then
  note "S2: one split-off, no follow-up moves"
else
  bail "S2: unexpected mutating calls: $(mutating_verbs | tr '\n' '|')"
fi

# S3: no polytoken tab -> refuse, exit nonzero, change nothing.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:43", "surface:44"] } ],
  "surfaces": {
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" }
  }
}
EOF
seed_ps <<'EOF'
ttys013: lazygit -/bin/zsh
ttys014: croft -/bin/zsh
EOF
before_layout="$(layout)"
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s3.err")"; rc=$?
if [ "$rc" -ne 0 ]; then
  note "S3: spread refuses with a nonzero exit when no polytoken tab is present"
else
  bail "S3: expected a nonzero exit, got 0"
fi
if grep -q "no polytoken session" "$TEST_TMP/s3.err"; then
  note "S3: the refusal names the reason on stderr"
else
  bail "S3: stderr did not explain the refusal: $(cat "$TEST_TMP/s3.err")"
fi
if [ "$(mutating_count)" -eq 0 ] && [ "$(layout)" = "$before_layout" ]; then
  note "S3: no mutating call, no state change"
else
  bail "S3: mutating calls or state change on the guard path ($(mutating_verbs | tr '\n' '|'))"
fi

# S4: nothing running lazygit/croft -> clean no-op.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "idle shell" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
EOF
before_layout="$(layout)"
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s4.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "nothing to spread"; then
  note "S4: spread reports nothing to spread and exits 0"
else
  bail "S4: expected exit 0 with a 'nothing to spread' message (rc=$rc, out=$out)"
fi
if [ "$(mutating_count)" -eq 0 ] && [ "$(layout)" = "$before_layout" ]; then
  note "S4: no mutating call, no state change"
else
  bail "S4: mutating calls or state change on the no-op path ($(mutating_verbs | tr '\n' '|'))"
fi

# S5: re-run on an already-spread workspace converges instead of stacking
#     up a second split.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43", "surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
ttys014: croft -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s5.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pane_count)" -eq 2 ]; then
  note "S5: re-run converges to two panes (the previous split is reused, not added to)"
else
  bail "S5: expected exit 0 and 2 panes, got rc=$rc panes=$(pane_count) ($(layout))"
fi
if [ "$(surfaces_of pane:13)" = "surface:42" ] \
   && [ "$(surfaces_of "$(pane_of surface:43)")" = "surface:43 surface:44" ]; then
  note "S5: canonical layout restored (polytoken left, lazygit+croft right)"
else
  bail "S5: unexpected layout after re-run: $(layout)"
fi
if [ "$(mutating_verbs | grep -c '^split-off')" -eq 1 ]; then
  note "S5: exactly one split-off on the re-run"
else
  bail "S5: expected one split-off, got: $(mutating_verbs | tr '\n' '|')"
fi

# S6: cmux absent (dead override, not on PATH) -> refuse, no calls at all.
setup
remember_calls
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
EOF
out="$(run_cmd_broken_cmux "$SPREAD" 2>"$TEST_TMP/s6a.err")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "cmux binary not found" "$TEST_TMP/s6a.err"; then
  note "S6: spread refuses when cmux is absent, with the reason on stderr"
else
  bail "S6: expected a refusal for spread (rc=$rc): $(cat "$TEST_TMP/s6a.err")"
fi
out="$(run_cmd_broken_cmux "$GATHER" 2>"$TEST_TMP/s6b.err")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "cmux binary not found" "$TEST_TMP/s6b.err"; then
  note "S6: gather refuses when cmux is absent, with the reason on stderr"
else
  bail "S6: expected a refusal for gather (rc=$rc): $(cat "$TEST_TMP/s6b.err")"
fi
if [ "$(lines)" -eq 0 ]; then
  note "S6: neither command attempted a cmux call"
else
  bail "S6: expected an empty call log, log: $(cat "$CALLS")"
fi

# S7: dry run prints the plan and stays read-only (no mutating call, no state
#     change) for both commands.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43", "surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
ttys014: croft -/bin/zsh
EOF
before_layout="$(layout)"
out="$(run_cmd "$SPREAD" --dry-run 2>"$TEST_TMP/s7a.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^cmux split-off --surface surface:43 right --focus false$' \
   && printf '%s' "$out" | grep -q '^cmux move-surface --surface surface:44 --pane'; then
  note "S7: spread dry run prints the planned split and follow-up move"
else
  bail "S7: unexpected spread dry-run output (rc=$rc): $out"
fi
if [ "$(unread_calls)" = "" ] && [ "$(layout)" = "$before_layout" ]; then
  note "S7: spread dry run made no non-read call and changed nothing"
else
  bail "S7: dry run wrote to cmux ($(unread_calls | tr '\n' '|')) or changed state"
fi
: >"$CALLS"
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "three" }
  }
}
EOF
before_layout="$(layout)"
out="$(run_cmd "$GATHER" --dry-run 2>"$TEST_TMP/s7b.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^cmux move-surface --surface surface:44 --pane pane:13 --after surface:43 --focus false$'; then
  note "S7: gather dry run prints the ordered move"
else
  bail "S7: unexpected gather dry-run output (rc=$rc): $out"
fi
if [ "$(unread_calls)" = "" ] && [ "$(layout)" = "$before_layout" ]; then
  note "S7: gather dry run made no non-read call and changed nothing"
else
  bail "S7: gather dry run wrote to cmux ($(unread_calls | tr '\n' '|')) or changed state"
fi

# S8: a tty running both polytoken and lazygit -> keep wins; the tab is never
#     moved.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken + lazygit" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "croft" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken lazygit -/bin/zsh
ttys014: croft -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s8.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(surfaces_of pane:13)" = "surface:42" ] \
   && [ "$(surfaces_of "$(pane_of surface:44)")" = "surface:44" ]; then
  note "S8: a tab running polytoken+lazygit stays in the keep pane"
else
  bail "S8: unexpected state (rc=$rc): $(layout)"
fi
if [ "$(mutating_verbs)" = "split-off --surface surface:44 right --focus false" ]; then
  note "S8: only the croft tab moved"
else
  bail "S8: unexpected mutating calls: $(mutating_verbs | tr '\n' '|')"
fi

# S9: --workspace accepts the three forms cmux itself accepts (ref, id,
#     index), and a workspace that is not in the tree says so instead of
#     claiming there is no Polytoken session.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "workspace_id": "DD9B932A-15D2-4E12-838F-8E237A32EDC6",
  "workspace_index": 1,
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
before_layout="$(layout)"
out="$(run_cmd "$GATHER" --workspace 1 2>"$TEST_TMP/s9a.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "already gathered"; then
  note "S9: --workspace accepts an index"
else
  bail "S9: the index form failed (rc=$rc): $(cat "$TEST_TMP/s9a.err")"
fi
out="$(run_cmd "$GATHER" --workspace DD9B932A-15D2-4E12-838F-8E237A32EDC6 2>"$TEST_TMP/s9b.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "already gathered"; then
  note "S9: --workspace accepts a workspace id"
else
  bail "S9: the id form failed (rc=$rc): $(cat "$TEST_TMP/s9b.err")"
fi
if [ "$(layout)" = "$before_layout" ] && [ "$(mutating_count)" -eq 0 ]; then
  note "S9: neither form moved anything (single-pane workspace)"
else
  bail "S9: unexpected state after the alias forms: $(layout)"
fi
out="$(run_cmd "$SPREAD" --workspace workspace:99 2>"$TEST_TMP/s9c.err")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "is not in cmux's tree" "$TEST_TMP/s9c.err"; then
  note "S9: an unknown workspace is reported as a workspace problem"
else
  bail "S9: expected a workspace-not-found refusal (rc=$rc): $(cat "$TEST_TMP/s9c.err")"
fi
if grep -q "no polytoken session" "$TEST_TMP/s9c.err"; then
  bail "S9: the unknown-workspace path still reports the misleading no-session message"
else
  note "S9: the unknown-workspace path no longer claims there is no Polytoken session"
fi

# S10: two Polytoken tabs in two panes -> the first pane in tree order is the
#      anchor, and the other Polytoken tab is left where it is (the documented
#      caveat).
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:46"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken (first)" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:46": { "type": "terminal", "tty": "ttys016", "title": "polytoken (second)" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
ttys016: polytoken -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s10.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pane_count)" -eq 3 ]; then
  note "S10: a second Polytoken pane is not merged, so three panes remain"
else
  bail "S10: expected exit 0 and 3 panes (rc=$rc): $(layout)"
fi
if [ "$(surfaces_of pane:13)" = "surface:42" ] \
   && [ "$(surfaces_of pane:14)" = "surface:46" ] \
   && [ "$(surfaces_of "$(pane_of surface:43)")" = "surface:43" ]; then
  note "S10: lazygit split off the first keep pane; the second Polytoken tab never moved"
else
  bail "S10: unexpected layout: $(layout)"
fi
if [ "$(mutating_verbs)" = "split-off --surface surface:43 right --focus false" ]; then
  note "S10: exactly one split-off, and no move of the other keep surface"
else
  bail "S10: unexpected mutating calls: $(mutating_verbs | tr '\n' '|')"
fi

# S11: --debug dumps the classification / layout to stderr on the read path
#      (and is still only a read: paired with --dry-run nothing is called).
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43", "surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" },
    "surface:44": { "type": "browser", "url": "https://example.com", "title": "docs" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" --dry-run --debug 2>"$TEST_TMP/s11a.err")"; rc=$?
if [ "$rc" -eq 0 ]; then
  note "S11: spread --debug --dry-run exits 0"
else
  bail "S11: spread --debug failed (rc=$rc): $(cat "$TEST_TMP/s11a.err")"
fi
if grep -q "debug: surface:42 pane=pane:13 tty=ttys012 -> keep" "$TEST_TMP/s11a.err"; then
  note "S11: spread --debug reports the keep surface"
else
  bail "S11: no keep line in: $(cat "$TEST_TMP/s11a.err")"
fi
if grep -q "debug: surface:43 pane=pane:13 tty=ttys013 -> lazygit" "$TEST_TMP/s11a.err"; then
  note "S11: spread --debug reports the move surface"
else
  bail "S11: no lazygit line in: $(cat "$TEST_TMP/s11a.err")"
fi
if grep -q "type=browser -> untouched" "$TEST_TMP/s11a.err"; then
  note "S11: spread --debug reports the non-terminal surface as untouched"
else
  bail "S11: no browser line in: $(tr '\n' '|' <"$TEST_TMP/s11a.err")"
fi
if [ "$(unread_calls)" = "" ]; then
  note "S11: spread --debug --dry-run still made no non-read call"
else
  bail "S11: debug leaked a call: $(unread_calls | tr '\n' '|')"
fi
# gather needs more than one pane, or it exits at the already-gathered guard
# before it can dump anything.
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
out="$(run_cmd "$GATHER" --dry-run --debug 2>"$TEST_TMP/s11b.err")"; rc=$?
if [ "$rc" -eq 0 ]; then
  note "S11: gather --debug --dry-run exits 0"
else
  bail "S11: gather --debug failed (rc=$rc): $(cat "$TEST_TMP/s11b.err")"
fi
if grep -q "debug: pane pane:13 focused=1 surfaces:" "$TEST_TMP/s11b.err"; then
  note "S11: gather --debug dumps the pane layout"
else
  bail "S11: no pane dump in: $(cat "$TEST_TMP/s11b.err")"
fi
if grep -q "debug: target=pane:13" "$TEST_TMP/s11b.err"; then
  note "S11: gather --debug reports the target pane"
else
  bail "S11: no target line in: $(cat "$TEST_TMP/s11b.err")"
fi
if [ "$(unread_calls)" = "" ]; then
  note "S11: gather --debug --dry-run still made no non-read call"
else
  bail "S11: debug leaked a call: $(unread_calls | tr '\n' '|')"
fi

# S12: --close-when-done closes the terminal the command ran in — on the
#      success path, last, and only when it can be identified; never when that
#      terminal is the one hosting the Polytoken session.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
TEST_OWN_TTY=ttys013
out="$(run_cmd "$SPREAD" --close-when-done 2>"$TEST_TMP/s12a.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && [ "$(pane_count)" -eq 2 ]; then
  note "S12: --close-when-done still arranges (exit 0, two panes)"
else
  bail "S12: expected exit 0 and 2 panes (rc=$rc): $(layout)"
fi
if [ "$(mutating_verbs | tail -n 1)" = "close-surface --surface pt-cmux-test-own" ]; then
  note "S12: the close is the last mutating call, after the arrangement"
else
  bail "S12: expected the close last, got: $(mutating_verbs | tr '\n' '|')"
fi

# S12b: no CMUX_SURFACE_ID -> refuse to close (a bare close-surface would close
#       whichever surface happened to be focused), but still exit 0.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
TEST_CMUX_SURFACE_ID=
TEST_OWN_TTY=ttys013
out="$(run_cmd "$SPREAD" --close-when-done 2>"$TEST_TMP/s12b.err")"; rc=$?
unset TEST_CMUX_SURFACE_ID TEST_OWN_TTY
if [ "$rc" -eq 0 ] && grep -q "CMUX_SURFACE_ID is unset" "$TEST_TMP/s12b.err"; then
  note "S12b: refuses to close an unidentifiable terminal, with the reason on stderr"
else
  bail "S12b: expected a refusal (rc=$rc): $(cat "$TEST_TMP/s12b.err")"
fi
if [ "$(mutating_verbs | grep -c '^close-surface')" -eq 0 ]; then
  note "S12b: no close-surface call was attempted"
else
  bail "S12b: a close-surface call went out anyway: $(mutating_verbs | tr '\n' '|')"
fi

# S12c: the terminal we are running in is the one hosting the session -> never
#       close it, whatever the caller asked for.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
TEST_OWN_TTY=ttys012
out="$(run_cmd "$SPREAD" --close-when-done 2>"$TEST_TMP/s12c.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && grep -q "refusing to close the terminal hosting the Polytoken session" "$TEST_TMP/s12c.err"; then
  note "S12c: refuses to close the terminal hosting the Polytoken session"
else
  bail "S12c: expected a refusal (rc=$rc): $(cat "$TEST_TMP/s12c.err")"
fi
if [ "$(mutating_verbs | grep -c '^close-surface')" -eq 0 ]; then
  note "S12c: no close-surface call was attempted"
else
  bail "S12c: a close-surface call went out anyway: $(mutating_verbs | tr '\n' '|')"
fi

# S12d: a failure leaves the terminal open, so the message stays readable.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys013: lazygit -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" --close-when-done 2>"$TEST_TMP/s12d.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(mutating_count)" -eq 0 ]; then
  note "S12d: a refused run does not close the terminal"
else
  bail "S12d: expected a refusal with no calls (rc=$rc): $(cat "$TEST_TMP/s12d.err")"
fi

# S12e: dry run prints the planned close instead of making it.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
TEST_OWN_TTY=ttys013
out="$(run_cmd "$SPREAD" --dry-run --close-when-done 2>"$TEST_TMP/s12e.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^cmux close-surface --surface pt-cmux-test-own$'; then
  note "S12e: dry run prints the planned close"
else
  bail "S12e: expected a planned close line (rc=$rc): $out"
fi
if [ "$(unread_calls)" = "" ]; then
  note "S12e: dry run made no non-read call (so nothing was closed)"
else
  bail "S12e: dry run called out: $(unread_calls | tr '\n' '|')"
fi

# S12f: no identifiable terminal of our own (detached, or a caller with no
#       controlling tty) -> refuse, because the "is this the agent's terminal?"
#       check has nothing to compare against.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
TEST_OWN_TTY=
out="$(run_cmd "$SPREAD" --close-when-done 2>"$TEST_TMP/s12f.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && grep -q "cannot identify the terminal" "$TEST_TMP/s12f.err"; then
  note "S12f: refuses to close when it cannot identify its own terminal"
else
  bail "S12f: expected a refusal (rc=$rc): $(cat "$TEST_TMP/s12f.err")"
fi
if [ "$(mutating_verbs | grep -c '^close-surface')" -eq 0 ]; then
  note "S12f: no close-surface call was attempted"
else
  bail "S12f: a close-surface call went out anyway: $(mutating_verbs | tr '\n' '|')"
fi

# S13: cmux commits split-off asynchronously; on a real session a tree read
# right after the call still shows the pre-split layout for ~0.1-0.3 s. A
# caller that reads once races that commit and loses — which is exactly how
# every Command Palette run failed (split reported as failed, exit 1, the
# palette tab left open). The script must poll instead.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "tree_lag": 1,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "polytoken" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "lazygit" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: lazygit -/bin/zsh
EOF
out="$(run_cmd "$SPREAD" 2>"$TEST_TMP/s13.err")"; rc=$?
if [ "$rc" -eq 0 ]; then
  note "S13: a lagging tree after split-off still spreads (exit 0)"
else
  bail "S13: expected success: $(cat "$TEST_TMP/s13.err")"
fi
if [ "$(pane_of surface:43)" != "pane:13" ] && [ -n "$(pane_of surface:43)" ]; then
  note "S13: lazygit is in the new split despite the stale first read"
else
  bail "S13: lazygit never left the keep pane: $(cat "$TEST_TMP/s13.err")"
fi
if [ "$(mutating_verbs)" = "split-off --surface surface:43 right --focus false" ]; then
  note "S13: the pre-collapse was a no-op and only the split mutated state"
else
  bail "S13: unexpected call sequence: $(mutating_verbs | tr '\n' '|')"
fi

# G1: three panes collapse into the focused one, tab order preserved, and no
#     pane is left behind.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:44"] },
             { "ref": "pane:15", "focused": false, "surfaces": ["surface:45", "surface:46"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "three" },
    "surface:45": { "type": "terminal", "tty": "ttys015", "title": "four" },
    "surface:46": { "type": "terminal", "tty": "ttys016", "title": "five" }
  }
}
EOF
out="$(run_cmd "$GATHER" 2>"$TEST_TMP/g1.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pane_count)" -eq 1 ]; then
  note "G1: gather exits 0 and leaves a single pane"
else
  bail "G1: expected exit 0 and 1 pane, got rc=$rc panes=$(pane_count) ($(layout))"
fi
if [ "$(surfaces_of pane:13)" = "surface:42 surface:43 surface:44 surface:45 surface:46" ]; then
  note "G1: all five surfaces are tabs of the target pane, in tree order"
else
  bail "G1: unexpected tab order: $(surfaces_of pane:13)"
fi
expected_seq="move-surface --surface surface:44 --pane pane:13 --after surface:43 --focus false
move-surface --surface surface:45 --pane pane:13 --after surface:44 --focus false
move-surface --surface surface:46 --pane pane:13 --after surface:45 --focus false"
if [ "$(mutating_verbs)" = "$expected_seq" ]; then
  note "G1: each move is chained --after the previous surface"
else
  bail "G1: unexpected mutating calls: $(mutating_verbs | tr '\n' '|')"
fi
if grep -q "still present" "$TEST_TMP/g1.err"; then
  bail "G1: gather warned about leftover panes: $(cat "$TEST_TMP/g1.err")"
else
  note "G1: no leftover-pane warning (the emptied panes are gone)"
fi
if printf '%s' "$out" | grep -q "gathered 3 surface(s) into pane:13"; then
  note "G1: summary reports the three surfaces gathered"
else
  bail "G1: unexpected summary: $out"
fi

# G2: a single-pane workspace is a no-op. The tree read is unavoidable (it is
#     how the pane count is known), so "no-op" means no mutating call and no
#     state change.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42", "surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
before_layout="$(layout)"
out="$(run_cmd "$GATHER" 2>"$TEST_TMP/g2.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "already gathered"; then
  note "G2: single-pane workspace reports already gathered and exits 0"
else
  bail "G2: expected exit 0 with 'already gathered' (rc=$rc, out=$out)"
fi
if [ "$(mutating_count)" -eq 0 ] && [ "$(layout)" = "$before_layout" ] \
   && [ "$(count '^tree --json --workspace workspace:11$')" -eq 1 ]; then
  note "G2: one read, no mutating call, no state change"
else
  bail "G2: unexpected calls or state change, log: $(cat "$CALLS")"
fi

# G3: when cmux does *not* close an emptied pane, gather names it (and still
#     exits 0 — the surfaces did all move).
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "keep_empty_panes": true,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
out="$(run_cmd "$GATHER" 2>"$TEST_TMP/g3.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(surfaces_of pane:13)" = "surface:42 surface:43" ]; then
  note "G3: every surface still ends up in the target pane"
else
  bail "G3: expected all surfaces in pane:13 (rc=$rc): $(layout)"
fi
if [ "$(pane_count)" -eq 2 ]; then
  note "G3: the emptied pane lingers, as this fixture models"
else
  bail "G3: fixture expected pane:14 to linger, got: $(layout)"
fi
if grep -q "still present after gathering: pane:14" "$TEST_TMP/g3.err"; then
  note "G3: gather names the pane that survived"
else
  bail "G3: expected a leftover warning naming pane:14: $(cat "$TEST_TMP/g3.err")"
fi

# G3b: a workspace whose extra pane is already empty has nothing to move, so
#      gather says that too rather than reporting a clean gather.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "keep_empty_panes": true,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": [] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" }
  }
}
EOF
before_layout="$(layout)"
out="$(run_cmd "$GATHER" 2>"$TEST_TMP/g3b.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "no surfaces moved"; then
  note "G3b: exits 0 and reports that nothing moved"
else
  bail "G3b: expected exit 0 with a no-surfaces-moved message (rc=$rc): $out"
fi
if grep -q "nothing to move, but 1 pane(s) beyond pane:13 still exist" "$TEST_TMP/g3b.err"; then
  note "G3b: warns about the pane that has nothing in it"
else
  bail "G3b: expected an empty-pane warning: $(cat "$TEST_TMP/g3b.err")"
fi
if [ "$(mutating_count)" -eq 0 ] && [ "$(layout)" = "$before_layout" ]; then
  note "G3b: no mutating call and no state change"
else
  bail "G3b: unexpected calls or state change: $(mutating_verbs | tr '\n' '|')"
fi

# G4: --close-when-done for gather — including the no-op paths, so a palette
#     run on a single-pane workspace does not leave a tab either.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
EOF
TEST_OWN_TTY=ttys013
out="$(run_cmd "$GATHER" --close-when-done 2>"$TEST_TMP/g4a.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && [ "$(pane_count)" -eq 1 ]; then
  note "G4: --close-when-done still gathers (exit 0, one pane)"
else
  bail "G4: expected exit 0 and 1 pane (rc=$rc): $(layout)"
fi
if [ "$(mutating_verbs | tail -n 1)" = "close-surface --surface pt-cmux-test-own" ]; then
  note "G4: the close is the last mutating call, after the moves"
else
  bail "G4: expected the close last, got: $(mutating_verbs | tr '\n' '|')"
fi

# G4b: an already-gathered workspace is a no-op that still closes the tab.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
EOF
TEST_OWN_TTY=ttys013
out="$(run_cmd "$GATHER" --close-when-done 2>"$TEST_TMP/g4b.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "already gathered"; then
  note "G4b: an already-gathered workspace still reports already gathered"
else
  bail "G4b: unexpected output (rc=$rc): $out"
fi
if [ "$(mutating_verbs)" = "close-surface --surface pt-cmux-test-own" ]; then
  note "G4b: the no-op path closes the tab and nothing else"
else
  bail "G4b: unexpected calls: $(mutating_verbs | tr '\n' '|')"
fi

# G4c: never close the terminal hosting the session.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
EOF
TEST_OWN_TTY=ttys012
out="$(run_cmd "$GATHER" --close-when-done 2>"$TEST_TMP/g4c.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && grep -q "refusing to close the terminal hosting the Polytoken session" "$TEST_TMP/g4c.err"; then
  note "G4c: refuses to close the terminal hosting the Polytoken session"
else
  bail "G4c: expected a refusal (rc=$rc): $(cat "$TEST_TMP/g4c.err")"
fi
if [ "$(mutating_verbs | grep -c '^close-surface')" -eq 0 ]; then
  note "G4c: no close-surface call was attempted"
else
  bail "G4c: a close-surface call went out anyway: $(mutating_verbs | tr '\n' '|')"
fi

# G4d: a failed run leaves the terminal open.
setup
remember_calls
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
EOF
out="$(run_cmd "$GATHER" --workspace workspace:99 --close-when-done 2>"$TEST_TMP/g4d.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(mutating_count)" -eq 0 ]; then
  note "G4d: a failed run does not close the terminal"
else
  bail "G4d: expected a failure with no calls (rc=$rc): $(cat "$TEST_TMP/g4d.err")"
fi

# G4e: without an identifiable terminal of its own, gather refuses to close
#      rather than guessing.
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
EOF
TEST_OWN_TTY=
out="$(run_cmd "$GATHER" --close-when-done 2>"$TEST_TMP/g4e.err")"; rc=$?
unset TEST_OWN_TTY
if [ "$rc" -eq 0 ] && grep -q "cannot identify the terminal" "$TEST_TMP/g4e.err"; then
  note "G4e: refuses to close when it cannot identify its own terminal"
else
  bail "G4e: expected a refusal (rc=$rc): $(cat "$TEST_TMP/g4e.err")"
fi
if [ "$(mutating_verbs | grep -c '^close-surface')" -eq 0 ]; then
  note "G4e: no close-surface call was attempted"
else
  bail "G4e: a close-surface call went out anyway: $(mutating_verbs | tr '\n' '|')"
fi

# G4f: the leftover-pane warning must wait out cmux's asynchronous pane
# close instead of reading the stale pre-move tree and warning about panes
# the workspace is already rid of (same async commit as the spread race).
setup
remember_calls
seed_state <<'EOF'
{
  "workspace_ref": "workspace:11",
  "next_pane": 20,
  "tree_lag": 1,
  "panes": [ { "ref": "pane:13", "focused": true, "surfaces": ["surface:42"] },
             { "ref": "pane:14", "focused": false, "surfaces": ["surface:43"] },
             { "ref": "pane:15", "focused": false, "surfaces": ["surface:44"] } ],
  "surfaces": {
    "surface:42": { "type": "terminal", "tty": "ttys012", "title": "one" },
    "surface:43": { "type": "terminal", "tty": "ttys013", "title": "two" },
    "surface:44": { "type": "terminal", "tty": "ttys014", "title": "three" }
  }
}
EOF
seed_ps <<'EOF'
ttys012: polytoken -/bin/zsh
ttys013: -/bin/zsh
ttys014: -/bin/zsh
EOF
out="$(run_cmd "$GATHER" 2>"$TEST_TMP/g4f.err")"; rc=$?
if [ "$rc" -eq 0 ]; then
  note "G4f: a lagging tree still gathers (exit 0)"
else
  bail "G4f: expected success: $(cat "$TEST_TMP/g4f.err")"
fi
if grep -q "still present after gathering" "$TEST_TMP/g4f.err"; then
  bail "G4f: warned about panes the stale first read only imagined: $(cat "$TEST_TMP/g4f.err")"
else
  note "G4f: no leftover warning for panes the tree had only not caught up on"
fi
if [ "$(grep -c '^tree ' "$CALLS")" -ge 3 ]; then
  note "G4f: verification polled the tree past the stale read"
else
  bail "G4f: expected 3+ tree reads (initial + stale + settled), got $(grep -c '^tree ' "$CALLS")"
fi

# ------------------------------------- install/uninstall: cmux actions ----

seed_cmux_json() {
  # A realistic cmux.json: comments (line and block), a URL inside a string
  # that must not be mistaken for a comment, trailing commas in three
  # places, and one foreign action that has to survive the merge.
  mkdir -p "$TEST_TMP/xdg/cmux"
  cat >"$TEST_TMP/xdg/cmux/cmux.json" <<'EOF'
{
  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
  "schemaVersion": 1,

  // Template note: cmux writes this file on first launch.
  /* block comment, containing a // and a } brace */
  "terminal": {
    "fontFamily": "SF Mono",   // trailing comment
  },
  "actions": {
    "foreign-action": {
      "type": "command",
      "title": "Foreign: keep me",
      "command": "echo 'https://example.com/keep/me' stays a string",
    },
  },
}
EOF
  # cmux.json is commonly 0600; the merge must not widen that.
  chmod 600 "$TEST_TMP/xdg/cmux/cmux.json"
}

cmux_json_of() { printf '%s\n' "$TEST_TMP/xdg/cmux/cmux.json"; }

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# I1: install merges the two actions into a JSONC config, preserves foreign
#     content, backs the file up, and is idempotent on re-run.
if [ "$HAVE_PYTHON3" = "1" ]; then
  setup
  seed_cmux_json
  cmux_json="$(cmux_json_of)"
  run_install >/dev/null 2>&1
  if jq -e '.actions["pt-cmux-spread"].type == "command"
            and .actions["pt-cmux-spread"].title == "Spread: split lg/croft right of polytoken"
            and .actions["pt-cmux-gather"].type == "command"
            and .actions["pt-cmux-gather"].title == "Gather: merge workspace panes"' \
       "$cmux_json" >/dev/null 2>&1; then
    note "I1: both pt-cmux actions registered as type=command with their titles"
  else
    bail "I1: actions not registered: $(cat "$cmux_json" 2>/dev/null)"
  fi
  if [ "$(jq -r '.actions["pt-cmux-spread"].command' "$cmux_json")" \
       = "'$TEST_TMP/xdg/polytoken/pt-cmux/pt-cmux-spread' --close-when-done" ] \
     && [ "$(jq -r '.actions["pt-cmux-gather"].command' "$cmux_json")" \
       = "'$TEST_TMP/xdg/polytoken/pt-cmux/pt-cmux-gather' --close-when-done" ]; then
    note "I1: action commands point at the installed scripts and close their tab"
  else
    bail "I1: unexpected command paths: $(jq -c '.actions' "$cmux_json")"
  fi
  if [ "$(file_mode "$cmux_json")" = "600" ]; then
    note "I1: the merged file keeps the original's 0600 permissions"
  else
    bail "I1: the merge changed the file mode to $(file_mode "$cmux_json")"
  fi
  if jq -e '.actions["foreign-action"].command | contains("https://example.com/keep/me")' \
       "$cmux_json" >/dev/null 2>&1 \
     && [ "$(jq -r '.schemaVersion' "$cmux_json")" = "1" ] \
     && [ "$(jq -r '.terminal.fontFamily' "$cmux_json")" = "SF Mono" ]; then
    note "I1: foreign action, schemaVersion and terminal settings survived; the URL was not treated as a comment"
  else
    bail "I1: merge lost unrelated content: $(cat "$cmux_json")"
  fi
  backup_found=""
  for f in "$TEST_TMP/xdg/cmux/"cmux.json.*.bak; do
    [ -f "$f" ] || continue
    backup_found="$f"
    break
  done
  if [ -n "$backup_found" ] && grep -q 'Template note' "$backup_found"; then
    note "I1: the original (comments included) was backed up first"
  else
    bail "I1: no usable backup found (found: ${backup_found:-none})"
  fi
  cp "$cmux_json" "$TEST_TMP/cmux-after-first.json"
  run_install >/dev/null 2>"$TEST_TMP/i1b.err"
  if cmp -s "$cmux_json" "$TEST_TMP/cmux-after-first.json"; then
    note "I1: re-running install leaves the file byte-identical (idempotent)"
  else
    bail "I1: re-run rewrote the config: $(cat "$cmux_json")"
  fi
  if [ "$(jq '[.actions | keys[] | select(startswith("pt-cmux-"))] | length' "$cmux_json")" -eq 2 ]; then
    note "I1: still exactly two pt-cmux actions after two installs"
  else
    bail "I1: unexpected action count: $(jq -c '.actions | keys' "$cmux_json")"
  fi

  # I2: a corrupt config is refused before anything is written.
  setup
  seed_cmux_json
  cmux_json="$(cmux_json_of)"
  # break it: an unterminated object
  printf '%s\n' '{ "actions": { "broken": }' >"$cmux_json"
  cp "$cmux_json" "$TEST_TMP/i2-original.json"
  run_install >/dev/null 2>"$TEST_TMP/i2.err"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q "not valid JSONC" "$TEST_TMP/i2.err"; then
    note "I2: install refuses a corrupt cmux.json with the reason on stderr"
  else
    bail "I2: expected a refusal (rc=$rc): $(cat "$TEST_TMP/i2.err")"
  fi
  if cmp -s "$cmux_json" "$TEST_TMP/i2-original.json" \
     && [ ! -e "$TEST_TMP/xdg/polytoken/hooks.json" ]; then
    note "I2: the corrupt file is untouched and the install stopped before the hooks"
  else
    bail "I2: install modified state despite refusing (hooks: $([ -e "$TEST_TMP/xdg/polytoken/hooks.json" ] && echo yes || echo no))"
  fi

  # I2b: cmux rejecting the merged config must not replace the target.
  setup
  seed_cmux_json
  cmux_json="$(cmux_json_of)"
  cp "$cmux_json" "$TEST_TMP/i2b-original.json"
  run_install PTCMUX_TEST_SHIM_FAIL_CONFIG_CHECK=1 >/dev/null 2>"$TEST_TMP/i2b.err"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q "rejected the merged config" "$TEST_TMP/i2b.err"; then
    note "I2b: install fails when cmux rejects the merged config"
  else
    bail "I2b: expected a config-check refusal (rc=$rc): $(cat "$TEST_TMP/i2b.err")"
  fi
  if cmp -s "$cmux_json" "$TEST_TMP/i2b-original.json"; then
    note "I2b: the target is left byte-identical (validate before replace)"
  else
    bail "I2b: the target was replaced despite the check failing"
  fi
  if [ ! -e "$TEST_TMP/xdg/polytoken/hooks.json" ] && [ ! -e "$TEST_TMP/xdg/polytoken/pt-cmux" ]; then
    note "I2b: the refusal happens before the hooks and scripts are installed"
  else
    bail "I2b: the install touched the hooks or scripts before the config check failed"
  fi

  # U1: uninstall strips only our entries, and does not rewrite a config that
  #     has none left.
  setup
  seed_cmux_json
  cmux_json="$(cmux_json_of)"
  run_install >/dev/null 2>&1
  run_uninstall >/dev/null 2>&1
  if jq -e '.actions | keys == ["foreign-action"]' "$cmux_json" >/dev/null 2>&1; then
    note "U1: uninstall leaves exactly the foreign action"
  else
    bail "U1: unexpected actions after uninstall: $(jq -c '.actions | keys' "$cmux_json" 2>/dev/null)"
  fi
  if jq -e '.actions["foreign-action"].title == "Foreign: keep me"' "$cmux_json" >/dev/null 2>&1; then
    note "U1: the foreign action is intact"
  else
    bail "U1: the foreign action was damaged: $(cat "$cmux_json")"
  fi
  cp "$cmux_json" "$TEST_TMP/u1-after-strip.json"
  run_uninstall >"$TEST_TMP/u1b.out" 2>&1
  if cmp -s "$cmux_json" "$TEST_TMP/u1-after-strip.json" \
     && grep -q "no pt-cmux-" "$TEST_TMP/u1b.out"; then
    note "U1: a second uninstall reports nothing to strip and rewrites nothing"
  else
    bail "U1: second uninstall modified the config or stayed quiet: $(cat "$TEST_TMP/u1b.out")"
  fi
else
  note "I1/I2/I2b/U1: skipped (python3 not found)"
fi

# ------------------------------------------------ negative lane check ----

# No handler/watcher path may emit a workspace status lane command: lanes
# are the user's manual surface. The only lane command in the whole suite
# is uninstall's legacy scrub, whose log lives in its own temp dir and is
# not in RECORDED_CALLS (case 13 pins it to exactly one occurrence).
lane_hits=""
n_logs=0
for f in $RECORDED_CALLS; do
  n_logs=$((n_logs + 1))
  hit="$(grep -h '^workspace status set' "$f" 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    lane_hits="$lane_hits $hit"
  fi
done
if [ -n "$lane_hits" ]; then
  bail "negative: handler/watcher path emitted a lane command: $lane_hits"
elif [ "$n_logs" -ge 11 ]; then
  note "negative: no handler/watcher call log ($n_logs logs) contains a lane command"
else
  bail "negative: only $n_logs handler/watcher call logs recorded (expected >= 11)"
fi

# ------------------------------------------------------------ summary -----

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1

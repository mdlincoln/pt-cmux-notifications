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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STATUS="$ROOT/bin/pt-cmux-status"
WATCHER="$ROOT/bin/pt-cmux-watcher"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
BASE_TMP="${TMPDIR:-/tmp}"

# Make sure no ambient variables leak in from the caller's environment.
unset PTCMUX_CMUX_BIN PTCMUX_LOG PTCMUX_NOTIFY PTCMUX_NO_WATCHER \
      PTCMUX_WATCHER_BIN PTCMUX_WATCH_INTERVAL PTCMUX_TEST_ANCESTOR_PIDS \
      PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE PTCMUX_TEST_SHIM_EXIT \
      PTCMUX_TEST_SHIM_FAIL_ICON \
      POLYTOKEN_SESSION_ID POLYTOKEN_GOAL_ACTIVE 2>/dev/null

if ! command -v jq >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/jq ]; then
  echo "jq is required by these tests (and by install.sh)" >&2
  exit 1
fi

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
  mkdir -p "$TEST_TMP/tmp" "$TEST_TMP/home" "$TEST_TMP/xdg" "$TEST_LOG_DIR"
  : >"$CALLS"
  : >"$CALLS_ARGS"
  cat >"$SHIM" <<EOF
#!/usr/bin/env bash
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
exit \${PTCMUX_TEST_SHIM_EXIT:-0}
EOF
  chmod +x "$SHIM"
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
  ( export XDG_CONFIG_HOME="$TEST_TMP/xdg" HOME="$TEST_TMP/home"
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
  if [ "$(count '^clear-status polytoken$')" -eq 1 ]; then
    note "case 18b: all-dead-at-startup clears the pill exactly once"
  else
    bail "case 18b: expected exactly one clear-status, log: $(cat "$CALLS")"
  fi
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

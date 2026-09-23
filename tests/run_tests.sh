#!/usr/bin/env bash
# tests/run_tests.sh — unit tests for pt-cmux hooks.
#
# Everything runs against a fake cmux shim and temp dirs; the real cmux
# binary, the real Polytoken config, and the real HOME are never touched.
#
# Run: bash tests/run_tests.sh   (nonzero exit on any failure)
#
# Case numbering follows the plan:
#   1–9   script cases (pt-cmux-status handler contract + lane values)
#   10–13 install/uninstall cases
#   14–18 notification and watcher cases

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
SHIM=""

note() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

setup() {
  TEST_TMP="$(mktemp -d "$BASE_TMP/ptcmux-test.XXXXXX")"
  ALL_TMP="$ALL_TMP $TEST_TMP"
  TEST_LOG_DIR="$TEST_TMP/log"
  CALLS="$TEST_TMP/calls.log"
  SHIM="$TEST_TMP/cmux"
  mkdir -p "$TEST_TMP/tmp" "$TEST_TMP/home" "$TEST_TMP/xdg" "$TEST_LOG_DIR"
  : >"$CALLS"
  cat >"$SHIM" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exit \${PTCMUX_TEST_SHIM_EXIT:-0}
EOF
  chmod +x "$SHIM"
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

# 1. working on a fresh session -> one working pin.
setup
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 1: working on fresh session"
if [ "$(count '^workspace status set working$')" -eq 1 ]; then
  note "case 1: lane pinned to working exactly once"
else
  bail "case 1: expected one working pin, log: $(cat "$CALLS")"
fi

# 2. working again -> pinned again (re-pin on every invocation).
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 2: working pinned again"
if [ "$(count '^workspace status set working$')" -eq 2 ]; then
  note "case 2: repeat invocation re-pins working (no dedup)"
else
  bail "case 2: expected two working pins, log: $(cat "$CALLS")"
fi

# 3. needs-attention after working.
out="$(run_status needs-attention 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 3: needs-attention"
if [ "$(count '^workspace status set needs-attention$')" -eq 1 ]; then
  note "case 3: lane pinned to needs-attention"
else
  bail "case 3: expected needs-attention pin, log: $(cat "$CALLS")"
fi

# 4. reset -> auto; a following working still fires a new pin.
out="$(run_status reset 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 4: reset"
if [ "$(count '^workspace status set auto$')" -eq 1 ]; then
  note "case 4: reset pins auto"
else
  bail "case 4: expected auto pin, log: $(cat "$CALLS")"
fi
out="$(run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 4b: working after reset"
if [ "$(count '^workspace status set working$')" -eq 3 ]; then
  note "case 4b: working after reset fires a new pin"
else
  bail "case 4b: expected a fresh working pin, log: $(cat "$CALLS")"
fi

# 5. done with an active goal -> no cmux call at all.
before="$(lines)"
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=true 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 5: done while goal active"
after="$(lines)"
if [ "$before" -eq "$after" ]; then
  note "case 5: goal-active stop does not touch the badge"
else
  bail "case 5: expected no shim calls, log: $(cat "$CALLS")"
fi

# 6. done with no goal -> done pin + notification.
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=false 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 6: done with no goal"
if [ "$(count '^workspace status set done$')" -eq 1 ]; then
  note "case 6: lane pinned to done"
else
  bail "case 6: expected done pin, log: $(cat "$CALLS")"
fi
if [ "$(count '^notify --title Polytoken --body Loop finished')" -eq 1 ]; then
  note "case 6: done posts its notification"
else
  bail "case 6: expected a done notification, log: $(cat "$CALLS")"
fi

# 6b. escape hatch: done while goal active with PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE=1.
out="$(run_status done POLYTOKEN_GOAL_ACTIVE=true PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 6b: SET_DONE_WHEN_GOAL_ACTIVE escape hatch"
if [ "$(count '^workspace status set done$')" -eq 2 ]; then
  note "case 6b: done is pinned despite the active goal"
else
  bail "case 6b: expected a done pin, log: $(cat "$CALLS")"
fi

# 7. cmux missing entirely (override dead, no cmux on PATH) -> exit 0, silent.
setup
out="$(run_status working PATH=/usr/bin:/bin PTCMUX_CMUX_BIN="$TEST_TMP/no-such-cmux" 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 7: cmux missing"
if [ "$(lines)" -eq 0 ]; then
  note "case 7: no cmux call attempted"
else
  bail "case 7: expected an empty call log, log: $(cat "$CALLS")"
fi

# 8. cmux errors (shim exits 1) -> handler still exits 0, silent.
setup
out="$(run_status working PTCMUX_TEST_SHIM_EXIT=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 8: cmux exits nonzero"
if [ -s "$TEST_LOG_DIR/error.log" ]; then
  note "case 8: failure logged to error.log"
else
  bail "case 8: expected the failure to be logged"
fi

# 9. arbitrary JSON on stdin is ignored.
setup
out="$(printf '{"session_id":"s","tool_input":{"q":"hi"}}' | run_status working 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 9: stdin JSON ignored"
if [ "$(count '^workspace status set working$')" -eq 1 ]; then
  note "case 9: lane pinned despite (unrelated) stdin payload"
else
  bail "case 9: expected a working pin, log: $(cat "$CALLS")"
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

# 13. uninstall removes cmux-* entries, keeps third-party, deletes pt-cmux/.
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

# ---------------------------------------------- notification/watcher -----

# 14. waiting lanes post notifications; working/reset clear them.
setup
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

# 15. PTCMUX_NOTIFY=0 -> no notify calls at all.
setup
run_status needs-attention PTCMUX_NOTIFY=0 >/dev/null 2>&1
run_status working PTCMUX_NOTIFY=0 >/dev/null 2>&1
run_status reset PTCMUX_NOTIFY=0 >/dev/null 2>&1
if [ "$(count '^notify')" -eq 0 ]; then
  note "case 15: PTCMUX_NOTIFY=0 disables all notify calls"
else
  bail "case 15: expected no notify calls, log: $(cat "$CALLS")"
fi

# 16. watcher spawns on reset and clears the lane when the watched PID dies.
setup
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
auto_before="$(count '^workspace status set auto$')"
if [ "$auto_before" -ge 1 ]; then
  : # reset already pinned auto once — expected
else
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  bail "case 16: reset should already have pinned auto once"
fi
kill "$spid" 2>/dev/null
wait "$spid" 2>/dev/null
i=0
auto_after="$auto_before"
while [ "$i" -lt 100 ] && [ "$auto_after" -lt $((auto_before + 1)) ]; do
  i=$((i + 1)); sleep 0.1
  auto_after="$(count '^workspace status set auto$')"
done
if [ "$auto_after" -eq $((auto_before + 1)) ]; then
  note "case 16: watcher pinned auto exactly once after watched PID exited"
else
  bail "case 16: expected auto count $((auto_before + 1)), got $auto_after; log: $(cat "$CALLS")"
fi

# 17. PTCMUX_NO_WATCHER=1 -> no watcher, no flag file.
setup
out="$(run_status reset PTCMUX_NO_WATCHER=1 2>/dev/null)"; rc=$?
assert_handler_contract "$rc" "$out" "case 17: reset with watcher disabled"
flag="$TEST_TMP/tmp/pt-cmux-status/watcher-test-session"
if [ ! -e "$flag" ] && [ "$(count '^workspace status set auto$')" -eq 1 ]; then
  note "case 17: no watcher spawned, lane still pinned to auto"
else
  bail "case 17: watcher was spawned or reset misbehaved (flag: $flag)"
fi

# 18. watcher with no PIDs exits silently; all-dead-at-startup clears once.
setup
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
  if [ "$(count '^workspace status set auto$')" -eq 1 ]; then
    note "case 18b: all-dead-at-startup pins auto exactly once"
  else
    bail "case 18b: expected exactly one auto pin, log: $(cat "$CALLS")"
  fi
fi

# 20. watcher tolerates a missing cmux binary (exit 0, silent, no calls).
setup
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

# ------------------------------------------------------------ summary -----

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1

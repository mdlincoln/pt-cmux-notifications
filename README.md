# pt-cmux-notifications

Polytoken hooks that keep the cmux sidebar status pill for Polytoken in
sync with the Polytoken loop — and post cmux notifications when the loop
is waiting on you.

## What it does

Whenever a Polytoken session runs inside a cmux workspace, the session's
sidebar row shows a status pill — the same icon-and-color pill treatment
native Claude Code sessions get — under the status key `polytoken`:

| Pill text | Icon | Color | cmux call | Polytoken hook event | Why |
|---|---|---|---|---|---|
| `Running` | `bolt.fill` | `#4C8DFF` | `cmux set-status polytoken Running --icon bolt.fill --color '#4C8DFF'` | `pre_user_prompt`, `pre_model_turn` | A submitted prompt or an upcoming model call means the loop is running. |
| `Needs input` | `bell.fill` | `#FF9500` | `cmux set-status polytoken 'Needs input' --icon bell.fill --color '#FF9500'` | `pre_tool_use` (`ask_user_question`) | Fires right before a user question blocks the turn. |
| `In review` | `eye.fill` | `#34C759` | `cmux set-status polytoken 'In review' --icon eye.fill --color '#34C759'` | `pre_tool_use` (`handoff_plan`) | Fires right before a plan is submitted for operator review. |
| `Idle` | `pause.circle.fill` | `#8E8E93` | `cmux set-status polytoken Idle --icon pause.circle.fill --color '#8E8E93'` | `stop` | The model finished and the turn went back to the user. |
| — (pill removed) | — | — | `cmux clear-status polytoken` | `session_start` (reset) | Clears any stale pill from a previous session. |

The `Running` icon/color pair is exactly what cmux itself sends for its
built-in Claude Code integration. The other three are deliberate choices:
`Needs input` uses amber instead of cmux's blue so the two states are
visually distinct (the identical-blue native treatment is a known
complaint, cmux #2616); `In review` and `Idle` have no native equivalent
under the custom `polytoken` key (the `Idle` icon matches what cmux uses
for Codex).

Additionally:

- **Notifications.** Transitions that leave the running state
  (`Needs input`, `In review`, `Idle`) post a cmux notification
  (`cmux notify`), so they are visible outside the workspace. The
  `Running` and reset transitions run `cmux notify --clear` so stale
  notifications don't pile up while the loop runs. Disable all of it with
  `PTCMUX_NOTIFY=0`.
- **Exit clearing.** Polytoken hooks have no session-exit event, so at
  `session_start` the handler spawns a detached watcher
  (`pt-cmux-watcher`) that polls the session's Polytoken process PIDs and
  clears the pill once they have all exited. Pills persist until cleared,
  so this is how the pill disappears on quit.
- **Goal-flicker mitigation.** While a saved-session goal is active, the
  loop keeps running on your behalf after every `stop`, so `stop` does
  **not** set `Idle` — the pill stays `Running` until the goal finishes
  and the final turn ends without a goal active.
- **Styled pill.** Each lane's `cmux set-status` call passes `--icon`
  (an SF Symbols name) and `--color` (a hex string) via the documented
  `cmux set-status` styling flags, mirroring the values cmux itself
  uses for its built-in Claude Code integration (see the table above).
  On a cmux build that rejects the styling flags the handler logs the
  failure and retries once with the plain unstyled call, so the pill is
  always set.

## Requirements

- cmux with sidebar status pills (`cmux set-status`, 0.64.x)
- Polytoken
- jq — only needed by `install.sh`/`uninstall.sh` for the merge

## Install

```sh
./install.sh
```

This installs:

- the handler scripts to `${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/pt-cmux/`
- the six `cmux-*` hook entries into the global
  `${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/hooks.json`

If a global `hooks.json` already exists, the installer **merges**: it
backs the file up to `hooks.json.<timestamp>.<pid>.bak`, removes any
previous `cmux-*` entries, and appends the current ones — unrelated
third-party hooks are preserved, and re-running the installer never
duplicates entries.

> **Note:** the hook handler paths expand
> `${XDG_CONFIG_HOME:-$HOME/.config}` from the **Polytoken daemon's**
> environment at hook-fire time, while `install.sh` resolves it from the
> shell you run it in. If you install with a custom `XDG_CONFIG_HOME`,
> make sure the daemon sees the same value, or the hooks will point at a
> path that does not exist.

> After installing, remember that Polytoken loads global hooks at startup
> or after a config reload — restart existing sessions (or reload config)
> before the hooks take effect.

## Uninstall

```sh
./uninstall.sh
```

Removes the `cmux-*` entries from `hooks.json` (deleting the file if no
hooks remain), removes the `pt-cmux/` script directory, and best-effort
clears the Polytoken status pill. It also scrubs the legacy workspace
lane pin that the previous (lane-based) version of this repo could leave
behind — per cmux's override semantics that pin auto-clears on its own
once the inferred lane shifts, the scrub just makes it immediate.

## Verifying in a live session (inside cmux)

Start a new Polytoken session in a cmux workspace. After each step check
`cmux list-status` (the `polytoken` entry should show the expected text)
and look at the session's sidebar row, which should show the same pill
treatment native Claude Code sessions show:

1. **Prompt submitted** → pill shows `Running` with the blue `bolt.fill`
   icon. Also check mid-turn during a long-running tool call —
   `pre_model_turn` keeps it set.
2. **User question open** (the model calls `ask_user_question`) → pill
   shows `Needs input` with the amber `bell.fill` icon while the
   question is on screen; after answering, the next model turn returns
   it to `Running`.
3. **Plan review open** (the model calls `handoff_plan`) → pill shows
   `In review`; approving or rejecting returns it to `Running` via the
   next model turn.
4. **Plain turn end** → pill shows `Idle`.
5. **Goal-driven turn end** → pill stays `Running` while the goal is
   active; when the goal completes and the last turn ends, the pill lands
   on `Idle`.
6. **Notifications** → each waiting-state transition (2–4) posted a
   notification, visible via `cmux list-notifications`; resuming work
   (`Running`) clears them.
7. **Exit clearing** → quit the Polytoken session; the pill disappears
   from `cmux list-status` (and from the sidebar row) within ~2 poll
   intervals. Also record what the ancestry walk finds (are hook handlers
   children of a per-session process or of a shared daemon?), and close
   one of two concurrent Polytoken sessions while the other keeps running
   — if the pill survives, the watcher is watching a shared daemon and
   the per-session PID refinement is needed (see design notes).
8. **Hook load check** → start a new session and submit one prompt; no
   hook-related error or warning should appear in the session's visible
   output surface.
9. **Background-job wake observation** → trigger a user question while a
   background job is running; note whether a `pre_model_turn` wake
   briefly flips the pill back to `Running` (expected to be rare and
   self-healing).

## Configuration

### Per-project hook disabling

Any project can disable individual hooks via a project-level
`.polytoken/hooks.json` with a negation entry:

```json
["!cmux-done"]
```

> **Warning:** the name after `!` must exactly match an installed global
> hook name (`cmux-session-reset`, `cmux-working-prompt`,
> `cmux-working-turn`, `cmux-needs-attention`, `cmux-review`,
> `cmux-done`). A non-matching name causes Polytoken to reject the
> project's entire `hooks.json`.

### Environment variables

| Variable | Effect |
|---|---|
| `PTCMUX_NOTIFY=0` | Disable all notification posts and clears. |
| `PTCMUX_NO_WATCHER=1` | Never spawn the exit watcher. |
| `PTCMUX_SET_DONE_WHEN_GOAL_ACTIVE=1` | Let `stop` set `Idle` even while a goal is active (restores per-turn idle flicker). |
| `PTCMUX_CMUX_BIN` | Explicit cmux binary. Authoritative: if set but not executable, cmux is treated as absent. |
| `PTCMUX_WATCHER_BIN` | Override the path to `pt-cmux-watcher`. |
| `PTCMUX_WATCH_INTERVAL` | Watcher poll interval in seconds (default 2). |
| `PTCMUX_LOG` | Log file for swallowed errors (default `$TMPDIR/pt-cmux-status/error.log`). |

## Notifications & exit clearing — details

- Notification bodies: `cmux-needs-attention` → "A user question is
  waiting for your answer"; `cmux-review` → "A plan is ready for your
  review"; `cmux-done` → "Loop finished — turn handed back to you".
- `Idle` posts a notification on each turn end that reaches it — the goal
  gate suppresses the transition entirely while a goal is active (by
  design). The `notify --clear` on the next `Running` set keeps
  accumulation bounded to the idle window.
- `cmux notify --clear` clears **all** notifications for the workspace,
  not only ours — third-party workspace notifications are cleared too.
- The exit watcher: at `session_start` the handler walks its own process
  ancestry (`ps`) and collects every ancestor whose process name mentions
  `polytoken`; the detached watcher polls those PIDs (every
  `PTCMUX_WATCH_INTERVAL` seconds) and clears the status pill once they
  have all exited. If no Polytoken ancestor can be identified, no watcher
  starts — the next session's reset still clears any stale pill.
- Known granularity caveat: if hook handlers are spawned by a long-lived
  shared daemon rather than the per-session TUI process, the watcher fires
  only when that daemon exits, leaving a stale pill after closing one of
  several sessions. It degrades gracefully (no spurious clears; the next
  session's reset re-clears), and the live checklist records the actual
  granularity. Converse races (a previous session's watcher clearing the
  pill a moment after a new session sets it) self-heal within one model
  turn because every event re-sets the pill.

## Design notes

- **Why no spinner.** The animated sidebar spinner is gated behind the
  `sidebar-workspace-agent-spinner-experiment` PostHog flag, which
  defaults **off** as of cmux 0.64.x — an in-session experiment
  confirmed `cmux workspace loading on --id polytoken-exp` toggles the
  loader but nothing renders in the sidebar while the flag is off. The
  Claude-style animated tab-title `◐` is composited inside cmux for
  Claude lanes only. Both surfaces are unreachable for a third-party
  status key, so this repo pins only the static pill icon/color.
- **Only blocking events are used.** Fire-and-forget events
  (`post_tool_use`, `post_model_turn`) can complete after a later `stop`
  handler's cmux call and land the pill on the wrong state. Blocking
  events run inline in loop order, so state transitions serialize.
- **The handler never blocks or fails the loop.** On the events used here,
  a hook `error` outcome stops the guarded action entirely. The handler
  therefore always exits `0`, never writes to stdout, and logs failures to
  a file under `$TMPDIR`. A missing or failing cmux binary changes
  nothing about its exit code.
- **No per-call timeout on cmux.** Each cmux invocation is a local
  unix-socket round trip (~ms) and Polytoken enforces a 30 s handler
  deadline; a hung cmux would stall the turn but not corrupt anything.
  This is a deliberate simplicity trade-off (macOS has no `timeout(1)`
  by default and a background-and-kill wrapper adds its own failure
  modes).
- **No dedup state file — re-set the pill on every event.** Pills persist
  until cleared, so this repo owns the full lifecycle: each event sets
  the pill, and reset, session exit, and uninstall clear it. Re-setting
  on every event is kept so a manually cleared pill self-restores on the
  next event (documented behavior). The cmux call is a ~ms local round
  trip at most once per model turn, so there is nothing meaningful to
  dedup.
- **Event payload independence.** The handler ignores the event JSON on
  stdin entirely; the state selector arrives as a CLI argument, so no
  hook payload field names are a dependency.
- **Goal flicker.** `POLYTOKEN_GOAL_ACTIVE` gates `stop`→`Idle` so
  goal-driven sessions don't strobe `Running → Idle → Running` on every
  continued turn (see above).

## Development

```sh
bash tests/run_tests.sh
```

Runs the full unit suite (handler contract, pill values, goal gate,
install/uninstall merge, notifications, watcher) against a fake cmux
shim — nothing touches the real cmux or the real Polytoken config.

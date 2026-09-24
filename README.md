# pt-cmux-notifications

Polytoken hooks that keep the cmux sidebar status pill for Polytoken in
sync with the Polytoken loop, post cmux notifications when the loop is
waiting on you, and provide two pane-arrangement commands
(`pt-cmux-spread`, `pt-cmux-gather`) for organising the workspace around a
running session.

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
  clears the pill *and* any pending notification once they have all
  exited (unless `PTCMUX_NOTIFY=0`). Pills persist until cleared, so this
  is how the pill disappears on quit — and this is what removes a
  summary notification such as "Loop finished — turn handed back to
  you" when the session is closed without another turn to clear it.
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

## Pane arrangement commands

Two user-invoked commands arrange the *panes* of a cmux workspace. They are
installed alongside the hooks and are also registered as `command` actions in
cmux's action registry, so they can be run from the Command Palette (or bound
to a shortcut):

| Command | What it does |
|---|---|
| `pt-cmux-spread` | Leaves the Polytoken tab where it is and moves the tabs running `lazygit` or `croft` into one new split immediately to the right of the Polytoken pane. |
| `pt-cmux-gather` | Collapses every pane of the workspace so that all of its surfaces become tabs of a single pane (the focused one). |

### How a surface is classified

Every terminal surface is classified by the processes running on its tty
(`ps -t <tty>`), matched on the executable's basename:

| Processes on the tty | Class | Effect in spread |
|---|---|---|
| `polytoken` | keep | never moved |
| `lazygit`, `croft` | move | moved into the new split |
| anything else | untouched | left alone |

A tty running **both** `polytoken` and `lazygit`/`croft` counts as keep: a tab
hosting a Polytoken session is never moved. Browser and simulator surfaces
are not classified at all.

### Details, and the deliberate choices

- **The keep pane** is the pane holding the first Polytoken surface in tree
  order. Polytoken tabs in *other* panes are deliberately left alone: spread
  arranges around the first keep pane rather than trying to combine several
  agent panes.
- **Tab order in the new split** is `lazygit` first, then `croft`, preserving
  each tool's existing tab order.
- **Re-running spread converges.** Move-surfaces that sit outside the keep
  pane are moved into it first, which empties — and therefore removes — the
  split a previous run created; the split is then rebuilt. Splits never
  accumulate.
- **Gather's tab order**: the target pane's own tabs first in their existing
  order, then the other panes' tabs in tree order, each pane keeping its own
  order. Every move is placed `--after` the surface moved before it.
- **Gather reports leftovers.** cmux is expected to close a pane when its
  last surface leaves it (there is no `close-pane` command). If a pane
  survives, gather names it in a warning and still exits 0 — the surfaces did
  move.
- **Mutations settle before they are judged.** cmux commits `split-off` and
  `move-surface` asynchronously: a tree read issued right after the call can
  still show the old layout for ~0.1-0.3 s. Both scripts therefore poll the
  tree for the expected post-condition (up to ~5 s after spread's split, ~3 s
  after gather's moves) instead of trusting one re-read. This is not
  defensive padding — a fast command-palette shell reliably lost that race
  (4 of 4 attempts), read the stale tree, concluded the split had never
  happened, and exited 1 with the failure message still on screen, which
  also left the palette's own tab open.
- **Neither command changes focus**: every call passes `--focus false`.
- **Exit codes**: `0` = arranged (or nothing to do); `1` = refused or failed
  (no cmux, no jq, unresolvable workspace, no Polytoken tab for spread, or a
  call failed). The guard paths make no mutating call at all.
- **The palette entry closes its own tab.** `install.sh` registers both
  commands with `--close-when-done`, so the terminal cmux opens for a palette
  invocation closes itself once the command has succeeded — otherwise the tab
  bar would collect one dead tab per invocation. A refusal or error leaves it
  open on purpose, so the message can be read. It closes only when it can
  positively identify the terminal it is running in *and* that terminal is not
  the one hosting the Polytoken session: with `CMUX_SURFACE_ID` unset, or with
  no tty of its own, the close is refused. (A bare `cmux close-surface` closes
  whichever surface is *focused*, which is exactly what must not be guessed.)
  Run detached or under a launcher, the flag is harmless for the same reason.

### Usage

```sh
pt-cmux-spread [--workspace <id|ref|index>] [-n|--dry-run] [--close-when-done] [--debug]
pt-cmux-gather [--workspace <id|ref|index>] [-n|--dry-run] [--close-when-done] [--debug]
```

The workspace is resolved from `--workspace`, else `$CMUX_WORKSPACE_ID`, else
the workspace `cmux identify` reports as focused. `--workspace` takes any of
the forms cmux itself takes — `workspace:3`, the workspace id, or its index —
since cmux's tree carries all three.

`-n`/`--dry-run` prints the planned cmux calls to stdout and changes nothing.
Reading the tree is how a plan gets built, so dry run is read-only rather than
call-free. split-off assigns the new pane ref when it runs, so its follow-up
moves are printed with a placeholder for that ref.

### Triggering them from cmux

`install.sh` registers both commands in the `actions` registry of
`~/.config/cmux/cmux.json`:

```jsonc
"actions": {
  "pt-cmux-spread": {
    "type": "command",
    "title": "Spread: split lg/croft right of polytoken",
    "command": "'…/polytoken/pt-cmux/pt-cmux-spread' --close-when-done"
  },
  "pt-cmux-gather": { "type": "command", "title": "Gather: merge workspace panes", "command": "…" }
}
```

A `command` action runs in a terminal and defaults to a new tab in the current
pane; the command string is shell text, hence the single quotes around the
path. `--close-when-done` then closes that tab again from the script side, so
a palette run leaves nothing behind (see the details above for when it
declines to close). The actions registry is a recent cmux feature (documented
as nightly when this was written); 0.64.25 has it, and older builds simply
never show the entries — the scripts still work when run directly.

Two notes about that merge: it rewrites the file as plain JSON, so the
template's hint comments are gone afterwards (a timestamped `.bak` of the
original is written first, and the file's permissions are carried over), and
re-running the installer leaves the file untouched — no rewrite, no extra
backup — when the actions are already correct.

## Requirements

- cmux with sidebar status pills (`cmux set-status`, 0.64.x)
- Polytoken
- jq — needed by `install.sh`/`uninstall.sh` for the hooks merge, and at run
  time by `pt-cmux-spread`/`pt-cmux-gather`
- python3 — needed by `install.sh`/`uninstall.sh` for the cmux.json (JSONC)
  actions merge

## Install

```sh
./install.sh
```

This installs:

- the handler scripts **and the two arrangement commands** to
  `${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/pt-cmux/`
- the six `cmux-*` hook entries into the global
  `${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/hooks.json`
- the `pt-cmux-spread` / `pt-cmux-gather` entries into the `actions` registry
  of `${XDG_CONFIG_HOME:-$HOME/.config}/cmux/cmux.json`, then reloads the cmux
  configuration

If a global `hooks.json` already exists, the installer **merges**: it
backs the file up to `hooks.json.<timestamp>.<pid>.bak`, removes any
previous `cmux-*` entries, and appends the current ones — unrelated
third-party hooks are preserved, and re-running the installer never
duplicates entries.

The cmux.json step is stricter, because cmux.json is JSONC (it carries
comments and trailing commas). The installer parses it with a small
string-aware reader (python3) and **refuses** — before the hooks or the
scripts are touched — a file it cannot parse, or one whose `actions` is not an
object. It then builds the merged result beside the target and validates that
result with cmux's own `cmux config check`; only when that passes is the file
swapped in, with the original backed up first and its permissions preserved
(cmux.json is commonly `0600`). So a cmux.json problem aborts the install with
nothing installed at all. If cmux.json does not exist yet — cmux writes its
template on first launch — the actions are skipped with a note; re-run the
installer once it exists.

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
hooks remain), removes the `pt-cmux/` script directory (hooks handlers *and*
arrangement commands), drops the `pt-cmux-*` entries from the `actions`
registry of `cmux.json` (foreign actions are preserved, and a config with
nothing of ours in it is not rewritten at all — its comments and formatting
survive), best-effort clears the Polytoken status pill, and reloads the cmux
configuration. It also scrubs the legacy workspace lane pin that the previous
(lane-based) version of this repo could leave behind — per cmux's override
semantics that pin auto-clears on its own once the inferred lane shifts, the
scrub just makes it immediate.

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
   intervals, and any pending notification (e.g. the final "Loop
   finished — turn handed back to you") disappears too. Also record what
   the ancestry walk finds (are hook handlers children of a per-session
   process or of a shared daemon?), and close one of two concurrent
   Polytoken sessions while the other keeps running — if the pill or a
   notification survives, the watcher is watching a shared daemon and the
   per-session PID refinement is needed (see design notes).
8. **Hook load check** → start a new session and submit one prompt; no
   hook-related error or warning should appear in the session's visible
   output surface.
9. **Background-job wake observation** → trigger a user question while a
   background job is running; note whether a `pre_model_turn` wake
   briefly flips the pill back to `Running` (expected to be rare and
   self-healing).

### Verifying the arrangement commands (live)

What the unit suite cannot reach is real cmux behaviour: the test shim models
split/move semantics instead of observing them, and driving the Command
Palette needs a GUI. Run this once in a real workspace and record what you
see.

1. **`cmux tree --json` field names** → `windows[].workspaces[].panes[]` with
   `ref` / `focused` / `surfaces[]`, each surface carrying `ref`, `type`,
   `tty`, `pane_ref`. Confirmed on 0.64.25; if a future build renames them,
   only the jq filters in the two scripts need adjusting.
2. **split-off / move-surface do what the scripts assume** → in a workspace
   with a Polytoken tab and a running `lazygit`, run `pt-cmux-spread` from the
   Polytoken tab. Expect the Polytoken pane untouched and one new split to its
   right holding the lazygit/croft tabs, lazygit first.
3. **Empty panes disappear** (this is an assumption, not an observation yet) →
   re-run spread afterwards: the layout must come back identical, with no
   extra pane, because the previous split loses its last surface. Gather
   should print no `warning: pane(s) still present`. If panes *do* linger, the
   layout stops converging and that is the signal to revisit the approach with
   the operator rather than live with it.
4. **Command Palette execution context and tab cleanup** → `cmd+shift+p`, then
   "Spread: split lg/croft right of polytoken". A `command` action defaults to
   a new tab in the current pane; that tab runs the script, which then closes
   it again with `cmux close-surface --surface $CMUX_SURFACE_ID`. Confirm the
   tab disappears and the arrangement still happened. Then confirm a *failure*
   leaves the terminal open with its message (e.g. run it in a workspace with
   no Polytoken tab). If a successful run leaves the tab behind, check that
   `CMUX_SURFACE_ID` is set in that shell, that the shell has a tty, and that
   `cmux close-surface --surface <id>` works when run by hand there.
5. **Shortcut binding (bonus)** → Settings → Shortcuts should accept the custom
   action IDs `pt-cmux-spread` / `pt-cmux-gather`. If custom IDs cannot be
   bound, palette-only triggering stands and this section is the record of it.
6. **End to end** → open a stray `lazygit` (or `croft`) tab, run spread from
   the palette, then gather. Expect spread to leave a two-pane workspace and
   gather to collapse it back to a single pane.
7. **Focus** → note which surface is focused after each command. Both scripts
   pass `--focus false` on every call, so no moved tab should steal focus; if
   focus lands somewhere surprising, that is a cmux-side default rather than a
   `--focus` decision, and the remedy would be an explicit refocus of the keep
   pane.

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
| `PTCMUX_PS_BIN` | Explicit `ps` binary for the arrangement commands' tty classification, with the same authoritative semantics as `PTCMUX_CMUX_BIN`. |
| `PTCMUX_OWN_TTY` | Override the tty lookup that `--close-when-done` uses to recognise the terminal it is running in. |
| `CMUX_SURFACE_ID` | Set by cmux in the shells it starts; identifies the terminal that `--close-when-done` closes. |
| `CMUX_WORKSPACE_ID` | Workspace the arrangement commands act on when `--workspace` is absent (before falling back to `cmux identify`). |
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
- Notification CLI semantics (observed on cmux 0.64.x): `cmux notify
  --clear` removes our still-*unread* queued notifications **entirely**;
  a notification that has already been read (state `read`, e.g. the user
  glanced at it) survives `notify --clear` and `clear-notifications`,
  staying in `cmux list-notifications` until it is removed with
  `cmux dismiss-notification --id <uuid>` — the id is the *second*
  field of each `list-notifications` row (the same uuid `cmux notify`
  returns as `notification:<uuid>`). This is what the exit watcher's
  `notify --clear` is for: it deletes anything from the last turn that
  is still pending at the moment the session exits.
- The exit watcher: at `session_start` the handler walks its own process
  ancestry (`ps`) and collects every ancestor whose process name mentions
  `polytoken`; the detached watcher polls those PIDs (every
  `PTCMUX_WATCH_INTERVAL` seconds) and clears the status pill once they
  have all exited. It then also runs `cmux notify --clear` (skipped under
  `PTCMUX_NOTIFY=0`), so summary notifications left by the last turn — e.g.
  "Loop finished — turn handed back to you" — do not outlive the session.
  If no Polytoken ancestor can be identified, no watcher starts — the
  next session's reset still clears any stale pill and notification.
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
install/uninstall merge, notifications, watcher, and the arrangement
commands' classification/ordering/guards) against a fake cmux shim — nothing
touches the real cmux, the real Polytoken config, or the real cmux.json.
The arrangement cases run against a *stateful* fake cmux (panes and surfaces,
with `split-off` and `move-surface` modelled) plus a fake `ps`, so the
assertions cover call sequences and resulting layouts. What that harness
cannot reach — real split geometry, whether an emptied pane really disappears,
and how the Command Palette runs an action — is listed in "Verifying the
arrangement commands (live)" above. The install cases parse cmux.json with
python3 and report a skip if python3 is unavailable.

# Usage self-pacing protocol (Linux Mint)

Active only after this session opted in (`--join`, via ~/.claude/CLAUDE.md). When active, a
per-prompt hook silently checks the shared usage and injects guidance ONLY when it matters:
a `[claude-usage] ...` line plus `ACTION` directives. Below the thresholds you see nothing —
work normally; the hook's check is cached and shared across sessions, so it's cheap.

The injected line looks like:
`[claude-usage] 5h 88% (resets in 1h2m / 3720s) | weekly 40% | 3 sessions pacing | save-line 84%`

Manual check (run from any terminal):
```
python3 ~/.claude/usage-pacing/linux/claude-usage.py
python3 ~/.claude/usage-pacing/linux/claude-usage.py --json
```

## The save-line (multi-session aware)
`save-line` is the 5h % at which you must wind down. It TIGHTENS as more sessions pace, because
all paced sessions share ONE account budget and each needs ~one handoff's worth of room to save:
`save-line = 100 - (reserve-per-session x (sessions + 1))`, reserve-per-session = 3% on Pro,
scaled down on Max plans. So with 1 session 94%, 3 sessions 88%, 5 82%.

## What to do on each ACTION
- **`ACTION (5h ..)` notice (5h >= 75%, below save-line):** prefer short, finishable tasks; don't
  start work that clearly won't complete before the save-line.
- **`ACTION SAVE NOW` (5h >= save-line):** finish the current step, write/update `PROGRESS.md`
  in the working dir (goal, what's done, exact next steps, files touched), then pause / hand off.
  Don't overrun — the reserved room is shared by all paced sessions. If you're supervising a fleet,
  also quiesce it here (see **Fleets / background subagents** below).
- **`ACTION (weekly >= 85%)`:** STOP auto-reawakening; do not schedule wakeups; hand off and let
  the user resume manually (a reawakening loop drains the weekly budget fastest). Stop any running
  background subagents/tasks too so they don't keep draining the weekly budget.

## Fleets / background subagents (you are the fleet's pacing controller)
Only THIS main session receives the pacing hook. Background subagents — spawned via the Agent tool
with `run_in_background`, or FleetView/Task tasks — do **NOT** get the hook, do **not** self-pace,
and keep burning the shared 5h budget on their own. Left running they hit the cap and crash
mid-work with no chance to save. So while you're running a fleet, you pace it on their behalf:
- **At the notice-line (`ACTION (5h ..)`):** stop *dispatching new* background work. Let in-flight
  subagents finish, but don't start long fresh ones that can't complete before the save-line. A
  fleet drains the 5h budget far faster than one agent, so treat the notice as real.
- **At `SAVE NOW`, and always before any `SLEEP`:** quiesce the fleet before you stop. `TaskList`
  to see what's running; for each running subagent, `SendMessage` it to checkpoint its progress
  into its own notes, then `TaskStop` it. Record in your `PROGRESS.md` what each subagent was doing
  and how to relaunch it (task, inputs, where it left off). Never leave a background agent running
  into the sleep window — it will hit the cap and die unsaved.
- **On `RESUME` (after the reset):** wake yourself *and the fleet* — re-spawn each paced-down
  subagent (Agent tool) with its remaining work from the checkpoint, or `SendMessage` to continue
  one whose context is still intact, then resume supervising.
This applies to BOTH resume variations: Variation A's forked window starts a fresh session (no live
subagents carry over), so it must re-spawn the fleet from `PROGRESS.md`; Variation B stays in-terminal
but its subagents were `TaskStop`ped before the sleep, so it re-spawns them on `RESUME`.

## Auto-resuming after the 5h reset
The opt-in choice already decides the variation (don't ask again):
- **`Option A` -> Variation A - visible scheduled resume** (`at` job; unattended; opens a new terminal
  window). Arm it at the save-line with `--schedule-resume`.
- **`Option B` -> Variation B - in-harness `/loop` resume** (stays in THIS terminal; attended
  permissions; SAFER). Already relaunched under `/loop` at opt-in.
- **`No` -> no auto-resume** - just hand off at the save-line.
Both Option A and Option B fire ONLY while this terminal stays open and the PC isn't shut down/restarted.

### Switching modes mid-session (the choice is not one-shot)
The opt-in only sets a starting mode; the user can change it anytime. When they ask to switch, run:
```
python3 ~/.claude/usage-pacing/linux/claude-usage.py --set-mode <no|A|B> --session-id <YOUR_ID>
```
and follow the single directive it prints. `--set-mode` always tears down any pending Variation-A
`at` job first (so a stale resume can't fire after you've changed your mind) and persists the new
mode in the session file (`resumeMode`), which is why the SAVE-NOW gate can then name the right
resume command.
- **-> `A`**: pacing on, resume = the `at`-scheduled terminal. Nothing to launch now; arm with
  `--schedule-resume` at the save-line. If you were under `/loop` for B, you can end the loop.
- **-> `B`**: pacing on, resume = in-harness `/loop`. Relaunch the task under `/loop` now (invoke
  the `loop` skill, NO interval) so `ScheduleWakeup` exists at the save-line. Same fallback as
  Option B: if you can't get a working dynamic loop, tell the user or fall back to A.
- **-> `no`**: leave the pool entirely (declined); any pending resume is cancelled. If you were
  under `/loop` for B, end the loop.

### Variation A (visible scheduled resume via 'at')
When you reach the save-line and are about to stop:
0. If you're supervising a fleet, quiesce it first (see **Fleets / background subagents**): stop
   every running background subagent and record in PROGRESS.md how to relaunch each — the forked
   resume window is a fresh session and will re-spawn them from PROGRESS.md, not inherit live ones.
1. If weekly >= 85%, do NOT schedule a resume (weekly budget nearly gone) - just stop.
2. Otherwise run:
   ```
   python3 ~/.claude/usage-pacing/linux/claude-usage.py --schedule-resume \
     --session-id <YOUR_ID> --work-dir <project-dir>
   ```
   (YOUR_ID is in the injected [usage-pacing] line; --work-dir defaults to the current dir if omitted.)
   This registers a one-shot `at` job that at the reset time opens a new terminal window and
   continues this session (forked, so it won't fight the original terminal). No PC wake; it
   self-cancels if the PC was rebooted or the terminal was closed since scheduling. Then tell
   the user the resume time and stop.

Notes: it continues via `claude --resume` (no PROGRESS.md needed), but writing PROGRESS.md is
still good insurance. The resumed run is UNATTENDED (`--dangerously-skip-permissions`) — that's
why it's opt-in. Cancel a pending resume with:
```
python3 ~/.claude/usage-pacing/linux/claude-usage.py --cancel-resume --session-id <YOUR_ID>
```
Requires the `at` daemon: `sudo apt install at && sudo systemctl enable --now atd`

### Variation B (in-harness `/loop` resume) - the safer one
Same goal (pick the work back up after the reset) but with NO `at` job, NO new terminal window,
NO folder-trust flip, and NO `--dangerously-skip-permissions`. The session stays in its own live
terminal and just sleeps until the window resets, then continues with NORMAL permissions.
Cost: it only works while this terminal stays open under `/loop` and the PC stays awake.
Entering B: if the user picked **Option B** at the opt-in, you ALREADY relaunched the task under
`/loop` then (see CLAUDE.md) — you're set. Otherwise you can enter B on request at any time.
Requirements & steps:
1. This session must be running under `/loop` (that's what makes `ScheduleWakeup` available). If it
   isn't, relaunch the task by invoking the `loop` skill (user's task, NO interval), or tell the
   user to type `/loop continue the work`, or fall back to Variation A.
2. At the save-line: write/refresh PROGRESS.md, quiesce your fleet if you have one (TaskStop every
   running background subagent, checkpoint each — they don't sleep with you and would crash on the
   cap), then run:
   ```
   python3 ~/.claude/usage-pacing/linux/claude-usage.py --loop-resume --session-id <YOUR_ID>
   ```
   and DO EXACTLY what the single directive line says:
   - `SLEEP <secs>` -> first confirm the fleet is stopped, then call
     `ScheduleWakeup(delaySeconds=<secs>)` passing the SAME `/loop` prompt back, then end the turn.
     (`<secs>` is already clamped <= 3300; long waits are chained across multiple wakes
     automatically - each wake you just run `--loop-resume` again.)
   - `RESUME` -> the window reset and there's room again: stop sleeping, relaunch your paced-down
     subagents from their checkpoints, and continue the saved work from PROGRESS.md (re-confirm
     pacing for yourself if needed).
   - `STOP` -> weekly is nearly gone: do not keep looping; hand off and let the user resume manually.
   - `WAIT <secs>` -> usage couldn't be read: `ScheduleWakeup(<secs>)` and re-check next wake.
3. On every subsequent `/loop` wake, run `--loop-resume` again and follow its directive.
Note: while sleeping you stay counted in the pacing pool (you'll resume and need save-room too).

**Limitation - B can't bridge a long wait once you're at the hard cap.** `ScheduleWakeup` maxes out
at 3600s and `--loop-resume` sleeps in <=3300s (~55min) hops, so any wait longer than that is chained:
wake, re-run `--loop-resume`, `ScheduleWakeup` again, repeat. Each re-arm hop is itself a model call.
If the 5h usage is ALREADY 100% at an intermediate hop - which happens when the reset is still more
than ~1 hop away AND usage is maxed - that model call is exactly what the cap blocks, so the loop
can't re-arm and never reaches the reset. The single-hop case is safe even at 100% (the one wake is
timed for just after the reset, when the cap has lifted). B is only reliable when you arm it with
headroom (at the save-line, below 100%) and nothing drives usage to 100% during the sleep - which is
another reason to pause the fleet before sleeping. When you're already maxed with a long wait to go,
prefer Variation A: its `at` job fires independently of the model and the rate limit.

Don't ration tokens or downgrade models otherwise — the goal is to pace around the reset and
leave room for every session to save, not to save usage.

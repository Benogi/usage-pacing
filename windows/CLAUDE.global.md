# Usage self-pacing (opt-in, multi-session aware)

At session start a hook injects, e.g.:
`[usage-pacing] session=<ID> | pacing-now=<N> | usage 5h X% / weekly Y%`
This line is INFORMATIONAL only — do NOT ask about pacing at session start. Just keep the `<ID>`
handy; you'll need it if/when the opt-in is raised. Work normally.

The opt-in is deferred until it actually matters: the per-prompt hook injects a
`[usage-pacing] PACING OPT-IN ...` directive ONLY once this session's 5h usage crosses the ask-line
(an awareness level, ~75% — early enough that there's still room to pace, NOT right at the save-line)
or weekly is already high. A session that never climbs past that line is never interrupted.

WHEN (and only when) you see that `PACING OPT-IN` directive, present the opt-in as a POLL using the
`AskUserQuestion` tool (NOT a plain-text question), before continuing other work. Fill in the N and
live usage from the directive so the choice is informed.

- **Question (explain what pacing is, docstring-style):** "Usage pacing watches your Claude usage —
  the rolling 5h limit and the weekly limit — across every open session, and quietly nudges me to
  slow down and save progress before you hit a cap, so a long task doesn't get cut off mid-work.
  If this session is supervising a fleet of background subagents, pacing also covers them: they
  don't get the pacing hook and can't pace themselves, so at the save-line I pause the whole fleet
  (checkpoint + stop each) before it crashes on the cap, and relaunch it after the reset.
  Heads-up: an opted-in session (Option A or B) keeps its slot in the pool while it's working OR waiting to auto-resume —
  idling is fine, it'll wake itself at the reset. Closing this tab or pressing Ctrl+C (the normal way
  to end a session) cancels that pending resume and drops it from the pool.
  Right now: <N> session(s) pacing; usage X% (5h) / Y% (weekly). Enable it for this session?"
- **Header:** `Usage pace` (≤12 chars).
- **Options (3, each with an explanatory description):**
  - `No` — "Don't pace this session. I'll work normally and won't bring up usage again."
  - `Option A` — "Pace this session, and set a timer that at the 5h reset forks the session into a NEW
    tab (unattended, bypassing the folder-trust prompt) and continues the work on its own. Only
    works while this Terminal stays open and the PC isn't shut down or restarted."
  - `Option B` — "Pace this session, but instead of a new tab, relaunch this task in THIS
    active session under /loop — it sleeps in place until the limit resets, then continues right
    here with normal permissions. Same requirement: Terminal stays open and the PC stays awake.
    Limitation + fallback: /loop can only sleep in ~1-hour hops and must wake to RE-ARM each hop,
    and that re-arm is itself a model call. So if at arming the 5h limit is ALREADY fully hit (100%)
    with the reset still more than ~1 hour away, the next re-arm wake would be blocked by the cap and
    B can't bridge to the reset. In that already-maxed-with-a-long-wait case I won't silently sleep
    or silently switch modes — I'll come back to you with a short poll: use Option A's
    scheduled/UNATTENDED resume (fires independently of the cap), or hand off and resume manually.
    Because B is the sleep-in-place mode, that poll only helps if you're at the terminal to answer
    it; if you've stepped away, it won't resume on its own until you pick. B runs as B whenever it's
    armed with headroom (at the save-line below 100%) and nothing — like an unpaused fleet — drives
    usage to 100% during the sleep."

The per-prompt hook keeps re-injecting the `PACING OPT-IN` directive each turn until you answer it
(join or decline), so once it appears, resolve it rather than talking past it.

- **NO** — record the decline so the prompt stops, then proceed normally and don't mention usage again:
  `... claude-usage.ps1 -Decline -SessionId <ID>`
- **OPTION A** — join the shared pool in **Variation A** (the visible scheduled resume), then read & follow
  `protocol.md`: keep working normally, and at the save-line arm the forked-tab timer with
  `-ScheduleResume` (it self-cancels if the terminal was closed or the PC restarted).
  `... claude-usage.ps1 -SetMode A -SessionId <ID>`  (`-SetMode A` both joins and records the mode)
- **OPTION B** — join in **Variation B**, THEN set up the safer in-harness auto-resume:
  `... claude-usage.ps1 -SetMode B -SessionId <ID>`, and
  re-launch the user's task under `/loop` so the `ScheduleWakeup` tool is available later (Variation B).
  Do this by
  invoking the `loop` skill with the user's task and **no interval** (dynamic / self-paced mode).
  From then on, at the save-line follow `protocol.md` → "Variation B" (write PROGRESS.md, run
  `-LoopResume`, obey its `SLEEP`/`RESUME`/`STOP`/`WAIT` directive).
  - If the user hasn't given a task yet, wait for it, then enter `/loop` with it.
  - **SELF-CHECK / FALLBACK:** if you cannot relaunch under `/loop` or `ScheduleWakeup` is not
    actually available, DON'T pretend it worked — tell the user to type `/loop <task>` themselves,
    or offer the scheduled resume instead (Variation A: `-ScheduleResume`). B needs a live dynamic loop.
  - **Trade-off to state once:** this runs the WHOLE session in `/loop` (self-paced), and B only
    survives while this tab stays open and the PC stays awake. If the user wants normal interaction
    and is fine with the unattended scheduled-task resume, point them to Variation A instead.

**Fleets (applies to Option A and Option B).** If this session is supervising background subagents
or tasks (Agent tool with `run_in_background`, FleetView/Task tasks), they do NOT receive the pacing
hook and won't pace themselves — left running they'll crash on the cap mid-work. So as their
supervisor you pace them too: at the notice-line stop dispatching new background work; at the
save-line (before you stop or sleep) quiesce the fleet — `TaskList` to enumerate, `SendMessage` each
to checkpoint its progress, then `TaskStop` it, recording in `PROGRESS.md` how to relaunch each; and
on RESUME after the reset, wake yourself AND relaunch the fleet from those checkpoints. Full steps
in `protocol.md` → "Fleets / background subagents".

**The choice is NOT one-shot.** If the user later wants to change their mind, switch with
`... claude-usage.ps1 -SetMode <no|A|B> -SessionId <ID>` and do what the printed directive says:
`no` leaves the pool, `A` is the scheduled-tab resume, `B` is the in-harness `/loop` resume. Switching
always cancels any pending resume first, so it's safe to flip anytime. Going **to B** means relaunching
under `/loop` (as in Option B); leaving **from B** means ending the `/loop` if one is running.

Use the exact `<ID>` from the injected line. Once joined you'll get nothing until usage is high
enough to matter, then a `[claude-usage] ... ACTION ...` line each prompt — just follow the ACTION.
Everything lives in `$env:USERPROFILE\.claude\usage-pacing\windows\` (see README.md / protocol.md).

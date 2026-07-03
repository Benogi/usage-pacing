# Usage self-pacing (opt-in, multi-session aware)

At session start a hook injects, e.g.:
`[usage-pacing] session=<ID> | pacing-now=<N> | usage 5h X% / weekly Y%`
This line is INFORMATIONAL only — do NOT ask about pacing at session start. Just keep the `<ID>`
handy; you'll need it if/when the opt-in is raised. Work normally.

The opt-in is deferred until it actually matters: the per-prompt hook injects a
`[usage-pacing] PACING OPT-IN ...` directive ONLY once this session's 5h usage crosses the ask-line
(an awareness level, ~75% — early enough that there's still room to pace, NOT right at the save-line)
or weekly is already high. A session that never climbs past that line is never interrupted. That
directive also carries the full path to `claude-usage.py` in its text.

WHEN (and only when) you see that `PACING OPT-IN` directive, present the opt-in as a POLL using the
`AskUserQuestion` tool (NOT a plain-text question), before continuing other work. Fill in the N and
live usage from the directive so the choice is informed.

- **Question (explain what pacing is, docstring-style):** "Usage pacing watches your Claude usage —
  the rolling 5h limit and the weekly limit — across every open session, and quietly nudges me to
  slow down and save progress before you hit a cap, so a long task doesn't get cut off mid-work.
  Heads-up: an opted-in session (Option A or B) keeps its slot in the pool while it's working OR waiting to auto-resume —
  idling is fine, it'll wake itself at the reset. Closing this terminal or pressing Ctrl+C (the
  normal way to end a session) cancels that pending resume and drops it from the pool.
  Right now: <N> session(s) pacing; usage X% (5h) / Y% (weekly). Enable it for this session?"
- **Header:** `Usage pace` (≤12 chars).
- **Options (3, each with an explanatory description):**
  - `No` — "Don't pace this session. I'll work normally and won't bring up usage again."
  - `Option A` — "Pace this session, and schedule a terminal that at the 5h reset forks the session into
    a NEW window (unattended, bypassing the folder-trust prompt) and continues the work on its own.
    Requires the 'at' daemon (sudo apt install at). Only works while this terminal stays open and
    the PC isn't shut down or restarted."
  - `Option B` — "Pace this session, but instead of a new window, relaunch this task in THIS
    active session under /loop — it sleeps in place until the limit resets, then continues right
    here with normal permissions. Same requirement: terminal stays open and the PC stays awake."

The per-prompt hook keeps re-injecting the `PACING OPT-IN` directive each turn until you answer it
(join or decline), so once it appears, resolve it rather than talking past it.

- **NO** — record the decline so the prompt stops, then proceed normally and don't mention usage again:
  `python3 <script> --decline --session-id <ID>`
  (where `<script>` is the path shown in the injected `[usage-pacing]` line)
- **OPTION A** — join the shared pool in **Variation A** (the visible scheduled resume), then read & follow
  `protocol.md`: keep working normally, and at the save-line arm the forked-terminal timer with
  `--schedule-resume` (it self-cancels if the terminal was closed or the PC restarted).
  `python3 <script> --set-mode A --session-id <ID>`  (`--set-mode A` both joins and records the mode)
- **OPTION B** — join in **Variation B**, THEN set up the safer in-harness auto-resume:
  `python3 <script> --set-mode B --session-id <ID>`, and
  re-launch the user's task under `/loop` so the `ScheduleWakeup` tool is available later (Variation B).
  Do this by invoking the `loop` skill with the user's task and **no interval** (dynamic / self-paced mode).
  From then on, at the save-line follow `protocol.md` → "Variation B" (write PROGRESS.md, run
  `--loop-resume`, obey its `SLEEP`/`RESUME`/`STOP`/`WAIT` directive).
  - If the user hasn't given a task yet, wait for it, then enter `/loop` with it.
  - **SELF-CHECK / FALLBACK:** if you cannot relaunch under `/loop` or `ScheduleWakeup` is not
    actually available, DON'T pretend it worked — tell the user to type `/loop <task>` themselves,
    or offer the scheduled resume instead (Variation A: `--schedule-resume`). B needs a live dynamic loop.
  - **Trade-off to state once:** this runs the WHOLE session in `/loop` (self-paced), and B only
    survives while this terminal stays open and the PC stays awake. If the user wants normal interaction
    and is fine with the unattended scheduled resume, point them to Variation A instead.

**The choice is NOT one-shot.** If the user later wants to change their mind, switch with
`python3 <script> --set-mode <no|A|B> --session-id <ID>` and do what the printed directive says:
`no` leaves the pool, `A` is the scheduled-terminal resume, `B` is the in-harness `/loop` resume.
Switching always cancels any pending resume first, so it's safe to flip anytime. Going **to B** means
relaunching under `/loop` (as in Option B); leaving **from B** means ending the `/loop` if one is running.

Use the exact `<ID>` from the injected line. Once joined you'll get nothing until usage is high
enough to matter, then a `[claude-usage] ... ACTION ...` line each prompt — just follow the ACTION.
Everything lives in `~/.claude/usage-pacing/linux/` (see README.md / protocol.md).

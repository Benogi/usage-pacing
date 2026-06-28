# Usage self-pacing (opt-in, multi-session aware)

At session start a hook injects, e.g.:
`[usage-pacing] session=<ID> | pacing-now=<N> | usage 5h X% / weekly Y%`
plus a `FIRST-ACTION REQUIRED` line when the session hasn't yet answered the opt-in.
The injected line also contains the full path to `claude-usage.py` in its text.

This is MANDATORY: your VERY FIRST action of the session must present the opt-in as a POLL using
the `AskUserQuestion` tool (NOT a plain-text question) before doing any other work. Fill in N and
the live usage so the choice is informed.

- **Question (explain what pacing is, docstring-style):** "Usage pacing watches your Claude usage —
  the rolling 5h limit and the weekly limit — across every open session, and quietly nudges me to
  slow down and save progress before you hit a cap, so a long task doesn't get cut off mid-work.
  Heads-up: a Yes session keeps its slot in the pool while it's working OR waiting to auto-resume —
  idling is fine, it'll wake itself at the reset. Closing this terminal or pressing Ctrl+C (the
  normal way to end a session) cancels that pending resume and drops it from the pool.
  Right now: <N> session(s) pacing; usage X% (5h) / Y% (weekly). Enable it for this session?"
- **Header:** `Usage pace` (≤12 chars).
- **Options (3, each with an explanatory description):**
  - `No` — "Don't pace this session. I'll work normally and won't bring up usage again."
  - `Yes` — "Pace this session, and schedule a terminal that at the 5h reset forks the session into
    a NEW window (unattended, bypassing the folder-trust prompt) and continues the work on its own.
    Requires the 'at' daemon (sudo apt install at). Only works while this terminal stays open and
    the PC isn't shut down or restarted."
  - `Yes + resume` — "Pace this session, but instead of a new window, relaunch this task in THIS
    active session under /loop — it sleeps in place until the limit resets, then continues right
    here with normal permissions. Same requirement: terminal stays open and the PC stays awake."

The per-prompt hook RE-INJECTS this directive every turn until you resolve it, so don't defer it.

- **NO** — record the decline so the prompt stops, then proceed normally and don't mention usage again:
  `python3 <script> --decline --session-id <ID>`
  (where `<script>` is the path shown in the injected `[usage-pacing]` line)
- **YES** — join the shared pool in **Variation A** (the visible scheduled resume), then read & follow
  `protocol.md`: keep working normally, and at the save-line arm the forked-terminal timer with
  `--schedule-resume` (it self-cancels if the terminal was closed or the PC restarted).
  `python3 <script> --set-mode A --session-id <ID>`  (`--set-mode A` both joins and records the mode)
- **YES+RESUME** — join in **Variation B**, THEN set up the safer in-harness auto-resume:
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
relaunching under `/loop` (as in YES+RESUME); leaving **from B** means ending the `/loop` if one is running.

Use the exact `<ID>` from the injected line. Once joined you'll get nothing until usage is high
enough to matter, then a `[claude-usage] ... ACTION ...` line each prompt — just follow the ACTION.
Everything lives in `~/.claude/usage-pacing/linux/` (see README.md / protocol.md).

# Usage pacing — Windows 10

See [`../linux/README.md`](../linux/README.md) for the Linux Mint version. See [`../README.md`](../README.md) for the overview.

Makes Claude Code sessions aware of your REAL account usage and coordinate around the shared
5-hour / weekly limits: the opt-in is raised only as a session nears the save-line (not at session
start; shown how many are already pacing), the pool size scales a reserve of "save-room," and every
paced session is told to hand off (PROGRESS.md) early enough that they can all save before the cap.

All state is shared files in this folder, read/written by the per-prompt hook — no daemon.

## Files
- `claude-usage.ps1` - the whole tool. Modes:
    - (default)  formatted report (incl. sessions pacing + save-line)
    - `-Brief`   one-line manual summary
    - `-Json`    machine fields incl. `fiveHourResetSecs`, `sessionsPacing`, `saveLine`, `planMultiplier`
    - `-Watch N` live report
    - `-Raw`     raw endpoint JSON
    - `-SessionStart`  hook: emits `session=<id> | pacing-now=N | usage ...` (reads session_id from stdin)
    - `-Gate`          hook: per-prompt; heartbeats joined sessions, injects when near the save-line
    - `-Join  -SessionId <id>`  opt a session into the pool
    - `-Decline -SessionId <id>`  record a NO answer (resolved, not joined; stops the opt-in prompt)
    - `-SetMode <no|A|B> -SessionId <id>`  switch modes after the opt-in (the choice isn't one-shot):
      `no` leaves the pool, `A` = scheduled-tab resume, `B` = in-harness `/loop` resume. Persists
      `resumeMode`, cancels any pending resume first, and prints one directive for the agent to follow.
    - `-Leave -SessionId <id>`  opt out / clear
    - `-ScheduleResume -SessionId <id> [-WorkDir d] [-Prompt p]`  schedule a visible resume at reset (variation A)
    - `-CancelResume -SessionId <id>`  cancel a pending scheduled resume
    - `-LoopResume -SessionId <id>`  in-harness `/loop` resume (variation B): emits one directive
      (`SLEEP <secs>` / `RESUME` / `STOP` / `WAIT <secs>`) for the agent to act on each wake
- `resume-runner.ps1` - fired by the scheduled task; restart-guard then opens Windows Terminal
- `protocol.md` - behavior the agent follows when joined
- `.usage-cache.json` - shared adaptive usage cache (one API call serves all sessions)
- `sessions\<id>.json` - one per opted-in session: `{ joined, declined, resumeArmed, resumeMode, lastSeen }`
  (the live pool). `resumeArmed` = this session has a pending auto-resume (Variation A scheduled task, or
  Variation B /loop sleep), so it keeps counting toward the pool while idle and is never pruned until it
  fires. `resumeMode` = `A` / `B` / `none`, the chosen resume variation (set at opt-in, changeable via
  `-SetMode`); it lets the SAVE-NOW gate name the right resume command. All writes go through one
  merge-writer so heartbeats preserve `resumeArmed` + `resumeMode`.
- `resume\<id>.json`, `resume\<id>-launch.ps1` - per-pending-resume state (auto-cleaned after firing)
- `../docs/PLAN.md` - design doc; `../docs/HANDOFF.md` - cold-resume entry point (private submodule)

## Auto-resume after the reset (opt-in, visible)
When a paced session hits the save-line it can register a ONE-SHOT Windows Scheduled Task that, at
the exact reset time, opens a VISIBLE Windows Terminal and continues the session via
`claude --resume <id> --fork-session` (forked so it won't fight the still-open original tab).
- Does NOT wake the PC (`WakeToRun` off); `StartWhenAvailable` so it runs after a sleep+wake.
- Self-cancels if the PC was restarted since scheduling (restart-guard in resume-runner.ps1).
- Unattended (`--dangerously-skip-permissions`) -> opt-in only.
- `wt` is launched via `-File` (NEVER a `;`-bearing `-Command` - wt treats `;` as a tab split).
Agent calls `-ScheduleResume`; cancel a pending one with `-CancelResume`. (Variation A.)

### Variation B: in-harness `/loop` resume (safer)
A second, "dumber" resume that avoids the parts of variation A that feel unsafe: NO Scheduled Task,
NO new terminal tab, NO `~/.claude.json` folder-trust flip, NO `--dangerously-skip-permissions`.
The session stays in ITS OWN live tab under `/loop` and sleeps with the harness `ScheduleWakeup`
tool until the 5h window resets, then continues with NORMAL (attended) permissions. The agent runs
`-LoopResume -SessionId <id>` once per wake and gets one directive: `SLEEP <secs>` (ScheduleWakeup
that long, re-pass the same `/loop` prompt, re-check on wake), `RESUME` (window reset - continue the
saved work), `STOP` (weekly >= 85% - hand off), or `WAIT <secs>` (usage unreadable - back off).
`<secs>` is clamped to <= 3300 so longer waits chain across several wakes. Trade-off vs A: B only
works while the tab stays open under `/loop` AND the PC stays awake (a sleeping ScheduleWakeup won't
fire on a powered-off machine), but nothing runs unattended or with elevated trust. See protocol.md.

## Flow
1. `~/.claude/settings.json` `SessionStart` hook injects the session id + current pool + usage as
   INFORMATIONAL context only — the opt-in is NOT asked at session start.
2. The opt-in is deferred until it matters: `-Gate` raises a `[usage-pacing] PACING OPT-IN` directive
   only once this session's 5h usage reaches the **ask-line** (`save-line - AskAheadPct`, default 5%)
   or weekly >= 85%. A session that never nears the cap is never interrupted. `~/.claude/CLAUDE.md`
   then makes the agent present the opt-in as a **poll** (the `AskUserQuestion` tool, not a plain-text
   question), explaining what pacing is and showing the pool + usage. Three options, each describing
   its resume behavior:
   - **No** -> `-Decline` (pace nothing; never mention usage again).
   - **Yes** -> `-SetMode A` (joins + records **Variation A**; at the save-line it arms a forked-tab
     scheduled resume with `-ScheduleResume`).
   - **Yes + resume** -> `-SetMode B` then relaunch the task under `/loop` for **Variation B**.
   Both Yes options need the tab left open + the PC not shut down/restarted; closing/Ctrl+C cancels
   the pending resume and drops the session from the pool. The choice isn't one-shot - the user can
   switch anytime with `-SetMode <no|A|B>` (cancels any pending resume, then re-points the resume path).
3. `UserPromptSubmit` hook runs `-Gate` every prompt: for joined sessions it heartbeats and,
   once 5h hits the save-line (or weekly hits 85%), injects usage + ACTION directives. Silent
   otherwise; declined sessions get nothing.
4. Sessions drop out of the count automatically when their heartbeat goes stale (idle/closed),
   UNLESS `resumeArmed` is set (a pending resume) — those stay counted until the resume fires
   (`Clear-Armed` in resume-runner.ps1) or is cancelled, so their save-room stays reserved.

## The reserve (thinks in tokens, via the plan multiplier)
A handoff costs a ~constant number of tokens; as a % that depends on the plan. The endpoint only
exposes %, but plans are multiples of Pro and the plan is read from `~/.claude/.credentials.json`
(`subscriptionType` / `rateLimitTier`), so:
`save-line = 100 - (3% / planMultiplier) x (pacingSessions + 1)`.
Pro x1 -> 3%/session; Max x5 -> 0.6%; Max x20 -> 0.15%. Unknown/Max-without-"20" assumes x5;
anything unrecognized falls back to x1 (Pro = most conservative). Tune the `$ProReserve` anchor
(default 3) at the top of the script.

## Turn it off / on (without deleting anything)
- **Disable / revert to stock Claude Code:**
  `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\usage-pacing\windows\deactivate.ps1"`
  Strips only our hook entries from `settings.json` (other keys & any unrelated hooks kept) and
  removes our `~/.claude/CLAUDE.md`. Nothing in this folder is deleted.
- **Re-enable:**
  `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\usage-pacing\windows\activate.ps1"`
  Re-adds the hooks and reinstalls `CLAUDE.md` from `CLAUDE.global.md` (the canonical copy here).

Both back up `settings.json` to `settings.json.bak` first, are idempotent, and take effect on the
NEXT session (hooks load at session start). `CLAUDE.global.md` is the source of truth for the
global instructions; edit it, then run activate.ps1 to apply.

## Honest limits
- ADVISORY, not enforced: agents comply via protocol.md; nothing hard-stops a session.
- Single machine sharing `~/.claude`. Concurrent cache writes are harmless (identical data).
- A declined-but-busy session still burns the shared budget; it just doesn't claim save-room.
  Everyone watches the same live %, so joined sessions still trigger their save on time.
- `/api/oauth/usage` is undocumented; all hook paths degrade to silence on failure.
- The script reads the OAuth token read-only; never refreshes/rewrites credentials. On 401,
  open Claude Code once to refresh.

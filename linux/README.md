# Usage pacing — Linux Mint

Linux Mint port of the Windows version (see `../` for the original). Same behaviour: sessions
opt in at start, a shared pool scales a "save-room" reserve, and paced sessions are nudged to
write PROGRESS.md and hand off before the cap. Pacing is ADVISORY — agents comply via protocol.md.

## Prerequisites
- **Python 3** (installed by default on Linux Mint 20/21/22)
- **Claude Code CLI** (`claude` in your PATH)
- **`at` daemon** (Variation A only — the visible scheduled resume):
  ```
  sudo apt install at
  sudo systemctl enable --now atd
  ```
  Variation B (`/loop` resume) has no extra dependencies.

## Quick start
```bash
# Install (idempotent — backs up settings.json and CLAUDE.md first):
bash ~/.claude/usage-pacing/linux/activate.sh

# Uninstall (leaves this folder intact):
bash ~/.claude/usage-pacing/linux/deactivate.sh

# Check current usage manually:
python3 ~/.claude/usage-pacing/linux/claude-usage.py
python3 ~/.claude/usage-pacing/linux/claude-usage.py --json
python3 ~/.claude/usage-pacing/linux/claude-usage.py --watch 10
```

## Files
- `claude-usage.py` — the whole tool. Modes:
    - (default)  formatted report (incl. sessions pacing + save-line)
    - `--brief`  one-line manual summary
    - `--json`   machine fields incl. `fiveHourResetSecs`, `sessionsPacing`, `saveLine`, `planMultiplier`
    - `--watch N` live report
    - `--raw`    raw endpoint JSON
    - `--session-start`  hook: emits `session=<id> | pacing-now=N | usage ...` (reads session_id from stdin)
    - `--gate`           hook: per-prompt; heartbeats joined sessions, injects when near the save-line
    - `--join  --session-id <id>`    opt a session into the pool
    - `--decline --session-id <id>`  record a NO answer (stops the forced opt-in)
    - `--set-mode <no|A|B> --session-id <id>`  switch modes after the opt-in:
      `no` leaves the pool, `A` = at-job resume, `B` = in-harness `/loop` resume.
    - `--leave --session-id <id>`    opt out / clear
    - `--schedule-resume --session-id <id> [--work-dir d] [--prompt p]`  schedule a visible resume (Variation A)
    - `--cancel-resume --session-id <id>`   cancel a pending scheduled resume
    - `--loop-resume --session-id <id>`     in-harness `/loop` resume directive (Variation B)
    - `--loop-resume --test-five PCT`       same, but override 5h usage % with PCT for live B demos
                                            (bypasses the adaptive cache; useful because cache always
                                            refreshes live when five ≥ 75%, so faking a high value
                                            via the cache file doesn't work)
    - `--run-resume <id>`                   internal: called by the `at` job at reset time
- `activate.sh`  / `deactivate.sh` — install / uninstall hooks and CLAUDE.md (idempotent)
- `test-resume.sh` — fire a Variation A test resume in N seconds
- `CLAUDE.global.md` — canonical copy of the global opt-in instructions (source of truth for CLAUDE.md)
- `protocol.md` — behaviour the agent follows when joined
- `.usage-cache.json` — shared adaptive usage cache (one API call serves all sessions)
- `sessions/<id>.json` — one per opted-in session: `{ joined, declined, resumeArmed, resumeMode, lastSeen }`
- `resume/<id>.json`, `resume/<id>-launch.sh` — per-pending-resume state (auto-cleaned after firing)

## Auto-resume after the reset

### Variation A — visible `at`-scheduled resume (requires `at` daemon)
When a paced session hits the save-line it registers a ONE-SHOT `at` job that, at the exact reset
time, opens a new window/tab and continues the session via
`claude --resume <id> --fork-session --dangerously-skip-permissions` (forked so it won't fight
the still-open original terminal).
- **If Oasis GUI is running** (`oasis-gui` process detected): opens the resume in a new tmux
  session, which Oasis auto-detects as a new tab. Requires `tmux` in PATH.
- **Otherwise**: launches a standard terminal emulator (`gnome-terminal`, `xterm`, etc.).
- Does NOT wake the PC; fires only if the PC is running when the `at` timer goes off.
- Self-cancels if the terminal was closed or the PC was rebooted since scheduling (boot-time guard
  + process-alive guard check PID start-tick via `/proc`).
- Unattended (`--dangerously-skip-permissions`) → opt-in only.
Agent calls `--schedule-resume`; cancel with `--cancel-resume`.

### Variation B — in-harness `/loop` resume (safer, no `at` needed)
No `at` job, no new terminal, no folder-trust flip, no `--dangerously-skip-permissions`. The
session stays in its own live terminal under `/loop` and sleeps via the harness `ScheduleWakeup`
tool until the 5h window resets, then continues with NORMAL (attended) permissions. The agent runs
`--loop-resume` once per `/loop` wake and gets one directive: `SLEEP <secs>`, `RESUME`, `STOP`,
or `WAIT <secs>`. Trade-off: B only works while the terminal stays open under `/loop` AND the PC
stays awake. See protocol.md.

## Flow
1. `~/.claude/settings.json` `SessionStart` hook injects the session id + current pool + usage.
2. `~/.claude/CLAUDE.md` makes the agent present the opt-in as a **poll** (the `AskUserQuestion`
   tool, not plain text), explaining pacing and the pool. Three options:
   - **No** → `--decline` (pace nothing; never mention usage again).
   - **Yes** → `--set-mode A` (joins + Variation A; at the save-line arm `--schedule-resume`).
   - **Yes + resume** → `--set-mode B` then relaunch under `/loop` for Variation B.
3. `UserPromptSubmit` hook runs `--gate` every prompt: for joined sessions it heartbeats and,
   once 5h hits the save-line (or weekly hits 85%), injects usage + ACTION directives.
4. Sessions drop from the count when heartbeat goes stale, UNLESS `resumeArmed` is set — those
   stay counted until the resume fires or is cancelled.

## The reserve
`save-line = 100 - (3% / planMultiplier) × (pacingSessions + 1)`.
Pro ×1 → 3%/session; Max ×5 → 0.6%; Max ×20 → 0.15%.

## Turn it off / on
```bash
# Disable (keeps this folder intact):
bash ~/.claude/usage-pacing/linux/deactivate.sh

# Re-enable:
bash ~/.claude/usage-pacing/linux/activate.sh
```
Both back up `settings.json` to `settings.json.bak` first, are idempotent, and take effect on the
NEXT session. `CLAUDE.global.md` is the source of truth; edit it, then run `activate.sh` to apply.

## Honest limits
- ADVISORY, not enforced: agents comply via protocol.md; nothing hard-stops a session.
- Single machine sharing `~/.claude`. Concurrent cache writes are harmless (identical data).
- `/api/oauth/usage` is undocumented; all hook paths degrade to silence on failure.
- Variation A requires `at` and a running display server when the job fires. If the PC is
  sleeping when the `at` job fires, it will NOT run (unlike Windows `StartWhenAvailable`). Use
  Variation B if you cannot guarantee the PC will be awake at the reset time.
- The script reads the OAuth token read-only; never refreshes/rewrites credentials. On 401,
  open Claude Code once to refresh.

# Usage pacing (multi-session)

Makes Claude Code sessions aware of your REAL account usage and coordinate around the shared
5-hour / weekly limits. Each session opts in at start, the pool size scales a "save-room"
reserve, and every paced session is told to hand off early enough that all can save before the
cap. Pacing is ADVISORY — agents comply via `protocol.md`; nothing hard-stops a session.

## Platform versions

| Platform | Folder | Script |
|---|---|---|
| **Windows 10** | [`windows/`](windows/) | `claude-usage.ps1` (PowerShell) |
| **Linux Mint** | [`linux/`](linux/) | `claude-usage.py` (Python 3) |

See the platform README for install steps, file reference, and honest limits:
- [windows/README.md](windows/README.md)
- [linux/README.md](linux/README.md)

## Shared files (at repo root)
- `HANDOFF.md` — session history and cold-resume entry point
- `PLAN.md` — original design rationale

## How it works
1. A `SessionStart` hook injects the session id + current pool size + live usage %.
2. The agent presents a poll (Variation A / B / No) at the start of each session.
3. A `UserPromptSubmit` hook heartbeats joined sessions and injects `ACTION` directives
   when usage approaches the save-line.
4. At the save-line the agent writes `PROGRESS.md` and either schedules a Variation A
   resume (unattended, new window at reset) or sleeps in-harness via Variation B (`/loop`).

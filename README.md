# Claude Code usage pacing

Most usage monitors show you a number. This one makes Claude slow down.

When your session approaches the 5-hour cap, the tool injects `ACTION` directives into Claude Code's context and instructs it to write `PROGRESS.md` and hand off — so work is saved before the limit hits. Across multiple simultaneous sessions, a shared pool scales the reserve so every session gets room to save.

## How it's different

| | Passive monitors | This tool |
|---|---|---|
| Shows current usage | ✓ | ✓ |
| Calculates reset time | ✓ | ✓ |
| Coordinates across sessions | ✗ | ✓ |
| Injects ACTION directives into Claude | ✗ | ✓ |
| Auto-resumes after reset | ✗ | ✓ |

## Demo

**Live usage check** (run manually or via hook):
```
  Claude Code usage  (live from your account)
  ------------------------------------------------------------
  5-hour block [####....................]  16.0%
                resets in 55m (at Mon 18:50 local)
                PACE: on track (~19.6% at reset). Headroom ~90.8%/h.
  7-day window [##......................]  10.0%
                resets in 3d 23h (at Fri 17:00 local)
                PACE: on track (~23.0% at reset). Headroom ~0.9%/h.
  ------------------------------------------------------------
  sessions pacing   1   save-line 94%   (plan x1)
```

**Hook injection at session start** (injected into Claude's context silently):
```
[usage-pacing] session=a1b2c3d4 | pacing-now=2 | usage 5h 81% / weekly 34%
```

**Hook injection when approaching the save-line:**
```
[claude-usage] 5h 88% (resets in 1h2m / 3720s) | weekly 34% | 2 sessions pacing | save-line 84%
ACTION SAVE NOW
```
Claude sees `ACTION SAVE NOW`, finishes the current step, writes `PROGRESS.md`, and stops — with room still left to do so.

## Auto-resume after the reset

Two variations, both opt-in per session:

- **Variation A** — schedules an OS task (Linux `at`, Windows Task Scheduler) that opens a new terminal and runs `claude --resume` at the exact reset time. Unattended; requires the machine to stay on.
- **Variation B** — stays in the current session under `/loop`, sleeps with `ScheduleWakeup` until the reset, then continues with normal permissions. Safer; no new window, no elevated trust.

## Platforms

| Platform | Folder | Script |
|---|---|---|
| **Linux** | [`linux/`](linux/) | `claude-usage.py` (Python 3) |
| **Windows 10** | [`windows/`](windows/) | `claude-usage.ps1` (PowerShell) |

See the platform README for install, file reference, and honest limits:
[linux/README.md](linux/README.md) · [windows/README.md](windows/README.md)

## How it works

1. `SessionStart` hook injects the session id + pool size + live usage % into Claude's context (informational only — no opt-in at start).
2. `UserPromptSubmit` hook raises an opt-in poll (No / Variation A / Variation B) only once the session nears the save-line (or weekly ≥ 85%), so sessions that never approach the cap are never interrupted.
3. Once joined, the same hook heartbeats every prompt and injects `ACTION` directives when usage crosses the save-line.
4. Save-line = `100 - reserve_per_session × (pacing_sessions + 1)`. More sessions pacing → earlier save-line, so all have room.
5. At the save-line: Claude writes `PROGRESS.md` and arms the chosen resume variation.

## License

MIT — see [LICENSE](LICENSE).

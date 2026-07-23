#!/usr/bin/env python3
"""
Real Claude Code usage limits + multi-session pacing. Linux Mint port of claude-usage.ps1.

Reads ~/.claude/.credentials.json and calls the same usage endpoint the in-app /usage uses.
Coordinates sessions through shared files in this directory.

Usage:
  python3 claude-usage.py                          # formatted report
  python3 claude-usage.py --brief                  # one-line summary
  python3 claude-usage.py --json                   # machine-readable JSON
  python3 claude-usage.py --raw                    # raw API JSON
  python3 claude-usage.py --watch N                # live report every N seconds
  python3 claude-usage.py --session-start          # hook: session start
  python3 claude-usage.py --gate                   # hook: per-prompt gate
  python3 claude-usage.py --join --session-id <id>
  python3 claude-usage.py --leave --session-id <id>
  python3 claude-usage.py --decline --session-id <id>
  python3 claude-usage.py --set-mode <no|A|B> --session-id <id>
  python3 claude-usage.py --schedule-resume --session-id <id> [--work-dir <d>] [--prompt <p>]
  python3 claude-usage.py --cancel-resume --session-id <id>
  python3 claude-usage.py --loop-resume --session-id <id>
  python3 claude-usage.py --run-resume <id>        # internal: fired by the at job (Variation A)
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
HOME        = os.path.expanduser('~')
CRED_PATH   = os.path.join(HOME, '.claude', '.credentials.json')
USAGE_URL   = 'https://api.anthropic.com/api/oauth/usage'
CACHE_FILE  = os.path.join(SCRIPT_DIR, '.usage-cache.json')
SESSIONS_DIR = os.path.join(SCRIPT_DIR, 'sessions')
RESUME_DIR  = os.path.join(SCRIPT_DIR, 'resume')

PRO_RESERVE = 3.0   # % of Pro budget reserved per paced session (anchor)
ACTIVE_SEC  = 360   # heartbeat window: session counts as active within this
STALE_SEC   = 86400 # prune UNARMED session files older than this
ARMED_STALE_SEC   = 7200   # armed Variation-B (/loop) cap. A live sleeping B loop re-arms + heartbeats on
                           # every ScheduleWakeup wake, at most one hop (<=3300s) apart; if an armed-B
                           # session hasn't been seen this long it CANNOT be a live loop (tab closed /
                           # crashed / killed) -> phantom, prune it. Kept > one hop + slack.
ARMED_STALE_SEC_A = 21600  # armed Variation-A (scheduled resume) cap. An armed-A session may sit idle with
                           # a frozen lastSeen until its resume fires at the reset (<=5h away) and clears
                           # the flag. Only past a full window + margin (6h) is it a phantom (never fired).
NOTICE_PCT  = 75    # soft-notice threshold (5h%)
ASK_PCT     = 75    # unresolved sessions are asked the opt-in once 5h crosses THIS line — anchored to
                    # awareness (not the save-line) so the ask lands with real room left to pace
ASK_AHEAD_PCT = 5   # safety guard: keep the ask-line at least this far BELOW the save-line, so a tight
                    # reserve never makes us ask and say save-now in the same breath
                    # (so the answer lands before the save-line, not at session start)


# ── ISO date helper ───────────────────────────────────────────────────────────
def _parse_iso(s):
    """Parse ISO 8601 datetime string; handles trailing Z (Python < 3.11 compat)."""
    if s and s.endswith('Z'):
        s = s[:-1] + '+00:00'
    return datetime.datetime.fromisoformat(s)


# ── Credentials / endpoint ────────────────────────────────────────────────────
def get_token():
    if not os.path.exists(CRED_PATH):
        raise RuntimeError(f"Credentials not found at {CRED_PATH}. Is Claude Code logged in?")
    with open(CRED_PATH) as f:
        data = json.load(f)
    token = data.get('claudeAiOauth', {}).get('accessToken')
    if not token:
        raise RuntimeError("No accessToken in credentials file.")
    return token


def get_usage():
    token = get_token()
    headers = {
        'Authorization': f'Bearer {token}',
        'anthropic-beta': 'oauth-2025-04-20',
        'anthropic-version': '2023-06-01',
    }
    req = urllib.request.Request(USAGE_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise RuntimeError("Endpoint returned 401 (token rejected). Open Claude Code once to refresh login.")
        raise RuntimeError(f"Usage request failed (HTTP {e.code}): {e}")
    except Exception as e:
        raise RuntimeError(f"Usage request failed: {e}")


def get_plan_multiplier():
    try:
        with open(CRED_PATH) as f:
            data = json.load(f)
        o = data.get('claudeAiOauth', {})
        hay = (str(o.get('subscriptionType', '')) + ' ' + str(o.get('rateLimitTier', ''))).lower()
        if '20' in hay:  return 20
        if 'max' in hay: return 5
        return 1
    except:
        return 1


# ── Shared adaptive cache ─────────────────────────────────────────────────────
def get_cached_usage():
    """Returns {ok, five, week, five_reset}. Refreshes rarely when far from the limit."""
    now = datetime.datetime.now(datetime.timezone.utc)
    cache = None
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE) as f:
                cache = json.load(f)
        except:
            cache = None

    refresh = True
    if cache:
        try:
            last_five = float(cache['five'])
            interval = 0 if last_five >= 75 else (120 if last_five >= 60 else 600)
            fetched  = _parse_iso(cache['fetchedAtUtc'])
            reset    = _parse_iso(cache['fiveResetsAt'])
            age = (now - fetched).total_seconds()
            if age < interval and now < reset:
                refresh = False
        except:
            refresh = True

    if refresh:
        try:
            u = get_usage()
            new_cache = {
                'fetchedAtUtc': now.isoformat(),
                'five':         float(u['five_hour']['utilization']),
                'week':         float(u['seven_day']['utilization']),
                'fiveResetsAt': u['five_hour']['resets_at'],
            }
            with open(CACHE_FILE, 'w') as f:
                json.dump(new_cache, f)
            return {'ok': True, 'five': new_cache['five'], 'week': new_cache['week'],
                    'five_reset': new_cache['fiveResetsAt']}
        except:
            if cache:
                return {'ok': True, 'five': float(cache['five']), 'week': float(cache['week']),
                        'five_reset': cache['fiveResetsAt']}
            return {'ok': False}

    return {'ok': True, 'five': float(cache['five']), 'week': float(cache['week']),
            'five_reset': cache['fiveResetsAt']}


# ── Session registry ──────────────────────────────────────────────────────────
def _safe_id(id_):
    return re.sub(r'[^A-Za-z0-9_.\-]', '_', id_)


def resolve_session_file(id_):
    return os.path.join(SESSIONS_DIR, f'{_safe_id(id_)}.json')


def get_session_id(explicit=None):
    if explicit:
        return explicit
    try:
        if not sys.stdin.isatty():
            raw = sys.stdin.read().strip()
            if raw:
                data = json.loads(raw)
                return data.get('session_id')
    except:
        pass
    return None


def get_session_record(id_):
    f = resolve_session_file(id_)
    if not os.path.exists(f):
        return None
    try:
        with open(f) as fp:
            return json.load(fp)
    except:
        return None


def write_session_state(id_, **overrides):
    """Merge-writer: preserves every existing field, overrides only what is passed."""
    if not id_:
        return
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    cur = get_session_record(id_) or {}
    rec = {
        'joined':      bool(cur.get('joined',      False)),
        'declined':    bool(cur.get('declined',    False)),
        'resumeArmed': bool(cur.get('resumeArmed', False)),
        'resumeMode':  str(cur.get('resumeMode',  'none')),
        'lastSeen':    datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    rec.update(overrides)
    rec['lastSeen'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with open(resolve_session_file(id_), 'w') as f:
        json.dump(rec, f, indent=2)


def set_heartbeat(id_, joined):
    write_session_state(id_, joined=joined)


def set_resume_armed(id_, armed):
    write_session_state(id_, resumeArmed=armed)


def get_resume_mode(id_):
    rec = get_session_record(id_)
    return str(rec['resumeMode']) if rec and rec.get('resumeMode') else 'none'


def test_joined(id_):
    s = get_session_record(id_)
    return bool(s and s.get('joined'))


def test_resolved(id_):
    s = get_session_record(id_)
    return bool(s and (s.get('joined') or s.get('declined')))


def set_declined(id_):
    write_session_state(id_, joined=False, declined=True, resumeArmed=False, resumeMode='none')


def get_joined_active_count():
    # Count joined sessions active within ACTIVE_SEC OR with a LIVE pending auto-resume armed. Prune
    # dead/phantom files. "Armed" alone is NOT proof a session is alive - trusting it forever is the
    # phantom-session bug: a Variation-B (/loop) session closed uncleanly (tab shut without Ctrl+C,
    # crash, kill) leaves resumeArmed=true with nothing to ever clear it, so it counted toward the pool
    # permanently and tightened every other session's save-line. The variations differ in what backs the
    # armed flag, so pruning is mode-aware:
    #   * Variation A: a scheduled resume + runner is the out-of-band backing; at the reset it fires (or
    #     skips if the tab was closed / rebooted) and ALWAYS clears the flag, self-healing within ~one 5h
    #     window. Phantom only if still armed past ARMED_STALE_SEC_A.
    #   * Variation B: nothing out-of-band backs it - only the live /loop calling loop-resume sets/clears
    #     it, heartbeating at most one ScheduleWakeup hop apart. So an armed-B session older than
    #     ARMED_STALE_SEC is provably dead and is pruned.
    if not os.path.exists(SESSIONS_DIR):
        return 0
    now = datetime.datetime.now(datetime.timezone.utc)
    n = 0
    for fname in os.listdir(SESSIONS_DIR):
        if not fname.endswith('.json'):
            continue
        fpath = os.path.join(SESSIONS_DIR, fname)
        try:
            with open(fpath) as f:
                s = json.load(f)
            last_seen = _parse_iso(s['lastSeen'])
            age = (now - last_seen).total_seconds()
            armed = bool(s.get('resumeArmed'))
            # Per-session staleness ceiling: unarmed -> long STALE_SEC grace; armed -> a mode-specific
            # "is this resume still live?" cap. Unknown/none mode falls to the stricter B cap (B has no
            # out-of-band backing, so defaulting to it clears phantoms fastest).
            if not armed:
                cap = STALE_SEC
            elif s.get('resumeMode') == 'A':
                cap = ARMED_STALE_SEC_A
            else:
                cap = ARMED_STALE_SEC
            if age > cap:
                os.remove(fpath)
                continue
            if s.get('joined') and (age <= ACTIVE_SEC or armed):
                n += 1
        except:
            pass
    return n


def get_save_line(active_count):
    per  = PRO_RESERVE / get_plan_multiplier()
    line = 100 - per * (active_count + 1)
    return max(line, 50.0)


# ── Oasis GUI / tmux integration ─────────────────────────────────────────────
def _is_oasis_running():
    try:
        r = subprocess.run(['pgrep', '-x', 'oasis-gui'], capture_output=True)
        return r.returncode == 0
    except:
        return False


def _open_in_oasis_tmux(launch_path, work_dir):
    """Create a new tmux session; Oasis GUI auto-detects it as a new tab."""
    import random, string
    suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=4))
    session_name = f'claude-resume-{suffix}'
    cmd = ['bash', '-c', f"bash {launch_path!r}; exec bash"]
    r = subprocess.run(
        ['tmux', 'new-session', '-d', '-s', session_name, '-c', work_dir, '-x', '220', '-y', '50'],
        capture_output=True,
    )
    if r.returncode != 0:
        return False, session_name
    subprocess.Popen(
        ['tmux', 'send-keys', '-t', session_name, f'bash {launch_path!r}', 'Enter'],
        close_fds=True,
    )
    return True, session_name


# ── Linux: process detection via /proc ───────────────────────────────────────
def _parse_proc_stat(pid):
    """Parse /proc/<pid>/stat. Returns dict or None."""
    try:
        with open(f'/proc/{pid}/stat') as f:
            content = f.read()
        # comm can contain spaces and parens; use the LAST ')' to split
        comm_end   = content.rfind(')')
        comm_start = content.index('(')
        comm = content[comm_start + 1:comm_end]
        rest = content[comm_end + 2:].split()
        # rest[1]=ppid (field 4), rest[19]=starttime (field 22)
        return {'pid': int(pid), 'comm': comm, 'ppid': int(rest[1]), 'starttime': int(rest[19])}
    except:
        return None


def get_session_host_proc():
    """Walk /proc parent chain to find the claude/node process (session host)."""
    try:
        current = os.getpid()
        last = None
        for _ in range(25):
            stat = _parse_proc_stat(current)
            if not stat:
                break
            last = stat
            if stat['comm'].lower() in ('claude', 'node'):
                return stat
            if stat['ppid'] <= 1:
                break
            current = stat['ppid']
        return last
    except:
        return None


def is_proc_alive(pid, starttime):
    """True if the process with this pid still has the same starttime (PID-reuse safe)."""
    stat = _parse_proc_stat(pid)
    return stat is not None and stat['starttime'] == starttime


# ── Boot time ─────────────────────────────────────────────────────────────────
def get_boot_time():
    """System boot time as Unix timestamp (float)."""
    try:
        with open('/proc/uptime') as f:
            uptime = float(f.read().split()[0])
        return time.time() - uptime
    except:
        return None


# ── Claude project roots ──────────────────────────────────────────────────────
def get_claude_project_roots():
    candidates = []
    if 'CLAUDE_CONFIG_DIR' in os.environ:
        candidates.append(os.path.join(os.environ['CLAUDE_CONFIG_DIR'], 'projects'))
    candidates.append(os.path.join(HOME, '.claude', 'projects'))
    seen, result = set(), []
    for c in candidates:
        if c not in seen and os.path.isdir(c):
            seen.add(c)
            result.append(c)
    return result


def get_session_origin_dir(id_):
    """Recover the cwd a session was started in by scanning its transcript."""
    if not id_:
        return None
    for root in get_claude_project_roots():
        try:
            for dirpath, _, files in os.walk(root):
                if f'{id_}.jsonl' in files:
                    jsonl = os.path.join(dirpath, f'{id_}.jsonl')
                    with open(jsonl) as f:
                        for i, line in enumerate(f):
                            if i >= 40:
                                break
                            try:
                                obj = json.loads(line)
                                if obj.get('cwd'):
                                    return obj['cwd']
                            except:
                                continue
        except:
            pass
    return None


# ── Format helpers ────────────────────────────────────────────────────────────
def secs_to(resets_at):
    try:
        reset = _parse_iso(resets_at)
        if reset.tzinfo is None:
            reset = reset.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        return max(int((reset - now).total_seconds()), 0)
    except:
        return 0


def bar(pct, width=24):
    fill = int(round(max(0.0, min(100.0, pct)) / 100 * width))
    return '#' * fill + '.' * (width - fill)


def format_span(secs):
    if secs <= 0:    return 'now'
    secs = int(secs)
    if secs >= 86400: return f'{secs // 86400}d {(secs % 86400) // 3600}h'
    if secs >= 3600:  return f'{secs // 3600}h {(secs % 3600) // 60}m'
    return f'{secs // 60}m'


# ── Hook modes ────────────────────────────────────────────────────────────────
def show_session_start(sid):
    try:
        id_ = get_session_id(sid)
        n   = get_joined_active_count()
        cu  = get_cached_usage()
        if cu['ok']:
            print(f"[usage-pacing] session={id_} | pacing-now={n} | usage 5h {cu['five']:.0f}% / weekly {cu['week']:.0f}%")
        else:
            print(f"[usage-pacing] session={id_} | pacing-now={n} | usage unavailable")
        # NOTE: the opt-in is NO LONGER forced at session start. It is raised by the per-prompt
        # gate only as the session approaches the save-line (see show_gate), so a session that
        # never gets near the cap is never interrupted. This line is informational context only.
    except:
        pass


def show_gate(sid):
    try:
        id_ = get_session_id(sid)
        if not id_:
            return
        resolved = test_resolved(id_)
        if resolved and not test_joined(id_):
            return  # declined -> silent forever

        cu = get_cached_usage()
        if not cu['ok']:
            return
        f5   = cu['five']
        f7   = cu['week']
        n    = get_joined_active_count()
        save = get_save_line(n)

        # UNRESOLVED session: don't force the opt-in at session start / every prompt anymore.
        # Raise it once 5h crosses the awareness ask-line (ASK_PCT, default 75) — early enough that
        # there's real room left to pace — or when weekly is already high. A session that never climbs
        # past ASK_PCT is never interrupted. The ask-line is clamped to stay ASK_AHEAD_PCT below the
        # save-line, so a tight reserve can never make us ask AT the cap. Below that: silent.
        if not resolved:
            ask_line = min(ASK_PCT, save - ASK_AHEAD_PCT)
            if f5 >= ask_line or f7 >= 85:
                usage = f"{f5:.0f}% (5h) / {f7:.0f}% (weekly)"
                print(
                    f"[usage-pacing] PACING OPT-IN (5h {f5:.0f}% crossed the ask-line {ask_line:.0f}%, with room left before the save-line {save:.0f}%): NOW "
                    f"present the opt-in as a POLL via the AskUserQuestion tool (NOT plain text). Explain that "
                    f"usage pacing watches your 5h + weekly Claude usage across sessions and nudges you to save "
                    f"progress before a cap. If this session is supervising a fleet of background subagents/tasks, "
                    f"add that pacing also pauses them before the cap (they don't pace themselves and would crash "
                    f"mid-work) and relaunches them after the reset. Show: '{n} session(s) currently pacing; usage {usage}; save-line "
                    f"{save:.0f}%.' Also warn: an opted-in (Option A/B) session keeps its pool slot while working OR "
                    f"idling-but-waiting-to-resume (it wakes itself at the reset), but closing the tab / Ctrl+C "
                    f"cancels the pending resume and drops it from the pool. Three options with explanatory "
                    f"descriptions (both Option A and Option B need this terminal left open + the PC not shut "
                    f"down/restarted): 'No' (don't pace, work normally), 'Option A' (pace + schedule a terminal that "
                    f"at the 5h reset forks the session into a NEW window and continues the work = Variation A; "
                    f"requires 'at' daemon), 'Option B' (pace + relaunch the task in THIS session under "
                    f"/loop, sleeping until the reset then continuing here = Variation B). On No run: python3 "
                    f"{SCRIPT_DIR}/claude-usage.py --decline --session-id {id_} | on Option A run: python3 "
                    f"{SCRIPT_DIR}/claude-usage.py --set-mode A --session-id {id_} (then arm --schedule-resume "
                    f"at the save-line) | on Option B run: python3 {SCRIPT_DIR}/claude-usage.py --set-mode "
                    f"B --session-id {id_} then re-launch the task under /loop (see CLAUDE.md). The choice is "
                    f"NOT one-shot - switch later with --set-mode no|A|B."
                )
            return

        set_heartbeat(id_, True)          # liveness (joined session)
        n    = get_joined_active_count()  # recount now that our heartbeat is fresh
        save = get_save_line(n)
        s5   = secs_to(cu['five_reset'])

        at_save = f5 >= save
        at_note = f5 >= NOTICE_PCT
        at_week = f7 >= 85
        if not (at_save or at_note or at_week):
            return

        print(f"[claude-usage] 5h {f5:.0f}% (resets in {format_span(s5)} / {s5}s) | weekly {f7:.0f}% | {n} sessions pacing | save-line {save:.0f}%")
        if at_save:
            print(f"ACTION SAVE NOW (5h {f5:.0f}% >= save-line {save:.0f}%): finish the current step, write/update PROGRESS.md, then pause / hand off. Room is reserved for {n} session(s) to save - don't overrun it. FLEET: if you're supervising background subagents/tasks they do NOT see this hook and will crash on the cap mid-work - quiesce them BEFORE you finalize PROGRESS.md (stops the biggest drain first, and lets PROGRESS.md capture their real state): TaskList to enumerate, tell each (SendMessage) to checkpoint its progress, then TaskStop it, and only THEN write PROGRESS.md recording what each was doing + how to relaunch it after the reset.")
            mode = get_resume_mode(id_)
            if f7 < 85:
                if mode == 'A':
                    print("ACTION RESUME (mode A): arm the visible scheduled resume now - run --schedule-resume --session-id <id> [--work-dir <dir>], then stop.")
                elif mode == 'B':
                    print("ACTION RESUME (mode B): you're under /loop - run --loop-resume --session-id <id> and follow its SLEEP/RESUME/STOP/WAIT directive.")
        elif at_note:
            print(f"ACTION (5h {f5:.0f}%): prefer short, finishable tasks. Save-line {save:.0f}% ({n} session(s) pacing); be ready to write PROGRESS.md and hand off there. If you're supervising a fleet, stop DISPATCHING new background subagents/tasks now (a fleet drains the 5h budget far faster) - let in-flight ones finish but don't start long fresh work that can't complete before the save-line.")
        if at_week:
            print(f"ACTION (weekly {f7:.0f}% >= 85%): STOP auto-reawakening in this session - do NOT schedule wakeups. Stop any background subagents/tasks (TaskList -> TaskStop) so they don't drain the weekly budget. Hand off and let the user resume manually.")
    except:
        pass


# ── Join / Leave / Decline / SetMode ─────────────────────────────────────────
def invoke_join(sid):
    id_ = get_session_id(sid)
    if id_:
        write_session_state(id_, joined=True, declined=False)
        print(f"usage-pacing: joined ({id_})")
    else:
        print("usage-pacing: no session id - not joined")


def invoke_leave(sid):
    id_ = get_session_id(sid)
    if id_:
        f = resolve_session_file(id_)
        if os.path.exists(f):
            os.remove(f)
        print(f"usage-pacing: left ({id_})")


def invoke_decline(sid):
    id_ = get_session_id(sid)
    if id_:
        set_declined(id_)
        print(f"usage-pacing: declined ({id_})")
    else:
        print("usage-pacing: no session id - not declined")


def invoke_set_mode(sid, mode):
    id_ = get_session_id(sid)
    if not id_:
        print("[set-mode] no session id; aborted")
        return
    m = mode.strip().lower()
    if   m in ('a', 'yes'):                   m = 'A'
    elif m in ('b', 'resume', 'yes+resume'):  m = 'B'
    elif m in ('no', 'none', 'off', 'decline'): m = 'no'
    else:
        print(f"[set-mode] unknown mode '{mode}' - use: no | A | B")
        return

    prev_mode = get_resume_mode(id_)
    invoke_cancel_resume(id_, quiet=True)
    from_b = (prev_mode == 'B')

    if m == 'no':
        set_declined(id_)
        msg = "PACING OFF for this session (left the pool); any pending resume cancelled. Don't pace further."
        if from_b:
            msg += " You were in Variation B - if you're running under /loop, end the loop now."
        print(f"[set-mode] {msg}")
        return

    write_session_state(id_, joined=True, declined=False, resumeMode=m, resumeArmed=False)
    if m == 'A':
        print("[set-mode] MODE A (visible scheduled resume via 'at'). Pacing ON. Nothing to launch now; at the save-line arm it with --schedule-resume.")
        if from_b:
            print("[set-mode] (switched from B) If you're running under /loop, you can end the loop - resume will be the 'at'-scheduled path instead.")
    else:
        print("[set-mode] MODE B (in-harness /loop resume). Pacing ON. To be ready, relaunch the task under /loop now (invoke the loop skill, NO interval) so ScheduleWakeup exists at the save-line.")


# ── Variation A: schedule resume via 'at' ────────────────────────────────────
def _find_terminal():
    """Return a terminal emulator command available on this system."""
    for term in ['gnome-terminal', 'x-terminal-emulator', 'tilix', 'xfce4-terminal', 'mate-terminal', 'xterm', 'konsole']:
        r = subprocess.run(['which', term], capture_output=True)
        if r.returncode == 0:
            return term
    return None


def ensure_folder_trusted(work_dir):
    """Set hasTrustDialogAccepted=true for work_dir in ~/.claude.json (same format as Windows)."""
    if not work_dir:
        return
    cfg = os.path.join(HOME, '.claude.json')
    if not os.path.exists(cfg):
        return
    try:
        import shutil
        with open(cfg) as f:
            data = json.load(f)
        projects = data.get('projects')
        if projects is None:
            return
        key = work_dir.replace('\\', '/')
        if key in projects:
            if projects[key].get('hasTrustDialogAccepted'):
                return
            projects[key]['hasTrustDialogAccepted'] = True
        else:
            projects[key] = {'hasTrustDialogAccepted': True}
        shutil.copy2(cfg, cfg + '.bak')
        with open(cfg, 'w') as f:
            json.dump(data, f, indent=2)
    except:
        pass


def invoke_schedule_resume(sid, work_dir=None, prompt=None, in_seconds=0):
    id_ = get_session_id(sid)
    if not id_:
        print("schedule-resume: no session id; aborted")
        return

    origin = get_session_origin_dir(id_)
    if origin:
        if work_dir and work_dir != origin:
            print(f"schedule-resume: overriding --work-dir '{work_dir}' with session origin '{origin}' (required for --resume)")
        work_dir = origin
    if not work_dir:
        work_dir = os.getcwd()

    if not prompt:
        prompt = (
            "Auto-resumed after a usage-limit reset. Continue the previous work from where it stopped. "
            "You are running unattended: do not ask the user questions. Enable usage pacing for yourself, "
            "keep working, and when you approach the cap again run --schedule-resume and stop."
        )

    if in_seconds > 0:
        when = datetime.datetime.now() + datetime.timedelta(seconds=in_seconds)
    else:
        try:
            u = get_usage()
            reset_iso = u['five_hour']['resets_at']
        except Exception as e:
            print(f"schedule-resume: couldn't read reset time; aborted: {e}")
            return
        reset_dt = _parse_iso(reset_iso)
        when = reset_dt.astimezone(tz=None).replace(tzinfo=None) + datetime.timedelta(minutes=1)
        if when < datetime.datetime.now() + datetime.timedelta(seconds=45):
            when = datetime.datetime.now() + datetime.timedelta(seconds=60)

    safe = _safe_id(id_)
    os.makedirs(RESUME_DIR, exist_ok=True)

    hp        = get_session_host_proc()
    display   = os.environ.get('DISPLAY', ':0')
    xauth     = os.environ.get('XAUTHORITY', os.path.join(HOME, '.Xauthority'))
    boot_time = get_boot_time()

    state = {
        'id':             id_,
        'workDir':        work_dir,
        'prompt':         prompt,
        'when':           when.isoformat(),
        'bootTime':       boot_time,
        'display':        display,
        'xauthority':     xauth,
        'hostPid':        hp['pid']       if hp else None,
        'hostStarttime':  hp['starttime'] if hp else None,
        'hostComm':       hp['comm']      if hp else None,
    }
    state_path  = os.path.join(RESUME_DIR, f'{safe}.json')
    launch_path = os.path.join(RESUME_DIR, f'{safe}-launch.sh')

    with open(state_path, 'w') as f:
        json.dump(state, f, indent=2)

    # Shell-safe escaping for the launch script
    def sh_escape(s):
        return "'" + s.replace("'", "'\\''") + "'"

    with open(launch_path, 'w') as f:
        f.write(f"#!/bin/bash\n")
        f.write(f"cd {sh_escape(work_dir)}\n")
        f.write(f"claude --resume {sh_escape(id_)} --fork-session --dangerously-skip-permissions {sh_escape(prompt)}\n")
    os.chmod(launch_path, 0o755)

    # Schedule with 'at'
    this_script = os.path.abspath(__file__)
    at_job_cmd  = f'python3 {sh_escape(this_script)} --run-resume {sh_escape(id_)}\n'

    # Always use an absolute HH:MM time — 'now + N seconds' is not portable across at implementations.
    at_time_str = when.strftime('%H:%M %m/%d/%Y')

    try:
        result = subprocess.run(
            ['at', at_time_str],
            input=at_job_cmd,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            err = (result.stderr or result.stdout).strip()
            raise RuntimeError(f"'at' rejected time '{at_time_str}': {err}")

        job_match = re.search(r'job (\d+)', result.stderr + result.stdout)
        job_id = job_match.group(1) if job_match else None

        if job_id:
            state['atJobId'] = job_id
            with open(state_path, 'w') as f:
                json.dump(state, f, indent=2)

        set_resume_armed(id_, True)
        suffix = f" [at job {job_id}]" if job_id else ""
        print(f"schedule-resume: visible resume set for {when.strftime('%Y-%m-%d %H:%M:%S')} in {work_dir}{suffix}")
    except FileNotFoundError:
        for p in (state_path, launch_path):
            try:
                if os.path.exists(p): os.remove(p)
            except: pass
        print("schedule-resume FAILED: 'at' command not found. Install with: sudo apt install at && sudo systemctl enable --now atd")
    except Exception as e:
        for p in (state_path, launch_path):
            try:
                if os.path.exists(p): os.remove(p)
            except: pass
        print(f"schedule-resume FAILED: {e}")


def invoke_cancel_resume(sid, quiet=False):
    id_ = get_session_id(sid)
    if not id_:
        if not quiet:
            print("cancel-resume: no session id")
        return
    safe       = _safe_id(id_)
    state_path = os.path.join(RESUME_DIR, f'{safe}.json')

    if os.path.exists(state_path):
        try:
            with open(state_path) as f:
                state = json.load(f)
            job_id = state.get('atJobId')
            if job_id:
                subprocess.run(['atrm', str(job_id)], capture_output=True)
        except:
            pass
        try:
            os.remove(state_path)
        except:
            pass

    launch_path = os.path.join(RESUME_DIR, f'{safe}-launch.sh')
    if os.path.exists(launch_path):
        try:
            os.remove(launch_path)
        except:
            pass

    set_resume_armed(id_, False)
    if not quiet:
        print(f"cancel-resume: cleared for {id_}")


# ── Variation A: resume runner (fired by 'at' job) ───────────────────────────
def run_resume(id_):
    """Check guards and open a terminal to continue the session. Called by the at job."""
    safe       = _safe_id(id_)
    state_path = os.path.join(RESUME_DIR, f'{safe}.json')
    launch_path= os.path.join(RESUME_DIR, f'{safe}-launch.sh')

    def clear_armed():
        try:
            sf = resolve_session_file(id_)
            if os.path.exists(sf):
                with open(sf) as f:
                    o = json.load(f)
                o['resumeArmed'] = False
                with open(sf, 'w') as fp:
                    json.dump(o, fp, indent=2)
        except:
            pass

    def cleanup():
        clear_armed()
        for p in (state_path, launch_path):
            try:
                if os.path.exists(p):
                    os.remove(p)
            except:
                pass

    if not os.path.exists(state_path):
        cleanup()
        return

    try:
        with open(state_path) as f:
            s = json.load(f)
    except:
        cleanup()
        return

    # Boot time guard: if the system was rebooted since scheduling, do NOT resume
    cur_boot   = get_boot_time()
    sched_boot = s.get('bootTime')
    if cur_boot and sched_boot and abs(cur_boot - sched_boot) > 30:
        cleanup()
        return

    # Process alive guard: only resume if the session's terminal process is still running
    host_pid  = s.get('hostPid')
    host_st   = s.get('hostStarttime')
    if not host_pid or not is_proc_alive(host_pid, host_st):
        cleanup()
        return

    if not os.path.exists(launch_path):
        cleanup()
        return

    ensure_folder_trusted(s.get('workDir', ''))

    display  = s.get('display', ':0')
    xauth    = s.get('xauthority', os.path.join(HOME, '.Xauthority'))
    work_dir = s.get('workDir', HOME)

    env = os.environ.copy()
    env['DISPLAY']    = display
    env['XAUTHORITY'] = xauth

    # Prefer opening inside Oasis GUI (tmux session it auto-detects as a new tab).
    # Fall back to a standalone terminal emulator if Oasis is not running.
    try:
        if _is_oasis_running():
            ok, sname = _open_in_oasis_tmux(launch_path, work_dir)
            if not ok:
                raise RuntimeError('tmux new-session failed')
        else:
            term = _find_terminal()
            if term == 'gnome-terminal':
                subprocess.Popen(
                    [term, '--working-directory', work_dir, '--',
                     'bash', '-c', f'bash {launch_path!r}; exec bash'],
                    env=env, close_fds=True
                )
            elif term == 'xterm':
                subprocess.Popen(
                    [term, '-e', f'bash -c \'bash {launch_path!r}; exec bash\''],
                    env=env, cwd=work_dir, close_fds=True
                )
            elif term:
                subprocess.Popen(
                    [term, '-e', f'bash -c \'bash {launch_path!r}; exec bash\''],
                    env=env, cwd=work_dir, close_fds=True
                )
            else:
                subprocess.Popen(['bash', launch_path], env=env, cwd=work_dir, close_fds=True)
    except Exception:
        pass

    clear_armed()
    try:
        if os.path.exists(state_path):
            os.remove(state_path)
    except:
        pass


# ── Variation B: in-harness /loop resume ─────────────────────────────────────
def invoke_loop_resume(sid, test_five=None):
    try:
        id_ = get_session_id(sid)
        if test_five is not None:
            far_future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=90)).isoformat()
            cu = {'ok': True, 'five': float(test_five), 'week': 6.0, 'five_reset': far_future}
        else:
            cu  = get_cached_usage()
        if not cu['ok']:
            print("[loop-resume] WAIT 600: usage unavailable - ScheduleWakeup(600) with the same /loop prompt and re-run --loop-resume.")
            return
        if id_:
            set_heartbeat(id_, True)
        f5   = cu['five']
        f7   = cu['week']
        n    = get_joined_active_count()
        save = get_save_line(n)

        if f7 >= 85:
            if id_:
                set_resume_armed(id_, False)
            print(f"[loop-resume] STOP: weekly {f7:.0f}% >= 85% - do NOT keep looping. Stop any background subagents/tasks (TaskList -> TaskStop) so they don't drain the weekly budget, write/refresh PROGRESS.md, end the loop, and let the user resume manually.")
            return
        if f5 < save:
            if id_:
                set_resume_armed(id_, False)
            print(f"[loop-resume] RESUME: 5h {f5:.0f}% < save-line {save:.0f}% - the window reset, room is back. Stop sleeping, RELAUNCH any subagents/tasks you paced down before the sleep (re-spawn from their checkpoints in PROGRESS.md, or SendMessage to continue one whose context is intact), then continue the saved work now.")
            return
        if id_:
            set_resume_armed(id_, True)
        s5    = secs_to(cu['five_reset'])
        multi_hop = (s5 + 60) > 3300   # reset is >1 ScheduleWakeup hop away -> must chain re-arms
        delay = min(s5 + 60, 3300)
        delay = max(delay, 60)
        # Danger case: a chained (multi-hop) wait while already at the hard cap. The next re-arm wake
        # is itself a model call, and a fully-capped 5h window blocks it, so the loop can't bridge to
        # the reset. Single-hop waits are safe (the one wake lands just after the reset). Flag it.
        cap_warn = ""
        if multi_hop and f5 >= 99:
            cap_warn = " WARNING - B CANNOT BRIDGE THIS WAIT: 5h is at the hard cap and the reset is >1 hop (~55min) away, so the NEXT re-arm wake is a model call the cap will block. Do NOT sleep, and do NOT silently arm any resume. By now the pre-sleep steps are done - the fleet is stopped/checkpointed and THEN PROGRESS.md was written - so the work is already halted and saved and this poll is ONLY about how to resume (if you somehow haven't stopped the fleet yet, do that FIRST, before polling). RE-RAISE the choice to the user via an AskUserQuestion poll (header 'B cant bridge'): explain that B's /loop can't sleep through to the reset here (its hourly re-arm is blocked by the cap), and offer TWO options - 'Option A' (the scheduled/UNATTENDED resume, which fires independently of the cap; on pick run --set-mode A --session-id <id> then --schedule-resume --session-id <id> [--work-dir <dir>], tell them the resume time, then stop) and 'Hand off' (write/refresh PROGRESS.md and stop; they resume manually after the reset). Arm A ONLY if they pick it; if they don't answer, nothing resumes (that's the accepted trade for not silently going unattended)."
        print(f"[loop-resume] SLEEP {delay}: 5h {f5:.0f}% still >= save-line {save:.0f}%; ~{s5}s ({format_span(s5)}) to reset. Before you sleep, make sure any background subagents/tasks are STOPPED with progress checkpointed (TaskList -> TaskStop; they don't pause themselves and would burn the cap and crash while you sleep). Then ScheduleWakeup({delay}) with the SAME /loop prompt, and run --loop-resume again on wake.{cap_warn}")
    except:
        print("[loop-resume] WAIT 600: error reading usage - ScheduleWakeup(600) with the same /loop prompt and re-run --loop-resume.")


# ── Brief summary ─────────────────────────────────────────────────────────────
def show_brief():
    try:
        u  = get_usage()
        f5 = float(u['five_hour']['utilization'])
        f7 = float(u['seven_day']['utilization'])
        s5 = secs_to(u['five_hour']['resets_at'])
        line = f"[claude-usage] 5h-block {f5:.0f}% (resets in {format_span(s5)} / {s5}s); 7-day {f7:.0f}%."
        if f5 >= 95:   line += " AT 5h LIMIT."
        elif f5 >= 80: line += " 5h high."
        print(line)
    except:
        pass


# ── Full report ───────────────────────────────────────────────────────────────
def show_window(label, pct, resets_at, window_hours):
    now   = datetime.datetime.now(datetime.timezone.utc)
    reset = _parse_iso(resets_at)
    if reset.tzinfo is None:
        reset = reset.replace(tzinfo=datetime.timezone.utc)
    start      = reset - datetime.timedelta(hours=window_hours)
    to_reset   = (reset - now).total_seconds()
    elapsed    = max((now - start).total_seconds() / 3600, 0.01)
    hrs_left   = max(to_reset / 3600, 0)
    burn       = pct / elapsed
    remaining  = 100 - pct
    sustain    = remaining / hrs_left if hrs_left > 0 else 0
    projected  = min(100.0, pct + burn * hrs_left)
    reset_local = reset.astimezone().strftime('%a %H:%M')

    print(f"  {label:<13}[{bar(pct)}] {pct:5.1f}%")
    print(f"                resets in {format_span(to_reset)} (at {reset_local} local)")
    if pct >= 100:
        print(f"                LIMIT REACHED - wait {format_span(to_reset)}.")
    elif burn > sustain and hrs_left > 0 and burn > 0:
        eta_secs = (remaining / burn) * 3600
        print(f"                PACE: ~{burn:.1f}%/h -> 100% in {format_span(eta_secs)}. Ease to ~{sustain:.1f}%/h.")
    else:
        print(f"                PACE: on track (~{projected:.1f}% at reset). Headroom ~{sustain:.1f}%/h.")


def show_report(raw=False, as_json=False):
    u = get_usage()
    if raw:
        print(json.dumps(u, indent=2))
        return
    if as_json:
        n = get_joined_active_count()
        print(json.dumps({
            'generatedUtc':      datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'fiveHourPct':       u['five_hour']['utilization'],
            'fiveHourReset':     u['five_hour']['resets_at'],
            'fiveHourResetSecs': secs_to(u['five_hour']['resets_at']),
            'sevenDayPct':       u['seven_day']['utilization'],
            'sevenDayReset':     u['seven_day']['resets_at'],
            'sevenDayResetSecs': secs_to(u['seven_day']['resets_at']),
            'opusPct':           (u.get('seven_day_opus')   or {}).get('utilization'),
            'sonnetPct':         (u.get('seven_day_sonnet') or {}).get('utilization'),
            'sessionsPacing':    n,
            'saveLine':          get_save_line(n),
            'planMultiplier':    get_plan_multiplier(),
        }, indent=2))
        return
    print()
    print("  Claude Code usage  (live from your account)")
    print("  " + "-" * 60)
    if u.get('five_hour') and u['five_hour'].get('utilization') is not None:
        show_window('5-hour block', float(u['five_hour']['utilization']), u['five_hour']['resets_at'], 5)
    if u.get('seven_day') and u['seven_day'].get('utilization') is not None:
        show_window('7-day window', float(u['seven_day']['utilization']), u['seven_day']['resets_at'], 168)
    n = get_joined_active_count()
    print("  " + "-" * 60)
    print(f"  sessions pacing   {n}   save-line {get_save_line(n):.0f}%   (plan x{get_plan_multiplier()})")
    print()


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    p = argparse.ArgumentParser(description='Claude Code usage pacing - Linux Mint')
    p.add_argument('--session-start',    action='store_true')
    p.add_argument('--gate',             action='store_true')
    p.add_argument('--join',             action='store_true')
    p.add_argument('--leave',            action='store_true')
    p.add_argument('--decline',          action='store_true')
    p.add_argument('--set-mode',         metavar='MODE')
    p.add_argument('--schedule-resume',  action='store_true')
    p.add_argument('--cancel-resume',    action='store_true')
    p.add_argument('--loop-resume',      action='store_true')
    p.add_argument('--test-five',        type=float, default=None, metavar='PCT', help='Override 5h usage % for testing --loop-resume')
    p.add_argument('--run-resume',       metavar='ID',   help='Internal: fired by at job')
    p.add_argument('--session-id',       metavar='ID')
    p.add_argument('--work-dir',         metavar='DIR')
    p.add_argument('--prompt',           metavar='TEXT')
    p.add_argument('--in-seconds',       type=int, default=0)
    p.add_argument('--brief',            action='store_true')
    p.add_argument('--json',             action='store_true', dest='as_json')
    p.add_argument('--raw',              action='store_true')
    p.add_argument('--watch',            type=int, default=0, metavar='N')
    args = p.parse_args()

    if   args.run_resume:      run_resume(args.run_resume)
    elif args.session_start:   show_session_start(args.session_id)
    elif args.join:            invoke_join(args.session_id)
    elif args.leave:           invoke_leave(args.session_id)
    elif args.decline:         invoke_decline(args.session_id)
    elif args.set_mode:        invoke_set_mode(args.session_id, args.set_mode)
    elif args.schedule_resume: invoke_schedule_resume(args.session_id, args.work_dir, args.prompt, args.in_seconds)
    elif args.cancel_resume:   invoke_cancel_resume(args.session_id)
    elif args.loop_resume:     invoke_loop_resume(args.session_id, args.test_five)
    elif args.gate:            show_gate(args.session_id)
    elif args.brief:           show_brief()
    elif args.watch > 0:
        while True:
            try:
                os.system('clear')
                show_report()
            except Exception as e:
                print(f"  {e}")
            print(f"  refreshing every {args.watch}s - Ctrl+C to stop")
            time.sleep(args.watch)
    else:
        show_report(raw=args.raw, as_json=args.as_json)


if __name__ == '__main__':
    main()

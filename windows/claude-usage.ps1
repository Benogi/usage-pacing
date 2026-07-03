<#
.SYNOPSIS
    Real Claude Code usage limits (same data as /usage) + multi-session pacing.

.DESCRIPTION
    Reads the OAuth token in ~/.claude/.credentials.json and calls the account usage
    endpoint (GET https://api.anthropic.com/api/oauth/usage) the in-app /usage uses.
    Coordinates multiple sessions through shared files in this folder:
      .usage-cache.json     - adaptively-cached usage reading (shared by all sessions)
      sessions\<id>.json     - one per opted-in session: { joined, lastSeen }

    Pacing is ADVISORY: the script computes a save-line; the agents comply via protocol.md.
    Nothing here hard-stops a session. /api/oauth/usage is undocumented and may change;
    every hook path degrades to silence on failure so a prompt is never blocked.

.PARAMETER (default)   Formatted report.
.PARAMETER Brief       One-line summary (manual).
.PARAMETER Json / Raw  Machine output.
.PARAMETER Watch N     Live report every N seconds.
.PARAMETER Gate        Per-prompt hook: heartbeat + threshold/reserve-gated injection (reads
                       session_id from stdin, or -SessionId).
.PARAMETER SessionStart Session-start hook: emits "session=<id> | pacing-now=N | usage ...".
.PARAMETER Join/Leave  Opt this session in/out (-SessionId required).
#>
[CmdletBinding()]
param(
    [int]    $Watch = 0,
    [switch] $Json,
    [switch] $Raw,
    [switch] $Brief,
    [switch] $Gate,
    [switch] $SessionStart,
    [switch] $Join,
    [switch] $Leave,
    [switch] $Decline,
    [switch] $ScheduleResume,
    [switch] $CancelResume,
    [switch] $LoopResume,
    [string] $SetMode,
    [string] $SessionId,
    [string] $WorkDir,
    [string] $Prompt,
    [int]    $InSeconds = 0
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CredPath     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'
$CacheFile    = Join-Path $PSScriptRoot '.usage-cache.json'
$SessionsDir  = Join-Path $PSScriptRoot 'sessions'
$ResumeDir    = Join-Path $PSScriptRoot 'resume'
$ProReserve   = 3.0      # %-of-Pro-budget reserved per paced session (one handoff). Anchor.
$ActiveSec    = 360      # a session counts as "active" if seen within this many seconds
$StaleSec     = 86400    # session files older than this are pruned
$NoticePct    = 75       # soft awareness threshold (5h%)
$AskPct       = 75       # unresolved sessions are asked the opt-in once 5h usage crosses THIS line.
                         # Anchored to awareness (not the save-line) so the ask lands with real room
                         # left to actually pace, instead of arriving right at the cap.
$AskAheadPct  = 5        # safety guard: the ask-line is always kept at least this far BELOW the
                         # save-line, so on tight (many-session / low-mult) reserves you're never
                         # asked and told to save-now in the same breath.

# --- credentials / endpoint -------------------------------------------------
function Get-Token {
    if (-not (Test-Path $CredPath)) { throw "Credentials not found at $CredPath. Is Claude Code logged in?" }
    $oauth = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
    if (-not $oauth.accessToken) { throw "No accessToken in credentials file." }
    return $oauth.accessToken
}

function Get-Usage {
    $tok = Get-Token
    $headers = @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20'; 'anthropic-version' = '2023-06-01' }
    try {
        return Invoke-RestMethod -Uri $UsageUrl -Headers $headers -Method Get -TimeoutSec 20
    } catch {
        $code = $null; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) { throw "Endpoint returned 401 (token rejected). Open Claude Code once to refresh login." }
        throw "Usage request failed$(if($code){" (HTTP $code)"}): $($_.Exception.Message)"
    }
}

function Get-PlanMultiplier {
    # Plans are multiples of Pro; reserve %/session = ProReserve / multiplier.
    try {
        $o = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
        $hay = (("" + $o.subscriptionType) + " " + ("" + $o.rateLimitTier)).ToLower()
        if ($hay -match '20')  { return 20 }
        if ($hay -match 'max') { return 5 }   # max-without-explicit-20 -> assume 5x
        return 1                               # pro / default_claude_ai
    } catch { return 1 }
}

# --- shared adaptive cache (account-wide; one file for all sessions) ---------
function Get-CachedUsage {
    # Returns @{ ok; five; week; fiveReset }. Refreshes rarely when far from the limit,
    # every call once near it; forces a refresh after the 5h window resets. Never throws.
    $nowDto = [datetimeoffset]::UtcNow
    $cache = $null
    if (Test-Path $CacheFile) { try { $cache = Get-Content $CacheFile -Raw | ConvertFrom-Json } catch { $cache = $null } }
    $refresh = $true
    if ($cache) {
        try {
            $lastFive = [double]$cache.five
            $interval = if ($lastFive -ge 75) { 0 } elseif ($lastFive -ge 60) { 120 } else { 600 }
            $age   = ($nowDto - [datetimeoffset]::Parse($cache.fetchedAtUtc)).TotalSeconds
            $reset = [datetimeoffset]::Parse($cache.fiveResetsAt)
            if ($age -lt $interval -and $nowDto -lt $reset) { $refresh = $false }
        } catch { $refresh = $true }
    }
    if ($refresh) {
        try {
            $u = Get-Usage
            $obj = [pscustomobject]@{
                fetchedAtUtc = $nowDto.ToString('o'); five = [double]$u.five_hour.utilization
                week = [double]$u.seven_day.utilization; fiveResetsAt = $u.five_hour.resets_at
            }
            $obj | ConvertTo-Json | Set-Content -Path $CacheFile -Encoding UTF8
            return @{ ok = $true; five = $obj.five; week = $obj.week; fiveReset = $obj.fiveResetsAt }
        } catch {
            if ($cache) { return @{ ok = $true; five = [double]$cache.five; week = [double]$cache.week; fiveReset = $cache.fiveResetsAt } }
            return @{ ok = $false }
        }
    }
    return @{ ok = $true; five = [double]$cache.five; week = [double]$cache.week; fiveReset = $cache.fiveResetsAt }
}

# --- session registry -------------------------------------------------------
function Resolve-SessionFile { param([string]$Id) Join-Path $SessionsDir ("{0}.json" -f ($Id -replace '[^A-Za-z0-9_.-]','_')) }

function Get-SessionId {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) { $p = $raw | ConvertFrom-Json; if ($p.session_id) { return [string]$p.session_id } }
        }
    } catch { }
    return $null
}

# Candidate roots where Claude Code keeps per-project transcripts. We don't hardcode one location:
# Claude honors $CLAUDE_CONFIG_DIR (and the home dir varies by user/OS), so we build a deduped,
# preference-ordered list of "<config-dir>/projects" candidates and let the caller search them.
function Get-ClaudeProjectRoots {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $HOME }
    $candidates = @(
        $env:CLAUDE_CONFIG_DIR,                 # explicit override wins
        (Join-Path $homeDir '.claude'),         # default on this account
        (Join-Path $HOME '.claude'),            # PS $HOME (may differ from USERPROFILE)
        (Join-Path $env:APPDATA 'claude')       # alt layout some installs use
    ) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'projects' }
    $candidates | Where-Object { Test-Path $_ } | Select-Object -Unique
}

# The directory a session was started in (its "project" cwd). `claude --resume <id>` is scoped to
# the current dir's project, so a resume MUST run from this origin dir or it fails with
# "No conversation found with session ID". We recover it from the session's transcript: Claude stores
# history at <config-dir>/projects/<encoded-cwd>/<id>.jsonl, and each record carries the real `cwd`
# (the encoded folder name is lossy, so we read cwd from the file rather than decode the name).
# We SEARCH all known project roots rather than assuming a fixed path.
function Get-SessionOriginDir {
    param([string]$Id)
    if (-not $Id) { return $null }
    foreach ($root in (Get-ClaudeProjectRoots)) {
        try {
            $jsonl = Get-ChildItem $root -Recurse -Filter "$Id.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $jsonl) { continue }
            foreach ($line in (Get-Content $jsonl.FullName -TotalCount 40)) {
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ($o.cwd) { return [string]$o.cwd }
            }
        } catch { }
    }
    return $null
}

# Read this session's record (or $null if none / unreadable).
function Get-SessionRecord {
    param([string]$Id)
    $f = Resolve-SessionFile $Id
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { return $null }
}

# Merge-write the session file: keep every existing field, override only the keys passed in $Set,
# and always refresh lastSeen. This is what preserves resumeArmed + resumeMode across the per-prompt
# heartbeat rewrites (each prompt rewrites this file, so partial writers would otherwise drop them).
function Write-SessionState {
    param([string]$Id, [hashtable]$Set)
    if (-not $Id) { return }
    if (-not (Test-Path $SessionsDir)) { New-Item -ItemType Directory -Force -Path $SessionsDir | Out-Null }
    $cur = Get-SessionRecord $Id
    $rec = [ordered]@{
        joined      = if ($cur) { [bool]$cur.joined } else { $false }
        declined    = if ($cur) { [bool]$cur.declined } else { $false }
        resumeArmed = if ($cur) { [bool]$cur.resumeArmed } else { $false }
        resumeMode  = if ($cur -and $cur.resumeMode) { [string]$cur.resumeMode } else { 'none' }
        lastSeen    = [datetimeoffset]::UtcNow.ToString('o')
    }
    if ($Set) { foreach ($k in $Set.Keys) { $rec[$k] = $Set[$k] } }
    $rec['lastSeen'] = [datetimeoffset]::UtcNow.ToString('o')
    [pscustomobject]$rec | ConvertTo-Json | Set-Content -Path (Resolve-SessionFile $Id) -Encoding UTF8
}

function Set-Heartbeat {
    param([string]$Id, [bool]$Joined)
    Write-SessionState -Id $Id -Set @{ joined = $Joined }
}

# Mark/clear this session as having a PENDING auto-resume (Variation A scheduled task, or Variation B
# /loop sleep). An armed session keeps counting toward the pool even while idle past $ActiveSec,
# because it WILL wake itself at the reset and needs save-room reserved for it. Preserves joined + mode.
function Set-ResumeArmed {
    param([string]$Id, [bool]$Armed)
    Write-SessionState -Id $Id -Set @{ resumeArmed = $Armed }
}

# The current persisted resume variation for this session: 'A', 'B', or 'none'.
function Get-ResumeMode {
    param([string]$Id)
    $cur = Get-SessionRecord $Id
    if ($cur -and $cur.resumeMode) { return [string]$cur.resumeMode } else { return 'none' }
}

function Test-Joined {
    param([string]$Id)
    $s = Get-SessionRecord $Id
    if (-not $s) { return $false }
    return [bool]$s.joined
}

# A session is "resolved" once the user has answered the opt-in either way (joined OR declined).
# Until then the gate FORCES the question on every prompt (see Show-Gate).
function Test-Resolved {
    param([string]$Id)
    $s = Get-SessionRecord $Id
    if (-not $s) { return $false }
    return [bool]($s.joined -or $s.declined)
}

function Set-Declined {
    param([string]$Id)
    Write-SessionState -Id $Id -Set @{ joined = $false; declined = $true; resumeArmed = $false; resumeMode = 'none' }
}

# Identify THIS session's live terminal process by walking up the parent chain to the nearest
# claude(node) process (the session), else the WindowsTerminal host, else the top ancestor.
# A scheduled resume records this PID + start time and only fires if it's still alive -> closing
# the terminal (or shutting down) means "I'm done" and cancels the pending resume.
function Get-SessionHostProc {
    try {
        $procs = @{}
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
        $cur = $PID; $claude = $null; $wt = $null; $last = $null
        for ($i = 0; $i -lt 25 -and $cur -and $procs.ContainsKey($cur); $i++) {
            $p = $procs[$cur]; $last = $p
            $n = "$($p.Name)".ToLower()
            if (-not $claude -and ($n -eq 'claude.exe' -or $n -eq 'node.exe')) { $claude = $p }
            if (-not $wt     -and  $n -eq 'windowsterminal.exe')              { $wt = $p }
            $cur = [int]$p.ParentProcessId
        }
        if ($claude) { return $claude } elseif ($wt) { return $wt } else { return $last }
    } catch { return $null }
}

function Get-JoinedActiveCount {
    # Count joined sessions that are active within $ActiveSec OR have a pending auto-resume armed
    # (idle-but-hooked-to-resume sessions still need reserved save-room). Prune stale, unarmed files.
    if (-not (Test-Path $SessionsDir)) { return 0 }
    $nowDto = [datetimeoffset]::UtcNow
    $n = 0
    foreach ($file in (Get-ChildItem -Path $SessionsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $s = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $age = ($nowDto - [datetimeoffset]::Parse($s.lastSeen)).TotalSeconds
            # Never prune a session with a pending resume out from under it; otherwise prune when stale.
            if ($age -gt $StaleSec -and -not $s.resumeArmed) { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue; continue }
            if ($s.joined -and ($age -le $ActiveSec -or $s.resumeArmed)) { $n++ }
        } catch { }
    }
    return $n
}

function Get-SaveLine {
    # Hold back ProReserve/mult per active paced session + 1 buffer, so all can save.
    param([int]$ActiveCount)
    $per = $ProReserve / (Get-PlanMultiplier)
    $line = 100 - $per * ($ActiveCount + 1)
    if ($line -lt 50) { $line = 50 }
    return $line
}

# --- formatting helpers -----------------------------------------------------
function Secs-To { param([string]$ResetsAt, [datetime]$NowUtc) [int][math]::Max(([datetimeoffset]::Parse($ResetsAt).UtcDateTime - $NowUtc).TotalSeconds, 0) }
function Bar { param([double]$Pct,[int]$Width=24) $fill=[int][math]::Round([math]::Max(0,[math]::Min(100,$Pct))/100*$Width); ('#'*$fill)+('.'*($Width-$fill)) }
function PctColor { param([double]$Pct) if ($Pct -ge 90){'Red'}elseif($Pct -ge 70){'Yellow'}else{'Green'} }
function Format-Span {
    param([timespan]$Ts)
    if ($Ts.TotalSeconds -le 0) { return 'now' }
    # NOTE: PowerShell [int] ROUNDS to nearest (unlike C#/Python truncation), so [int]$Ts.TotalHours
    # on a 4h31m span yields 5 -> a phantom "+1h". Floor the .Total* values so the leading unit is
    # truncated to match the trailing component (.Hours/.Minutes are already truncated integer parts).
    if ($Ts.TotalHours -ge 24)  { return ('{0}d {1}h' -f [int][math]::Floor($Ts.TotalDays),  $Ts.Hours) }
    if ($Ts.TotalHours -ge 1)   { return ('{0}h {1}m' -f [int][math]::Floor($Ts.TotalHours), $Ts.Minutes) }
    return ('{0}m' -f [int][math]::Floor($Ts.TotalMinutes))
}

# --- hook modes -------------------------------------------------------------
# Session-start: emit the session id + how many OTHER sessions are pacing + usage,
# so the agent can ask an informed opt-in question.
function Show-SessionStart {
    param([string]$Sid)
    try {
        $id = Get-SessionId -Explicit $Sid
        $n  = Get-JoinedActiveCount
        $cu = Get-CachedUsage
        if ($cu.ok) {
            Write-Output ("[usage-pacing] session={0} | pacing-now={1} | usage 5h {2:N0}% / weekly {3:N0}%" -f $id, $n, $cu.five, $cu.week)
        } else {
            Write-Output ("[usage-pacing] session={0} | pacing-now={1} | usage unavailable" -f $id, $n)
        }
        # NOTE: the opt-in is NO LONGER forced at session start. It is raised by the per-prompt
        # gate only as the session approaches the save-line (see Show-Gate), so a session that
        # never gets near the cap is never interrupted. This line is informational context only.
    } catch { }
}

# Per-prompt: only acts for opted-in sessions; heartbeats; injects when near the save-line
# (which tightens as more sessions pace) or weekly >= 85%. Silent otherwise. Never throws.
function Show-Gate {
    param([string]$Sid)
    try {
        $id = Get-SessionId -Explicit $Sid
        if (-not $id) { return }
        $resolved = Test-Resolved $id
        if ($resolved -and -not (Test-Joined $id)) { return }   # declined -> silent forever

        $cu = Get-CachedUsage
        if (-not $cu.ok) { return }
        $f5 = [double]$cu.five; $f7 = [double]$cu.week
        $n  = Get-JoinedActiveCount
        $save = Get-SaveLine -ActiveCount $n

        # UNRESOLVED session: don't force the opt-in at session start / every prompt anymore.
        # Raise it once 5h crosses the awareness ask-line (AskPct, default 75) - early enough that
        # there's real room left to pace - or when weekly is already high. A session that never
        # climbs past AskPct is never interrupted. The ask-line is also clamped to stay at least
        # AskAheadPct below the save-line, so a tight reserve can never make us ask AT the cap.
        if (-not $resolved) {
            $askLine = [math]::Min($AskPct, $save - $AskAheadPct)
            if ($f5 -ge $askLine -or $f7 -ge 85) {
                $usage = ("{0:N0}% (5h) / {1:N0}% (weekly)" -f $f5, $f7)
                Write-Output ("[usage-pacing] PACING OPT-IN (5h {5:N0}% crossed the ask-line {4:N0}%, with room left before the save-line {3:N0}%): NOW present the opt-in as a POLL via the AskUserQuestion tool (NOT plain text). Explain that usage pacing watches your 5h + weekly Claude usage across sessions and nudges you to save progress before a cap. Show: '{0} session(s) currently pacing; usage {1}; save-line {3:N0}%.' Also warn: an opted-in (Option A/B) session keeps its pool slot while working OR idling-but-waiting-to-resume (it wakes itself at the reset), but closing the tab / Ctrl+C cancels the pending resume and drops it from the pool. Three options with explanatory descriptions (both Option A and Option B need this Terminal left open + the PC not shut down/restarted): 'No' (don't pace, work normally), 'Option A' (pace + at the 5h reset fork the session into a NEW tab, bypassing folder trust, and continue the work = Variation A), 'Option B' (pace + relaunch the task in THIS session under /loop, sleeping until the reset then continuing here = Variation B). On No run: claude-usage.ps1 -Decline -SessionId {2} | on Option A run: claude-usage.ps1 -SetMode A -SessionId {2} (then arm -ScheduleResume at the save-line) | on Option B run: claude-usage.ps1 -SetMode B -SessionId {2} then re-launch the task under /loop (see CLAUDE.md). The choice is NOT one-shot - switch later with -SetMode no|A|B." -f $n, $usage, $id, $save, $askLine, $f5)
            }
            return
        }

        Set-Heartbeat -Id $id -Joined $true        # liveness (joined session)
        $n    = Get-JoinedActiveCount              # recount now that our heartbeat is fresh
        $save = Get-SaveLine -ActiveCount $n
        $nowUtc = [datetime]::UtcNow
        $s5 = Secs-To $cu.fiveReset $nowUtc

        $atSave = $f5 -ge $save
        $atNote = $f5 -ge $NoticePct
        $atWeek = $f7 -ge 85
        if (-not ($atSave -or $atNote -or $atWeek)) { return }

        Write-Output ("[claude-usage] 5h {0:N0}% (resets in {1} / {2}s) | weekly {3:N0}% | {4} sessions pacing | save-line {5:N0}%" -f $f5,(Format-Span ([timespan]::FromSeconds($s5))),$s5,$f7,$n,$save)
        if ($atSave) {
            Write-Output ("ACTION SAVE NOW (5h {0:N0}% >= save-line {1:N0}%): finish the current step, write/update PROGRESS.md, then pause / hand off. Room is reserved for {2} session(s) to save - don't overrun it." -f $f5,$save,$n)
            switch (Get-ResumeMode $id) {
                'A' { if ($f7 -lt 85) { Write-Output "ACTION RESUME (mode A): arm the visible scheduled resume now - run -ScheduleResume -SessionId <id> [-WorkDir <dir>], then stop." } }
                'B' { if ($f7 -lt 85) { Write-Output "ACTION RESUME (mode B): you're under /loop - run -LoopResume -SessionId <id> and follow its SLEEP/RESUME/STOP/WAIT directive." } }
            }
        } elseif ($atNote) {
            Write-Output ("ACTION (5h {0:N0}%): prefer short, finishable tasks. Save-line {1:N0}% ({2} session(s) pacing); be ready to write PROGRESS.md and hand off there." -f $f5,$save,$n)
        }
        if ($atWeek) {
            Write-Output ("ACTION (weekly {0:N0}% >= 85%): STOP auto-reawakening in this session - do NOT schedule wakeups. Hand off and let the user resume manually." -f $f7)
        }
    } catch { }
}

function Invoke-Join  { param([string]$Sid) $id = Get-SessionId -Explicit $Sid; if ($id) { Write-SessionState -Id $id -Set @{ joined = $true; declined = $false }; Write-Output "usage-pacing: joined ($id)" } else { Write-Output "usage-pacing: no session id - not joined" } }
function Invoke-Leave { param([string]$Sid) $id = Get-SessionId -Explicit $Sid; if ($id) { Remove-Item (Resolve-SessionFile $id) -Force -ErrorAction SilentlyContinue; Write-Output "usage-pacing: left ($id)" } }
# Record a NO answer so the forced opt-in stops nagging for this session (resolved, not joined).
function Invoke-Decline { param([string]$Sid) $id = Get-SessionId -Explicit $Sid; if ($id) { Set-Declined -Id $id; Write-Output "usage-pacing: declined ($id)" } else { Write-Output "usage-pacing: no session id - not declined" } }

# Switch this session BETWEEN pacing modes after the initial opt-in (the choice is no longer
# one-shot). Accepted modes map to the three opt-in answers:
#   no  (no|none|off|decline)        -> leave the pool entirely (declined); pace no further.
#   A   (a|yes)                      -> pace + Variation A (visible scheduled resume, armed at save-line).
#   B   (b|resume|yes+resume)        -> pace + Variation B (in-harness /loop resume).
# On EVERY switch it first tears down any pending Variation-A scheduled task (so a stale resume can't
# fire after you've changed your mind), persists the new resumeMode, then prints ONE directive telling
# the agent what to do next. Variation B's /loop can't be killed from here, so for ->A/->no after B it
# tells the agent to end the loop itself.
function Invoke-SetMode {
    param([string]$Sid, [string]$Mode)
    $id = Get-SessionId -Explicit $Sid
    if (-not $id) { Write-Output "[set-mode] no session id; aborted"; return }
    $m = "$Mode".Trim().ToLower()
    if     ($m -in @('a','yes'))                      { $m = 'A' }
    elseif ($m -in @('b','resume','yes+resume'))      { $m = 'B' }
    elseif ($m -in @('no','none','off','decline'))    { $m = 'no' }
    else { Write-Output "[set-mode] unknown mode '$Mode' - use: no | A | B"; return }

    $prevMode = Get-ResumeMode $id
    # Always cancel a pending Variation-A scheduled task + clear the armed flag (no-op if none).
    Invoke-CancelResume -Sid $id | Out-Null
    $fromB = ($prevMode -eq 'B')

    if ($m -eq 'no') {
        Set-Declined -Id $id
        $msg = "PACING OFF for this session (left the pool); any pending resume cancelled. Don't pace further."
        if ($fromB) { $msg += " You were in Variation B - if you're running under /loop, end the loop now." }
        Write-Output "[set-mode] $msg"
        return
    }

    Write-SessionState -Id $id -Set @{ joined = $true; declined = $false; resumeMode = $m; resumeArmed = $false }
    if ($m -eq 'A') {
        Write-Output "[set-mode] MODE A (visible scheduled resume). Pacing ON. Nothing to launch now; at the save-line arm it with -ScheduleResume."
        if ($fromB) { Write-Output "[set-mode] (switched from B) If you're running under /loop, you can end the loop - resume will be the scheduled-task path instead." }
    } else {
        Write-Output "[set-mode] MODE B (in-harness /loop resume). Pacing ON. To be ready, relaunch the task under /loop now (invoke the loop skill, NO interval) so ScheduleWakeup exists at the save-line."
    }
}

# Register a ONE-SHOT Windows Scheduled Task that, at the next 5h reset, opens a VISIBLE
# Windows Terminal and continues this session (forked, so it won't fight the still-open
# original). No PC wake; a restart-since-scheduling cancels it (guard is in resume-runner.ps1).
function Invoke-ScheduleResume {
    param([string]$Sid, [string]$Work, [string]$Pr, [int]$In = 0)
    $id = Get-SessionId -Explicit $Sid
    if (-not $id) { Write-Output "schedule-resume: no session id; aborted"; return }
    # `claude --resume` only finds the session from the dir it was started in. Recover that origin
    # from the transcript and let it WIN over any -WorkDir: resuming in the wrong dir is the classic
    # "No conversation found with session ID" failure. -WorkDir stays a fallback if origin is unknown.
    $origin = Get-SessionOriginDir -Id $id
    if ($origin) {
        if ($Work -and $Work -ne $origin) { Write-Output "schedule-resume: overriding -WorkDir '$Work' with session origin '$origin' (required for --resume)" }
        $Work = $origin
    }
    if (-not $Work) { $Work = (Get-Location).Path }
    if (-not $Pr) {
        $Pr = "Auto-resumed after a usage-limit reset. Continue the previous work from where it stopped. You are running unattended: do not ask the user questions. Enable usage pacing for yourself, keep working, and when you approach the cap again run -ScheduleResume and stop."
    }
    if ($In -gt 0) {
        # Test override: fire $In seconds from now instead of at the real reset.
        $when = (Get-Date).AddSeconds($In)
    } else {
        try { $u = Get-Usage; $resetIso = $u.five_hour.resets_at } catch { Write-Output "schedule-resume: couldn't read reset time; aborted"; return }
        $when = [datetimeoffset]::Parse($resetIso).LocalDateTime.AddMinutes(1)
        if ($when -lt (Get-Date).AddSeconds(45)) { $when = (Get-Date).AddSeconds(60) }
    }
    $safe = ($id -replace '[^A-Za-z0-9_.-]','_')
    $taskName = "ClaudeResume_$safe"
    if (-not (Test-Path $ResumeDir)) { New-Item -ItemType Directory -Force -Path $ResumeDir | Out-Null }

    # A per-resume launch script avoids cross-process quoting hell for the prompt.
    $launch = Join-Path $ResumeDir "$safe-launch.ps1"
    $pq = $Pr.Replace("'","''"); $wq = $Work.Replace("'","''"); $iq = $id.Replace("'","''")
    @"
Set-Location '$wq'
claude --resume '$iq' --fork-session --dangerously-skip-permissions '$pq'
"@ | Set-Content -Path $launch -Encoding UTF8

    # Capture the live session/terminal process so the resume self-cancels if it's closed.
    $hp = Get-SessionHostProc
    [pscustomobject]@{
        id = $id; taskName = $taskName; launch = $launch
        bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
        when = $when.ToString('o'); workDir = $Work
        hostPid       = if ($hp) { [int]$hp.ProcessId } else { $null }
        hostStartTicks = if ($hp) { [string]$hp.CreationDate.Ticks } else { $null }
        hostName      = if ($hp) { [string]$hp.Name } else { $null }
    } | ConvertTo-Json | Set-Content -Path (Join-Path $ResumeDir "$safe.json") -Encoding UTF8

    $wrapper = Join-Path $PSScriptRoot 'resume-runner.ps1'
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapper`" -Id `"$id`""
    $trigger = New-ScheduledTaskTrigger -Once -At $when
    # StartWhenAvailable: run after a missed start (e.g. PC was asleep). WakeToRun is left OFF.
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Set-ResumeArmed -Id $id -Armed $true   # idle-but-pending: keep counting toward the pool until it fires
        Write-Output ("schedule-resume: visible resume set for {0} in {1} [task {2}]" -f $when.ToString('yyyy-MM-dd HH:mm'), $Work, $taskName)
    } catch {
        Write-Output ("schedule-resume FAILED: {0}" -f $_.Exception.Message)
    }
}

function Invoke-CancelResume {
    param([string]$Sid)
    $id = Get-SessionId -Explicit $Sid
    if (-not $id) { Write-Output "cancel-resume: no session id"; return }
    $safe = ($id -replace '[^A-Za-z0-9_.-]','_')
    Unregister-ScheduledTask -TaskName "ClaudeResume_$safe" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ResumeDir "$safe.json") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ResumeDir "$safe-launch.ps1") -Force -ErrorAction SilentlyContinue
    Set-ResumeArmed -Id $id -Armed $false   # no longer pending -> stop reserving pool room for it
    Write-Output "cancel-resume: cleared for $id"
}

# In-harness "/loop" resume (VARIATION B - the safer alternative to -ScheduleResume): NO scheduled
# task, NO new terminal, NO folder-trust flip, NO --dangerously-skip-permissions. The session
# stays in its own live tab under /loop and sleeps with ScheduleWakeup until the 5h window resets,
# then continues with NORMAL permissions. The agent runs this ONCE per /loop wake to get a single
# deterministic directive about what to do next. Emits exactly one line:
#   RESUME       - the 5h window reset (room is back): stop sleeping, continue the saved work now.
#   SLEEP <secs> - still capped: ScheduleWakeup(<secs>) with the SAME /loop prompt, then re-run this.
#   STOP         - weekly >= 85%: don't keep looping (a reawakening loop drains weekly fastest).
#   WAIT <secs>  - usage couldn't be read: back off and re-check (degrade, never hard-fail).
# Reuses the shared cache + save-line + session pool, so it stays consistent with the gate.
function Invoke-LoopResume {
    param([string]$Sid)
    try {
        $id = Get-SessionId -Explicit $Sid
        $cu = Get-CachedUsage
        if (-not $cu.ok) { Write-Output "[loop-resume] WAIT 600: usage unavailable - ScheduleWakeup(600) with the same /loop prompt and re-run -LoopResume."; return }
        if ($id) { Set-Heartbeat -Id $id -Joined $true }   # keep this session in the pool while it waits
        $f5 = [double]$cu.five; $f7 = [double]$cu.week
        $n  = Get-JoinedActiveCount
        $save = Get-SaveLine -ActiveCount $n
        if ($f7 -ge 85) {
            if ($id) { Set-ResumeArmed -Id $id -Armed $false }   # loop ending -> no longer a pending resume
            Write-Output ("[loop-resume] STOP: weekly {0:N0}% >= 85% - do NOT keep looping. Write/refresh PROGRESS.md, end the loop, and let the user resume manually." -f $f7)
            return
        }
        if ($f5 -lt $save) {
            if ($id) { Set-ResumeArmed -Id $id -Armed $false }   # resumed (active again) -> back to normal heartbeat
            Write-Output ("[loop-resume] RESUME: 5h {0:N0}% < save-line {1:N0}% - the window reset, room is back. Stop sleeping and continue the saved work now." -f $f5,$save)
            return
        }
        if ($id) { Set-ResumeArmed -Id $id -Armed $true }       # sleeping until reset -> stay counted between wakes
        $s5 = Secs-To $cu.fiveReset ([datetime]::UtcNow)
        $delay = $s5 + 60                                   # +1min so we wake just AFTER the reset
        if ($delay -gt 3300) { $delay = 3300 }             # ScheduleWakeup clamps to 3600; chain longer waits
        if ($delay -lt 60)   { $delay = 60 }
        Write-Output ("[loop-resume] SLEEP {0}: 5h {1:N0}% still >= save-line {2:N0}%; ~{3}s ({4}) to reset. ScheduleWakeup({0}) with the SAME /loop prompt, then run -LoopResume again on wake." -f $delay,$f5,$save,$s5,(Format-Span ([timespan]::FromSeconds($s5))))
    } catch { Write-Output "[loop-resume] WAIT 600: error reading usage - ScheduleWakeup(600) with the same /loop prompt and re-run -LoopResume." }
}

# Manual one-line summary.
function Show-Brief {
    try {
        $nowUtc = [datetime]::UtcNow; $u = Get-Usage
        $f5 = [double]$u.five_hour.utilization; $f7 = [double]$u.seven_day.utilization
        $s5 = Secs-To $u.five_hour.resets_at $nowUtc
        $line = "[claude-usage] 5h-block {0:N0}% (resets in {1} / {2}s); 7-day {3:N0}%." -f $f5,(Format-Span ([timespan]::FromSeconds($s5))),$s5,$f7
        if ($f5 -ge 95) { $line += " AT 5h LIMIT." } elseif ($f5 -ge 80) { $line += " 5h high." }
        Write-Output $line
    } catch { }
}

# --- full report (default / -Json / -Raw / -Watch) --------------------------
function Show-Window {
    param([string]$Label,[double]$Pct,[string]$ResetsAt,[double]$WindowHours,[datetime]$NowUtc)
    $reset = [datetimeoffset]::Parse($ResetsAt).UtcDateTime
    $start = $reset.AddHours(-$WindowHours)
    $toReset = $reset - $NowUtc
    $elapsed = [math]::Max(($NowUtc - $start).TotalHours, 0.01)
    $hrsLeft = [math]::Max($toReset.TotalHours, 0)
    $burn = $Pct / $elapsed; $remaining = 100 - $Pct
    $sustain = if ($hrsLeft -gt 0) { $remaining / $hrsLeft } else { 0 }
    $projected = [math]::Min(100, $Pct + $burn * $hrsLeft)
    Write-Host ("  {0,-13}[{1}] {2,5:N1}%" -f $Label,(Bar $Pct),$Pct) -ForegroundColor (PctColor $Pct)
    Write-Host ("                resets in {0} (at {1}local)" -f (Format-Span $toReset), $reset.ToLocalTime().ToString('ddd HH:mm ')) -ForegroundColor DarkGray
    if ($Pct -ge 100) {
        Write-Host ("                LIMIT REACHED - wait {0}." -f (Format-Span $toReset)) -ForegroundColor Red
    } elseif ($burn -gt $sustain -and $hrsLeft -gt 0 -and $burn -gt 0) {
        $eta = $NowUtc.AddHours($remaining / $burn)
        Write-Host ("                PACE: ~{0:N1}%/h -> 100% in {1}. Ease to ~{2:N1}%/h." -f $burn,(Format-Span ($eta - $NowUtc)),$sustain) -ForegroundColor Yellow
    } else {
        Write-Host ("                PACE: on track (~{0:N1}% at reset). Headroom ~{1:N1}%/h." -f $projected,$sustain) -ForegroundColor Green
    }
}

function Show-Report {
    $nowUtc = [datetime]::UtcNow; $u = Get-Usage
    if ($Raw)  { $u | ConvertTo-Json -Depth 8; return }
    if ($Json) {
        [pscustomobject]@{
            generatedUtc = $nowUtc.ToString('o')
            fiveHourPct = $u.five_hour.utilization; fiveHourReset = $u.five_hour.resets_at; fiveHourResetSecs = (Secs-To $u.five_hour.resets_at $nowUtc)
            sevenDayPct = $u.seven_day.utilization; sevenDayReset = $u.seven_day.resets_at; sevenDayResetSecs = (Secs-To $u.seven_day.resets_at $nowUtc)
            opusPct = $u.seven_day_opus.utilization; sonnetPct = $u.seven_day_sonnet.utilization
            sessionsPacing = (Get-JoinedActiveCount); saveLine = (Get-SaveLine -ActiveCount (Get-JoinedActiveCount)); planMultiplier = (Get-PlanMultiplier)
        } | ConvertTo-Json
        return
    }
    Write-Host ""
    Write-Host "  Claude Code usage" -ForegroundColor Cyan -NoNewline
    Write-Host "  (live from your account)" -ForegroundColor DarkGray
    Write-Host ("  " + ("-" * 60)) -ForegroundColor DarkGray
    if ($u.five_hour -and $null -ne $u.five_hour.utilization) { Show-Window -Label '5-hour block' -Pct ([double]$u.five_hour.utilization) -ResetsAt $u.five_hour.resets_at -WindowHours 5 -NowUtc $nowUtc }
    if ($u.seven_day -and $null -ne $u.seven_day.utilization) { Show-Window -Label '7-day window' -Pct ([double]$u.seven_day.utilization) -ResetsAt $u.seven_day.resets_at -WindowHours 168 -NowUtc $nowUtc }
    $n = Get-JoinedActiveCount
    Write-Host ("  " + ("-" * 60)) -ForegroundColor DarkGray
    Write-Host ("  sessions pacing   {0}   save-line {1:N0}%   (plan x{2})" -f $n,(Get-SaveLine -ActiveCount $n),(Get-PlanMultiplier)) -ForegroundColor DarkGray
    Write-Host ""
}

# --- dispatch ---------------------------------------------------------------
if ($SessionStart)   { Show-SessionStart -Sid $SessionId; exit 0 }
if ($Join)           { Invoke-Join  -Sid $SessionId; exit 0 }
if ($Leave)          { Invoke-Leave -Sid $SessionId; exit 0 }
if ($Decline)        { Invoke-Decline -Sid $SessionId; exit 0 }
if ($SetMode)        { Invoke-SetMode -Sid $SessionId -Mode $SetMode; exit 0 }
if ($ScheduleResume) { Invoke-ScheduleResume -Sid $SessionId -Work $WorkDir -Pr $Prompt -In $InSeconds; exit 0 }
if ($CancelResume)   { Invoke-CancelResume -Sid $SessionId; exit 0 }
if ($LoopResume)     { Invoke-LoopResume -Sid $SessionId; exit 0 }
if ($Gate)           { Show-Gate    -Sid $SessionId; exit 0 }
if ($Brief)          { Show-Brief;  exit 0 }

if ($Watch -gt 0) {
    while ($true) {
        Clear-Host
        try { Show-Report } catch { Write-Host "  $_" -ForegroundColor Red }
        Write-Host ("  refreshing every {0}s - Ctrl+C to stop" -f $Watch) -ForegroundColor DarkGray
        Start-Sleep -Seconds $Watch
    }
} else { Show-Report }

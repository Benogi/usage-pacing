<#
  resume-runner.ps1 - fired by the one-shot scheduled task created by `claude-usage.ps1 -ScheduleResume`.
  At the reset time it: (1) skips if the PC was restarted since scheduling (PC off = "I'm done"),
  (2) skips if the session's terminal process is no longer alive (tab/window closed = "I'm done"),
  (3) otherwise opens a VISIBLE Windows Terminal continuing the session (forked), (4) cleans up the
  task + its state files. Never throws; on any problem it just cleans up and exits.
  So a resume fires ONLY if you left the terminal open/trayed; closing it or shutting down cancels it.
#>
param([string]$Id)
$ErrorActionPreference = 'SilentlyContinue'

$dir       = $PSScriptRoot
$safe      = ($Id -replace '[^A-Za-z0-9_.-]','_')
$statePath = Join-Path $dir "resume\$safe.json"
$launch    = Join-Path $dir "resume\$safe-launch.ps1"
$taskName  = "ClaudeResume_$safe"

# Clear this session's pending-resume flag in the pacing pool: once the resume has fired (or been
# skipped because the tab was closed / PC rebooted), it's no longer pending and must stop counting.
function Clear-Armed {
    try {
        $sf = Join-Path $dir "sessions\$safe.json"
        if (-not (Test-Path $sf)) { return }
        $o = Get-Content $sf -Raw | ConvertFrom-Json
        if ($o.PSObject.Properties['resumeArmed']) { $o.resumeArmed = $false }
        else { $o | Add-Member -NotePropertyName resumeArmed -NotePropertyValue $false -Force }
        $o | ConvertTo-Json | Set-Content -Path $sf -Encoding UTF8
    } catch { }
}

function Cleanup {
    Clear-Armed
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item $launch    -Force -ErrorAction SilentlyContinue
}

# Pre-trust the target folder so the forked `claude --resume` doesn't stop at the
# "Do you trust the files in this folder?" dialog (a gate SEPARATE from --dangerously-skip-permissions).
# Claude keys projects in ~/.claude.json by forward-slash path. Lossless edit (Depth 100), backed up.
function Ensure-FolderTrusted {
    param([string]$WorkDir)
    try {
        if (-not $WorkDir) { return }
        $cfg = Join-Path $env:USERPROFILE '.claude.json'
        if (-not (Test-Path $cfg)) { return }
        $key = $WorkDir.Replace('\','/')
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $j.projects) { return }
        $prop = $j.projects.PSObject.Properties[$key]
        if ($prop) {
            if ($prop.Value.hasTrustDialogAccepted -eq $true) { return }   # already trusted, no write
            $prop.Value.hasTrustDialogAccepted = $true
        } else {
            # Folder claude has never seen: create a minimal trusted entry.
            $j.projects | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{ hasTrustDialogAccepted = $true })
        }
        Copy-Item $cfg "$cfg.bak" -Force -ErrorAction SilentlyContinue
        ($j | ConvertTo-Json -Depth 100) | Set-Content -Path $cfg -Encoding UTF8
    } catch { }
}

try {
    if (-not (Test-Path $statePath)) { Cleanup; return }
    $s = Get-Content $statePath -Raw | ConvertFrom-Json

    # Restart guard: if Windows booted AFTER this resume was scheduled, do NOT resume
    # (turning the PC off means "I'm done").
    $bootNow = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    if ($bootNow -ne $s.bootTime) { Cleanup; return }

    # Terminal-alive guard: only resume if the session's terminal process is STILL running.
    # Closing the tab/window kills it -> that also means "I'm done", so cancel the resume.
    # (No host captured = older/failed capture -> fail safe to NOT resuming.)
    $alive = $false
    if ($s.hostPid) {
        try {
            $hp = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$s.hostPid) -ErrorAction SilentlyContinue
            if ($hp -and ("$($hp.CreationDate.Ticks)" -eq "$($s.hostStartTicks)")) { $alive = $true }
        } catch { $alive = $false }
    }
    if (-not $alive) { Cleanup; return }

    if (-not (Test-Path $launch)) { Cleanup; return }

    # Remove the folder-trust dialog before launching (otherwise the fork waits for a human click).
    Ensure-FolderTrusted -WorkDir $s.workDir

    # Visible: add a NEW TAB to the already-open Terminal window (-w last), explicitly running
    # PowerShell (not the default cmd profile), via -File so wt never sees a ';'. -NoExit keeps
    # the tab open after the resumed session ends.
    Start-Process 'wt.exe' -ArgumentList @(
        '-w', 'last', 'new-tab',
        '-d', $s.workDir,
        'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launch
    )
} catch { }

# One-shot: the resume has fired, so clear the pending flag and remove the task + state (the launch
# script is left until the resumed session is running; comment the next line out to keep for debug).
Clear-Armed
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $statePath -Force -ErrorAction SilentlyContinue

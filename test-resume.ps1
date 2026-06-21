<#
  test-resume.ps1 - guided test of the visible scheduled resume. Run AFTER a relaunch.

  The agent runs this with its OWN session id (from the [usage-pacing] line injected at start):
    powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\usage-pacing\test-resume.ps1 -SessionId <id>

  It schedules a resume to fire in a few seconds (test override -InSeconds) with a marker prompt,
  so you can watch the FULL pipeline quickly instead of waiting ~5h for a real reset:
    task fires -> restart-guard -> new PowerShell tab in THIS window -> forked `claude --resume`.

  What it confirms - especially the one open unknown: does the forked session AUTO-RUN the prompt,
  or just pre-fill and wait for Enter?
#>
param([string]$SessionId, [int]$InSeconds = 12)

$script = Join-Path $PSScriptRoot 'claude-usage.ps1'
if (-not $SessionId) {
    Write-Host "Need -SessionId <id>. Use the id from the [usage-pacing] line shown at session start." -ForegroundColor Yellow
    exit 1
}

$marker = "TEST-RESUME: reply with exactly the single line RESUME-AUTORUN-OK and then stop. Do not ask about pacing or do anything else."

Write-Host "Scheduling a TEST resume to fire in ~$InSeconds seconds (forks this session; your current tab is untouched)..." -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $script -ScheduleResume -SessionId $SessionId -WorkDir (Get-Location).Path -Prompt $marker -InSeconds $InSeconds

Write-Host ""
Write-Host "WATCH NOW (~$InSeconds s):" -ForegroundColor Green
Write-Host "  1. A NEW TAB opens in this Terminal window, running PowerShell."
Write-Host "  2. It runs: claude --resume $SessionId --fork-session ...  (a forked copy)."
Write-Host "  3. RESULT:"
Write-Host "       - new tab prints 'RESUME-AUTORUN-OK' on its own  ->  auto-run WORKS. Done." -ForegroundColor Green
Write-Host "       - new tab sits at an empty prompt waiting          ->  auto-run does NOT work." -ForegroundColor Yellow
Write-Host "         Fix: switch resume-runner's launch to headless 'claude -p' (auto-runs but no"
Write-Host "         visible tab), OR find an interactive auto-submit flag. See HANDOFF.md open item 2."
Write-Host ""
Write-Host "Cancel a pending test resume:" -ForegroundColor DarkGray
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" -CancelResume -SessionId $SessionId" -ForegroundColor DarkGray

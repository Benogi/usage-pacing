<#
  activate.ps1 - (Re)install the usage-pacing modifications:
    * adds our SessionStart + UserPromptSubmit hook entries to ~/.claude/settings.json
      (existing keys & any unrelated hooks are preserved; our entries are de-duplicated)
    * installs ~/.claude/CLAUDE.md from the canonical copy in this folder (CLAUDE.global.md);
      if a different CLAUDE.md already exists, it's backed up to CLAUDE.md.prebak first
  settings.json is backed up to settings.json.bak before any change. Idempotent.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\usage-pacing\activate.ps1
#>
$ErrorActionPreference = 'Stop'

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$claudeMd     = Join-Path $claudeDir 'CLAUDE.md'
$mdBackup     = Join-Path $claudeDir 'CLAUDE.md.prebak'
$paceDir      = Join-Path $claudeDir 'usage-pacing'
$script       = Join-Path $paceDir 'claude-usage.ps1'
# Forward slashes: Claude Code runs hook commands through a POSIX-style shell that eats
# backslashes (C:\Users\... -> C:Users...). PowerShell -File accepts forward slashes fine.
$scriptFwd    = ($script -replace '\\','/')
$canonMd      = Join-Path $paceDir 'CLAUDE.global.md'
$marker       = 'claude-usage.ps1'   # slash-agnostic; identifies OUR hook commands
$mdMarker     = 'Usage self-pacing'

if (-not (Test-Path $script))  { Write-Host "Missing $script - usage-pacing work not found. Aborting." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $canonMd)) { Write-Host "Missing $canonMd (canonical CLAUDE.md). Aborting." -ForegroundColor Red; exit 1 }

Write-Host "Activating usage-pacing..." -ForegroundColor Cyan

$ssCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFwd -SessionStart"
$upCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFwd -Gate"

function Set-OurHook {
    param($Settings, [string]$Event, [string]$Command, [string]$Marker)
    $group = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $Command; timeout = 15 }) }
    $foreign = @()
    if ($Settings.hooks.PSObject.Properties.Name -contains $Event) {
        $foreign = @($Settings.hooks.$Event | Where-Object {
            -not ((@($_.hooks | ForEach-Object { $_.command }) -join "`n").Contains($Marker))
        })
    }
    $arr = @($foreign + $group)
    if ($Settings.hooks.PSObject.Properties.Name -contains $Event) { $Settings.hooks.$Event = $arr }
    else { $Settings.hooks | Add-Member -NotePropertyName $Event -NotePropertyValue $arr -Force }
}

# --- settings.json: add/refresh our hooks ----------------------------------
$settings = if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    Get-Content $settingsPath -Raw | ConvertFrom-Json
} else { [pscustomobject]@{} }

if (-not ($settings.PSObject.Properties.Name -contains 'hooks') -or $null -eq $settings.hooks) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}
Set-OurHook -Settings $settings -Event 'SessionStart'     -Command $ssCmd -Marker $marker
Set-OurHook -Settings $settings -Event 'UserPromptSubmit' -Command $upCmd -Marker $marker
$settings | ConvertTo-Json -Depth 12 | Set-Content $settingsPath -Encoding UTF8
Write-Host "  settings.json: SessionStart + UserPromptSubmit hooks installed (backup: settings.json.bak)" -ForegroundColor Green

# --- CLAUDE.md: install from canonical, backing up any foreign one ----------
if ((Test-Path $claudeMd) -and -not ((Get-Content $claudeMd -Raw) -match [regex]::Escape($mdMarker))) {
    if (-not (Test-Path $mdBackup)) { Copy-Item $claudeMd $mdBackup -Force; Write-Host "  CLAUDE.md: your existing file backed up to CLAUDE.md.prebak" -ForegroundColor Yellow }
}
Copy-Item $canonMd $claudeMd -Force
Write-Host "  CLAUDE.md: installed (opt-in prompt active for new sessions)" -ForegroundColor Green

Write-Host "Done. New sessions will ask about pacing. (Current session unaffected - hooks load at start.)" -ForegroundColor Cyan

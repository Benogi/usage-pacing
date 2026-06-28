<#
  deactivate.ps1 - Revert Claude Code to its original (stock) state by removing ONLY the
  usage-pacing modifications:
    * strips our hook entries from ~/.claude/settings.json (other keys & any unrelated hooks kept)
    * removes ~/.claude/CLAUDE.md if it's ours (restores a pre-existing one if we had backed it up)
  It does NOT delete anything in this folder - all our work stays put. Re-enable with activate.ps1.
  settings.json is backed up to settings.json.bak before any change. Idempotent.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\usage-pacing\windows\deactivate.ps1
#>
$ErrorActionPreference = 'Stop'

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$claudeMd     = Join-Path $claudeDir 'CLAUDE.md'
$mdBackup     = Join-Path $claudeDir 'CLAUDE.md.prebak'
$marker       = 'claude-usage.ps1'   # slash-agnostic; identifies OUR hook commands
$mdMarker     = 'Usage self-pacing'               # identifies OUR CLAUDE.md

Write-Host "Deactivating usage-pacing..." -ForegroundColor Cyan

# --- settings.json: remove our hook entries only --------------------------
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $changed = $false
    if ($settings.PSObject.Properties.Name -contains 'hooks' -and $settings.hooks) {
        foreach ($evt in @($settings.hooks.PSObject.Properties.Name)) {
            $kept = @($settings.hooks.$evt | Where-Object {
                -not ((@($_.hooks | ForEach-Object { $_.command }) -join "`n").Contains($marker))
            })
            if ($kept.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove($evt); $changed = $true }
            elseif ($kept.Count -ne @($settings.hooks.$evt).Count) { $settings.hooks.$evt = $kept; $changed = $true }
        }
        if (($settings.hooks.PSObject.Properties | Measure-Object).Count -eq 0) {
            $settings.PSObject.Properties.Remove('hooks'); $changed = $true
        }
    }
    $settings | ConvertTo-Json -Depth 12 | Set-Content $settingsPath -Encoding UTF8
    if ($changed) { Write-Host "  settings.json: removed our hooks (backup: settings.json.bak)" -ForegroundColor Green }
    else          { Write-Host "  settings.json: no usage-pacing hooks present (nothing to remove)" -ForegroundColor DarkGray }
} else {
    Write-Host "  settings.json: not found (nothing to do)" -ForegroundColor DarkGray
}

# --- CLAUDE.md: remove ours / restore any pre-existing one ------------------
if ((Test-Path $claudeMd) -and ((Get-Content $claudeMd -Raw) -match [regex]::Escape($mdMarker))) {
    Remove-Item $claudeMd -Force
    if (Test-Path $mdBackup) {
        Move-Item $mdBackup $claudeMd -Force
        Write-Host "  CLAUDE.md: removed ours, restored your previous CLAUDE.md" -ForegroundColor Green
    } else {
        Write-Host "  CLAUDE.md: removed (stock state had none)" -ForegroundColor Green
    }
} else {
    Write-Host "  CLAUDE.md: not ours / absent (left untouched)" -ForegroundColor DarkGray
}

Write-Host "Done. Stock Claude Code behavior restored. Your work in usage-pacing\ is intact." -ForegroundColor Cyan
$activate = Join-Path (Split-Path $PSCommandPath) 'activate.ps1'
Write-Host "Re-enable anytime: powershell -NoProfile -ExecutionPolicy Bypass -File `"$activate`"" -ForegroundColor DarkGray

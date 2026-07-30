<#
.SYNOPSIS
  Create junction links so the "plugins" directory is visible to every Hermes profile.
.DESCRIPTION
  For each profile under <HERMES_HOME>/profiles/, this script creates a junction
  pointing back to <HERMES_HOME>/plugins.  Dashboard API plugins (like
  memory-manager) are then available no matter which profile is active.
#>

$ErrorActionPreference = "Stop"

$HermesHome = $env:HERMES_HOME
if (-not $HermesHome) {
    $HermesHome = "$env:LOCALAPPDATA\hermes"
}

$SourcePlugins = Join-Path $HermesHome "plugins"
$ProfilesDir   = Join-Path $HermesHome "profiles"

if (-not (Test-Path $ProfilesDir)) {
    Write-Host "No profiles directory found at $ProfilesDir — nothing to link." -ForegroundColor Yellow
    exit 0
}

$linked  = 0
$skipped = 0

Get-ChildItem $ProfilesDir -Directory | ForEach-Object {
    $profileName = $_.Name
    $tgtPlugins  = Join-Path $_.FullName "plugins"

    if (Test-Path $tgtPlugins) {
        $item = Get-Item $tgtPlugins
        if ($item.LinkType -eq "Junction") {
            Write-Host "[$profileName] ALREADY LINKED -> $($item.Target)" -ForegroundColor Yellow
            $skipped++
            return
        }
        Write-Host "[$profileName] EXISTS (not a junction) — skipping" -ForegroundColor Yellow
        $skipped++
        return
    }

    try {
        New-Item -Path $tgtPlugins -ItemType Junction -Target $SourcePlugins -Force | Out-Null
        Write-Host "[$profileName] LINKED -> $SourcePlugins" -ForegroundColor Green
        $linked++
    } catch {
        Write-Host "[$profileName] FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done.  $linked linked, $skipped skipped." -ForegroundColor Cyan

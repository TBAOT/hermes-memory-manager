# Memory Manager plugin installer for Windows.
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.ps1 | iex
#
# Or locally:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'

$PLUGIN_ID = 'memory-manager'
$REPO_BASE = 'https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main'

# --- Resolve HERMES_HOME -----------------------------------------------------
$envHermesHome = $env:HERMES_HOME
if ($envHermesHome) {
    $HermesHome = $envHermesHome
} elseif ($env:LOCALAPPDATA) {
    $HermesHome = Join-Path $env:LOCALAPPDATA 'hermes'
} else {
    $HermesHome = Join-Path $env:USERPROFILE '.hermes'
}

if (-not (Test-Path $HermesHome)) {
    Write-Host "Hermes home not found at: $HermesHome" -ForegroundColor Red
    Write-Host 'Install Hermes first, then re-run this script.'
    exit 1
}

Write-Host "Hermes home: $HermesHome" -ForegroundColor Cyan

# --- Locate source files -----------------------------------------------------
# When running from a local clone, prefer the repo files. When running via
# curl|iex, download from GitHub.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# CRITICAL: read/write at the BYTE level. Windows PowerShell 5.x defaults
# to the system ANSI codepage (GBK on zh-CN) for Get-Content -Raw, which
# corrupts UTF-8 Chinese characters into mojibake; Set-Content -Encoding
# UTF8 adds a BOM. Both cause "Invalid or unexpected token" in V8. Using
# [IO.File]::ReadAllBytes / WriteAllBytes bypasses all encoding layers.
function Install-PluginFile {
    param([string]$RelativePath, [string]$UrlPath, [string]$Dest)
    $localPath = Join-Path $scriptDir $RelativePath
    if ($scriptDir -and (Test-Path $localPath)) {
        Write-Host "  Copying: $localPath"
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
    } else {
        $url = "$REPO_BASE/$UrlPath"
        Write-Host "  Downloading: $url"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
        $bytes = $resp.Content
        # If Content is a string (PowerShell 5 returns string for text/*),
        # convert back to UTF-8 bytes without BOM.
        if ($bytes -is [string]) {
            $enc = New-Object System.Text.UTF8Encoding $false
            $bytes = $enc.GetBytes($bytes)
        }
    }
    [System.IO.File]::WriteAllBytes($Dest, $bytes)
}

# --- Create directories ------------------------------------------------------
$backendDir = Join-Path $HermesHome "plugins\$PLUGIN_ID\dashboard"
$desktopDir = Join-Path $HermesHome "desktop-plugins\$PLUGIN_ID"

Write-Host 'Creating directories...' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $backendDir | Out-Null
New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null

# --- Write backend files -----------------------------------------------------
Write-Host 'Installing backend (plugin_api.py + manifest.json)...' -ForegroundColor Cyan
Install-PluginFile -RelativePath 'python\dashboard\plugin_api.py' -UrlPath 'python/dashboard/plugin_api.py' -Dest (Join-Path $backendDir 'plugin_api.py')
Install-PluginFile -RelativePath 'python\dashboard\manifest.json' -UrlPath 'python/dashboard/manifest.json' -Dest (Join-Path $backendDir 'manifest.json')

# --- Write desktop plugin ----------------------------------------------------
Write-Host 'Installing desktop plugin (plugin.js)...' -ForegroundColor Cyan
Install-PluginFile -RelativePath 'desktop\plugin.js' -UrlPath 'desktop/plugin.js' -Dest (Join-Path $desktopDir 'plugin.js')

# --- Enable the plugin -------------------------------------------------------
# The dashboard plugin API loader (web_server._mount_plugin_api_routes)
# gates user plugins on the `plugins.enabled` list in config.yaml. We edit
# the config directly via Hermes' own config module so the format matches
# what `hermes plugins enable` would produce.
Write-Host 'Enabling plugin in config.yaml...' -ForegroundColor Cyan
$enableScript = @"
import sys
from pathlib import Path
hermes_home = Path(r'$HermesHome')
plugin_id = '$PLUGIN_ID'
# Prefer Hermes' own config helpers so save_format matches the rest of the
# file; fall back to raw PyYAML if those imports fail (e.g. running outside
# the Hermes venv).
try:
    sys.path.insert(0, str(hermes_home / 'hermes-agent'))
    from hermes_cli.config import load_config, save_config
    cfg = load_config()
    plugins = cfg.setdefault('plugins', {})
    enabled = plugins.get('enabled')
    if not isinstance(enabled, list):
        enabled = []
    if plugin_id not in enabled:
        enabled.append(plugin_id)
        plugins['enabled'] = sorted(enabled)
        save_config(cfg)
        print(f'  Added {plugin_id} to plugins.enabled (via hermes_cli.config)')
    else:
        print(f'  {plugin_id} already in plugins.enabled')
except Exception as exc:
    print(f'  hermes_cli.config not available ({exc}); falling back to PyYAML')
    import yaml
    config_path = hermes_home / 'config.yaml'
    if not config_path.exists():
        print(f'  config.yaml not found at {config_path}')
        sys.exit(0)
    with open(config_path, 'r', encoding='utf-8') as f:
        cfg = yaml.safe_load(f) or {}
    plugins = cfg.setdefault('plugins', {})
    enabled = plugins.get('enabled') or []
    if not isinstance(enabled, list):
        enabled = []
    if plugin_id not in enabled:
        enabled.append(plugin_id)
        plugins['enabled'] = sorted(enabled)
        with open(config_path, 'w', encoding='utf-8') as f:
            yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)
        print(f'  Added {plugin_id} to plugins.enabled (via PyYAML)')
    else:
        print(f'  {plugin_id} already in plugins.enabled')
"@
# Prefer Hermes' own Python venv (it has hermes_cli.config + ruamel.yaml).
# Fall back to system python if the venv isn't where we expect.
$hermesPy = Join-Path $HermesHome 'hermes-agent\venv\Scripts\python.exe'
if (-not (Test-Path $hermesPy)) {
    $hermesPy = 'python'
}
$enableScript | & $hermesPy -

Write-Host ''
Write-Host 'Memory Manager plugin installed successfully.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Restart Hermes Desktop (or run: hermes gateway restart)'
Write-Host '  2. Open the sidebar — you''ll see a "记忆管理器" entry.'
Write-Host '  3. Or use the command palette (Ctrl+K) and search "打开记忆管理器".'
Write-Host ''
Write-Host 'To uninstall: delete these folders and run hermes plugins disable memory-manager'
Write-Host "  - $backendDir"
Write-Host "  - $desktopDir"

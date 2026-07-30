# Memory Manager plugin installer for Windows.
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.ps1 | iex
#
# Or locally:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# To uninstall, run:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 uninstall

param(
    [string]$Action = "install"
)

$ErrorActionPreference = "Stop"

$PLUGIN_ID = "memory-manager"
$REPO_BASE = "https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main"

# --- Resolve HERMES_HOME -----------------------------------------------------
$envHermesHome = $env:HERMES_HOME
if ($envHermesHome) {
    $HermesHome = $envHermesHome
} elseif ($env:LOCALAPPDATA) {
    $HermesHome = Join-Path $env:LOCALAPPDATA "hermes"
} else {
    $HermesHome = Join-Path $env:USERPROFILE ".hermes"
}

if (-not (Test-Path $HermesHome)) {
    Write-Host "Hermes home not found at: $HermesHome" -ForegroundColor Red
    Write-Host "Install Hermes first, then re-run this script."
    exit 1
}

Write-Host "Hermes home: $HermesHome" -ForegroundColor Cyan

# --- Resolve Python / config tool -------------------------------------------
$hermesPy = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
if (-not (Test-Path $hermesPy)) {
    $hermesPy = "python"
}

# --- Helper: copy or download file bytes with UTF-8 (no BOM) ---------------
function Install-PluginFile {
    param([string]$RelativePath, [string]$UrlPath, [string]$Dest)
    $localPath = Join-Path $PSScriptRoot $RelativePath
    if ($PSScriptRoot -and (Test-Path $localPath)) {
        Write-Host "  Copying: $localPath"
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
    } else {
        $url = "$REPO_BASE/$UrlPath"
        Write-Host "  Downloading: $url"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
        $bytes = $resp.Content
        if ($bytes -is [string]) {
            $enc = New-Object System.Text.UTF8Encoding $false
            $bytes = $enc.GetBytes($bytes)
        }
    }
    [System.IO.File]::WriteAllBytes($Dest, $bytes)
}

# --- helpers to enable/disable the plugin in config.yaml -------------------
function Enable-Plugin {
    param([string]$HermesHome, [string]$PluginId)
    $enableScript = @"
import sys
from pathlib import Path
hermes_home = Path(r`"$HermesHome`")
plugin_id = `"$PluginId`"
try:
    sys.path.insert(0, str(hermes_home / "hermes-agent"))
    from hermes_cli.config import load_config, save_config
    cfg = load_config()
    plugins = cfg.setdefault("plugins", {})
    enabled = plugins.get("enabled")
    if not isinstance(enabled, list):
        enabled = []
    if plugin_id not in enabled:
        enabled.append(plugin_id)
        plugins["enabled"] = sorted(enabled)
        save_config(cfg)
        print(f"  Added {plugin_id} to plugins.enabled")
    else:
        print(f"  {plugin_id} already in plugins.enabled")
except Exception as exc:
    import subprocess
    subprocess.run(["hermes", "plugins", "enable", plugin_id], check=False)
"@
    $enableScript | & $hermesPy -
}

function Disable-Plugin {
    param([string]$HermesHome, [string]$PluginId)
    $disableScript = @"
import sys
from pathlib import Path
hermes_home = Path(r`"$HermesHome`")
plugin_id = `"$PluginId`"
try:
    sys.path.insert(0, str(hermes_home / "hermes-agent"))
    from hermes_cli.config import load_config, save_config
    cfg = load_config()
    plugins = cfg.setdefault("plugins", {})
    enabled = plugins.get("enabled") or []
    if plugin_id in enabled:
        enabled.remove(plugin_id)
        plugins["enabled"] = sorted(enabled)
        save_config(cfg)
        print(f"  Removed {plugin_id} from plugins.enabled")
    else:
        print(f"  {plugin_id} not in plugins.enabled")
except Exception:
    import subprocess
    subprocess.run(["hermes", "plugins", "disable", plugin_id], check=False)
"@
    $disableScript | & $hermesPy -
}

# --- Uninstall helper ------------------------------------------------------
function Uninstall-Plugin {
    param([string]$HermesHome, [string]$PluginId)
    $backendDir = Join-Path $HermesHome "plugins\$PluginId"
    $desktopDir = Join-Path $HermesHome "desktop-plugins\$PluginId"

    Write-Host "Removing: $backendDir" -ForegroundColor Yellow
    if (Test-Path $backendDir) { Remove-Item -Recurse -Force $backendDir }

    Write-Host "Removing: $desktopDir" -ForegroundColor Yellow
    if (Test-Path $desktopDir) { Remove-Item -Recurse -Force $desktopDir }

    Disable-Plugin -HermesHome $HermesHome -PluginId $PluginId

    Write-Host ""
    Write-Host "$PluginId uninstalled." -ForegroundColor Green
    Write-Host "Restart Hermes Desktop to apply."
}

# --- Main ---------------------------------------------------------------------
switch ($Action.ToLower()) {
    "install" {
        Write-Host "Installing $PLUGIN_ID → $HermesHome" -ForegroundColor Cyan

        $backendDir = Join-Path $HermesHome "plugins\$PLUGIN_ID\dashboard"
        $desktopDir = Join-Path $HermesHome "desktop-plugins\$PLUGIN_ID"

        New-Item -ItemType Directory -Force -Path $backendDir | Out-Null
        New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null

        Write-Host "Installing backend (plugin_api.py + manifest.json + plugin.yaml)..." -ForegroundColor Cyan
        Install-PluginFile -RelativePath "python\dashboard\plugin_api.py" -UrlPath "python/dashboard/plugin_api.py" -Dest (Join-Path $backendDir "plugin_api.py")
        Install-PluginFile -RelativePath "python\dashboard\manifest.json" -UrlPath "python/dashboard/manifest.json" -Dest (Join-Path $backendDir "manifest.json")
        Install-PluginFile -RelativePath "plugin.yaml" -UrlPath "plugin.yaml" -Dest (Join-Path (Split-Path $backendDir -Parent) "plugin.yaml")

        Write-Host "Installing desktop plugin (plugin.js)..." -ForegroundColor Cyan
        Install-PluginFile -RelativePath "desktop\plugin.js" -UrlPath "desktop/plugin.js" -Dest (Join-Path $desktopDir "plugin.js")

        # Write uninstall script for Windows
        $uninstallPs1 = @"
`$ErrorActionPreference = 'Stop'
`$PLUGIN_ID = '$PLUGIN_ID'
`$HERMES_HOME = '$HermesHome'
Write-Host "Uninstalling `$PLUGIN_ID..." -ForegroundColor Yellow
`$backendDir = Join-Path `$HERMES_HOME "plugins\`$PLUGIN_ID"
`$desktopDir = Join-Path `$HERMES_HOME "desktop-plugins\`$PLUGIN_ID"
if (Test-Path `$backendDir) { Remove-Item -Recurse -Force `$backendDir }
if (Test-Path `$desktopDir) { Remove-Item -Recurse -Force `$desktopDir }

`$disableScript = @"
import sys
from pathlib import Path
hermes_home = Path(r`"`$HERMES_HOME`")
plugin_id = `"`$PLUGIN_ID`"
try:
    sys.path.insert(0, str(hermes_home / "hermes-agent"))
    from hermes_cli.config import load_config, save_config
    cfg = load_config()
    plugins = cfg.setdefault("plugins", {})
    enabled = plugins.get("enabled") or []
    if plugin_id in enabled:
        enabled.remove(plugin_id)
        plugins["enabled"] = sorted(enabled)
        save_config(cfg)
        print(f"  Removed {plugin_id} from plugins.enabled")
except Exception:
    import subprocess
    subprocess.run(["hermes", "plugins", "disable", plugin_id], check=False)
"@
`$disableScript | python -

Write-Host "`$PLUGIN_ID uninstalled." -ForegroundColor Green
Write-Host "Restart Hermes Desktop to apply."
"@
        $uninstallPs1 | Out-File -FilePath (Join-Path $backendDir "uninstall.ps1") -Encoding UTF8 -NoNewline

        Enable-Plugin -HermesHome $HermesHome -PluginId $PLUGIN_ID

        Write-Host ""
        Write-Host "$PLUGIN_ID installed successfully." -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Restart Hermes Desktop (or run: hermes gateway restart)"
        Write-Host "  2. Open the sidebar - you will see a 'Memory Manager' entry."
        Write-Host "  3. Or use the command palette (Ctrl+K) and search 'Open Memory Manager'."
        Write-Host ""
        Write-Host "To uninstall: powershell -ExecutionPolicy Bypass -File .\install.ps1 uninstall"
    }
    "uninstall" {
        Write-Host "Uninstalling $PLUGIN_ID..." -ForegroundColor Yellow
        Uninstall-Plugin -HermesHome $HermesHome -PluginId $PLUGIN_ID
    }
    default {
        Write-Host "Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [install|uninstall]" -ForegroundColor Red
        exit 1
    }
}

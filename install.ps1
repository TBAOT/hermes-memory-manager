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
function Ensure-ProfilePluginsLinks {
    # Walks <HERMES_HOME>/profiles/* and makes sure each profile has BOTH a
    # "plugins" and a "desktop-plugins" entry pointing back at the global
    # <HERMES_HOME>/plugins and <HERMES_HOME>/desktop-plugins. This is what
    # lets a freshly-created profile pick up dashboard plugins (like
    # memory-manager) AND the desktop runtime plugin without re-running the
    # installer. Designed to be safe + cheap to call on every Hermes
    # startup: it only creates the junction when it's missing, never
    # overwrites a real directory, and exits silently when there are no
    # profiles yet.
    param([string]$HermesHome)

    $profilesDir = Join-Path $HermesHome "profiles"

    if (-not (Test-Path $profilesDir)) {
        return
    }

    Get-ChildItem $profilesDir -Directory | ForEach-Object {
        $pName = $_.Name
        foreach ($dirName in @("plugins", "desktop-plugins")) {
            $source = Join-Path $HermesHome $dirName
            if (-not (Test-Path $source)) {
                # That part not installed at all — nothing to link.
                continue
            }
            $tgt = Join-Path $_.FullName $dirName
            if (Test-Path $tgt) {
                $item = Get-Item $tgt -Force
                if ($item.LinkType -eq "Junction" -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    # Already a junction (or symlink) — leave it alone.
                    continue
                }
                # Real directory at that path — don't clobber.
                continue
            }
            try {
                New-Item -Path $tgt -ItemType Junction -Target $source -Force | Out-Null
                Write-Host "  [memory-manager] linked new profile $pName ($dirName)" -ForegroundColor Green
            } catch {
                Write-Host "  [memory-manager] failed to link $pName ($dirName) : $_" -ForegroundColor Red
            }
        }
    }
}

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
    $gatewayScript = Join-Path $HermesHome "gateway-service\Hermes_Gateway.cmd"

    Write-Host "Removing: $backendDir" -ForegroundColor Yellow
    if (Test-Path $backendDir) { Remove-Item -Recurse -Force $backendDir }

    Write-Host "Removing: $desktopDir" -ForegroundColor Yellow
    if (Test-Path $desktopDir) { Remove-Item -Recurse -Force $desktopDir }

    # Strip our auto-link lines from the gateway startup script so we don't
    # leave a dangling reference to a script we just deleted. We match the
    # marker comment plus the powershell line that follows it.
    if (Test-Path $gatewayScript) {
        $marker = "[memory-manager] auto-link"
        $lines  = Get-Content -LiteralPath $gatewayScript
        $kept   = @()
        $skip   = $false
        foreach ($line in $lines) {
            if ($skip) { $skip = $false; continue }
            if ($line -match [regex]::Escape($marker)) {
                # Drop this marker line and the very next line (our powershell call).
                $skip = $true
                continue
            }
            $kept += $line
        }
        # Trim trailing blank lines to keep the file tidy.
        while ($kept.Count -gt 0 -and $kept[-1] -match '^\s*$') { $kept = $kept[0..($kept.Count - 2)] }
        $kept += ""
        [System.IO.File]::WriteAllLines($gatewayScript, $kept)
        Write-Host "Stripped auto-link lines from: $gatewayScript" -ForegroundColor Yellow
    }

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

        # Write uninstall script for Windows (using byte-level write to avoid here-string nesting issues)
        $u = '$ErrorActionPreference = "Stop"'
        $u += "`n" + '$PLUGIN_ID = "' + $PLUGIN_ID + '"'
        $u += "`n" + '$HERMES_HOME = "' + $HermesHome + '"'
        $u += "`n" + 'Write-Host "Uninstalling $PLUGIN_ID..." -ForegroundColor Yellow'
        $u += "`n" + '$backendDir = Join-Path $HERMES_HOME "plugins\$PLUGIN_ID"'
        $u += "`n" + '$desktopDir = Join-Path $HERMES_HOME "desktop-plugins\$PLUGIN_ID"'
        $u += "`n" + 'if (Test-Path $backendDir) { Remove-Item -Recurse -Force $backendDir }'
        $u += "`n" + 'if (Test-Path $desktopDir) { Remove-Item -Recurse -Force $desktopDir }'
        $u += "`n" + '$disableScript = @'''
        $u += "`n" + 'import sys'
        $u += "`n" + 'from pathlib import Path'
        $u += "`n" + 'hermes_home = Path(r"$HERMES_HOME")'
        $u += "`n" + 'plugin_id = "$PLUGIN_ID"'
        $u += "`n" + 'try:'
        $u += "`n" + '    sys.path.insert(0, str(hermes_home / "hermes-agent"))'
        $u += "`n" + '    from hermes_cli.config import load_config, save_config'
        $u += "`n" + '    cfg = load_config()'
        $u += "`n" + '    plugins = cfg.setdefault("plugins", {})'
        $u += "`n" + '    enabled = plugins.get("enabled") or []'
        $u += "`n" + '    if plugin_id in enabled:'
        $u += "`n" + '        enabled.remove(plugin_id)'
        $u += "`n" + '        plugins["enabled"] = sorted(enabled)'
        $u += "`n" + '        save_config(cfg)'
        $u += "`n" + '        print(f"  Removed {plugin_id} from plugins.enabled")'
        $u += "`n" + 'except Exception:'
        $u += "`n" + '    import subprocess'
        $u += "`n" + '    subprocess.run(["hermes", "plugins", "disable", plugin_id], check=False)'
        $u += "`n" + "'@"
        $u += "`n" + '$disableScript | python -'
        $u += "`n" + 'Write-Host "$PLUGIN_ID uninstalled." -ForegroundColor Green'
        $u += "`n" + 'Write-Host "Restart Hermes Desktop to apply."'
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText((Join-Path $backendDir "uninstall.ps1"), $u, $enc)

        Enable-Plugin -HermesHome $HermesHome -PluginId $PLUGIN_ID

        # One-shot link pass right after install so every existing profile
        # has plugins/ available immediately.
        Write-Host ""
        Write-Host "Linking plugins to all profiles..." -ForegroundColor Cyan
        Ensure-ProfilePluginsLinks -HermesHome $HermesHome

        # Wire ensure-links into the Hermes gateway startup script so any
        # profile created later (e.g. via the desktop UI's "+ New profile"
        # button) automatically picks up the memory-manager backend. The
        # write is idempotent — we only add the line if it isn't already
        # present, and a marker comment lets us recognise our own line.
        #
        # We also need a stable path the gateway script can call into, so
        # we copy this installer (and its sibling install.sh) into
        # <HERMES_HOME>/plugins/memory-manager/dashboard/ as "ensure.ps1"
        # / "ensure.sh". That way the gateway always invokes the same path
        # regardless of where the user originally ran the installer from.
        $ensureScript = Join-Path $backendDir "ensure.ps1"
        try {
            if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "install.ps1"))) {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Destination $ensureScript -Force
            } else {
                $url = "$REPO_BASE/install.ps1"
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
                $bytes = $resp.Content
                if ($bytes -is [string]) {
                    $enc = New-Object System.Text.UTF8Encoding $false
                    $bytes = $enc.GetBytes($bytes)
                }
                [System.IO.File]::WriteAllBytes($ensureScript, $bytes)
            }
        } catch {
            Write-Host "  Warning: could not stage ensure.ps1 (auto-link on startup will not be wired): $_" -ForegroundColor Yellow
        }
        $gatewayScript = Join-Path $HermesHome "gateway-service\Hermes_Gateway.cmd"
        $marker        = "[memory-manager] auto-link"
        if ((Test-Path $gatewayScript) -and (Test-Path $ensureScript)) {
            $existing = Get-Content -LiteralPath $gatewayScript -Raw -ErrorAction SilentlyContinue
            if ($existing -and ($existing -notmatch [regex]::Escape($marker))) {
                # Insert the auto-link hook before the gateway run command so it
                # executes on every startup BEFORE the gateway process starts.
                # The gateway line is the python(w).exe ... gateway run call.
                $lines = @(Get-Content -LiteralPath $gatewayScript)
                $insertLines = @(
                    "REM $marker ensure newly-created profiles pick up the memory-manager backend",
                    "powershell -NoProfile -ExecutionPolicy Bypass -File ""$ensureScript"" ensure-links >nul 2>&1",
                    ""
                )
                $newLines = @()
                $inserted = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if (-not $inserted -and ($lines[$i] -match 'pythonw?\.exe.*gateway\s+run')) {
                        $newLines = $lines[0..($i - 1)] + $insertLines + $lines[$i..($lines.Count - 1)]
                        $inserted = $true
                        break
                    }
                }
                if (-not $inserted) {
                    # No gateway-run line found — fall back to inserting before exit /b.
                    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                        if (-not $inserted -and ($lines[$i] -match '^exit\s+/b')) {
                            $newLines = $lines[0..($i - 1)] + $insertLines + $lines[$i..($lines.Count - 1)]
                            $inserted = $true
                            break
                        }
                    }
                }
                if (-not $inserted) {
                    $newLines = $lines + $insertLines
                }
                [System.IO.File]::WriteAllLines($gatewayScript, $newLines)
                Write-Host ""
                Write-Host "Wired auto-link into Hermes gateway startup:" -ForegroundColor Cyan
                Write-Host "  $gatewayScript"
                Write-Host "  ensure script: $ensureScript"
            } elseif ($existing -and ($existing -match [regex]::Escape($marker))) {
                Write-Host ""
                Write-Host "Hermes gateway startup already wired for auto-link (skipped)." -ForegroundColor Yellow
            } else {
                Write-Host ""
                Write-Host "Could not read gateway script to wire auto-link (skipped):" -ForegroundColor Yellow
                Write-Host "  $gatewayScript"
            }
        } else {
            Write-Host ""
            Write-Host "Hermes gateway script not found, skipped auto-link wiring:" -ForegroundColor Yellow
            Write-Host "  $gatewayScript"
            Write-Host "  (Create a profile once in Hermes Desktop so the script is generated, then re-run this installer.)"
        }

        Write-Host ""
        Write-Host "$PLUGIN_ID installed successfully." -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Restart Hermes Desktop (or run: hermes gateway restart)"
        Write-Host "  2. Open the sidebar - you will see a 'Memory Manager' entry."
        Write-Host "  3. Or use the command palette (Ctrl+K) and search 'Open Memory Manager'."
        Write-Host ""
        Write-Host "Auto-link new profiles:" -ForegroundColor Cyan
        Write-Host "  This installer has been wired into Hermes gateway startup so any"
        Write-Host "  profile you create later will automatically get the memory-manager"
        Write-Host "  backend AND desktop plugin (via junctions to <HERMES_HOME>/plugins"
        Write-Host "  and <HERMES_HOME>/desktop-plugins)."
        Write-Host ""
        Write-Host "To uninstall: powershell -ExecutionPolicy Bypass -File .\install.ps1 uninstall"
    }
    "uninstall" {
        Write-Host "Uninstalling $PLUGIN_ID..." -ForegroundColor Yellow
        Uninstall-Plugin -HermesHome $HermesHome -PluginId $PLUGIN_ID
    }
    "ensure-links" {
        # Idempotent: re-link any profile that's missing <profile>/plugins or
        # <profile>/desktop-plugins. Intended to be called from Hermes'
        # startup script so freshly-created profiles pick up the
        # memory-manager backend AND desktop plugin automatically.
        Ensure-ProfilePluginsLinks -HermesHome $HermesHome
    }
    default {
        Write-Host "Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [install|uninstall|ensure-links]" -ForegroundColor Red
        exit 1
    }
}

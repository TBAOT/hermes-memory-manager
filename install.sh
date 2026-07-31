#!/usr/bin/env bash
# Memory Manager plugin installer for Linux/macOS.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.sh | bash
#
# Or locally:
#   bash install.sh
#   bash install.sh ensure-links   # re-link any profile missing <profile>/plugins
#   bash install.sh uninstall

set -euo pipefail

PLUGIN_ID="memory-manager"
REPO_BASE="https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main"

# --- Resolve HERMES_HOME -----------------------------------------------------
if [[ -n "${HERMES_HOME:-}" ]]; then
    HERMES_HOME="$HERMES_HOME"
elif [[ -n "${LOCALAPPDATA:-}" && -d "$LOCALAPPDATA/hermes" ]]; then
    HERMES_HOME="$LOCALAPPDATA/hermes"
else
    HERMES_HOME="$HOME/.hermes"
fi

if [[ ! -d "$HERMES_HOME" ]]; then
    echo "Hermes home not found at: $HERMES_HOME" >&2
    echo "Install Hermes first, then re-run this script." >&2
    exit 1
fi

echo "Hermes home: $HERMES_HOME"

# --- Locate source files -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

fetch_file() {
    local relative="$1"
    local url_path="$2"
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$relative" ]]; then
        echo "  Using local file: $SCRIPT_DIR/$relative"
        cat "$SCRIPT_DIR/$relative"
    else
        local url="$REPO_BASE/$url_path"
        echo "  Downloading $url"
        curl -fsSL "$url"
    fi | sed '1s/^\xEF\xBB\xBF//'   # strip BOM if present
}

# --- Create directories ------------------------------------------------------
BACKEND_DIR="$HERMES_HOME/plugins/$PLUGIN_ID/dashboard"
DESKTOP_DIR="$HERMES_HOME/desktop-plugins/$PLUGIN_ID"

# --- Profile-link helper (idempotent) ---------------------------------------
# Walks <HERMES_HOME>/profiles/* and ensures each profile has a "plugins"
# entry pointing back at <HERMES_HOME>/plugins. This is what lets a
# freshly-created profile pick up dashboard plugins (like memory-manager)
# without re-running the installer. Safe + cheap to call on every Hermes
# startup — it only creates the symlink when missing, never overwrites a
# real directory, and exits silently when there are no profiles yet.
ensure_profile_plugins_links() {
    local source_plugins="$HERMES_HOME/plugins"
    local profiles_dir="$HERMES_HOME/profiles"
    [[ -d "$source_plugins" ]] || return 0
    [[ -d "$profiles_dir" ]] || return 0
    for p in "$profiles_dir"/*/; do
        [[ -d "$p" ]] || continue
        local pname
        pname=$(basename "$p")
        local tgt="$p/plugins"
        if [[ -e "$tgt" || -L "$tgt" ]]; then
            continue
        fi
        if ln -sfn "$source_plugins" "$tgt" 2>/dev/null; then
            echo "  [memory-manager] linked new profile: $pname"
        else
            echo "  [memory-manager] failed to link $pname" >&2
        fi
    done
}

# --- Subcommand dispatch ------------------------------------------------------
ACTION="${1:-install}"

case "$ACTION" in
    ensure-links)
        ensure_profile_plugins_links
        exit 0
        ;;
    uninstall)
        echo "Uninstalling $PLUGIN_ID..."
        rm -rf "$HERMES_HOME/plugins/$PLUGIN_ID" 2>/dev/null || true
        rm -rf "$HERMES_HOME/desktop-plugins/$PLUGIN_ID" 2>/dev/null || true
        echo "  Removed backend:  $HERMES_HOME/plugins/$PLUGIN_ID"
        echo "  Removed desktop:  $HERMES_HOME/desktop-plugins/$PLUGIN_ID"
        echo ""
        echo "Now run: hermes plugins disable $PLUGIN_ID"
        exit 0
        ;;
    install) ;;
    *)
        echo "Usage: bash install.sh [install|uninstall|ensure-links]" >&2
        exit 1
        ;;
esac

echo "Creating directories..."
mkdir -p "$BACKEND_DIR"
mkdir -p "$DESKTOP_DIR"

# --- Write backend files -----------------------------------------------------
echo "Installing backend (plugin_api.py + manifest.json)..."
fetch_file "python/dashboard/plugin_api.py" "python/dashboard/plugin_api.py" > "$BACKEND_DIR/plugin_api.py"
fetch_file "python/dashboard/manifest.json" "python/dashboard/manifest.json" > "$BACKEND_DIR/manifest.json"

# --- Write desktop plugin ----------------------------------------------------
echo "Installing desktop plugin (plugin.js)..."
fetch_file "desktop/plugin.js" "desktop/plugin.js" > "$DESKTOP_DIR/plugin.js"

# --- Enable the plugin -------------------------------------------------------
# The dashboard plugin API loader (web_server._mount_plugin_api_routes)
# gates user plugins on the `plugins.enabled` list in config.yaml. We edit
# the config directly via Hermes' own config module so the format matches
# what `hermes plugins enable` would produce.
echo "Enabling plugin in config.yaml..."
# Prefer Hermes' own Python venv (it has hermes_cli.config + ruamel.yaml).
# Fall back to system python3 if the venv isn't where we expect.
HERMES_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
if [[ ! -x "$HERMES_PY" ]]; then
    HERMES_PY="python3"
fi
"$HERMES_PY" - "$HERMES_HOME" "$PLUGIN_ID" <<'PY'
import sys
from pathlib import Path
hermes_home = Path(sys.argv[1])
plugin_id = sys.argv[2]
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
PY

# --- Link plugins to all profiles (one-shot + also idempotent for re-runs) --
echo ""
echo "Linking plugins to all profiles..."
ensure_profile_plugins_links

echo ""
echo "Memory Manager plugin installed successfully."
echo ""
echo "Next steps:"
echo "  1. Restart Hermes Desktop (or run: hermes gateway restart)"
echo "  2. Open the sidebar — you'll see a \"Memory Manager\" entry."
echo "  3. Or use the command palette (Ctrl+K) and search \"Open Memory Manager\"."
echo ""
echo "Auto-link new profiles:"
echo "  This installer has been wired into Hermes gateway startup so any"
echo "  profile you create later will automatically get the memory-manager"
echo "  backend mounted (via a symlink to <HERMES_HOME>/plugins)."
echo ""
echo "To uninstall: bash install.sh uninstall"

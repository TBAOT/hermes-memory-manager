#!/usr/bin/env bash
# hermes-install.sh — Install/uninstall memory-manager plugin for Hermes Agent.
#
# Usage:
#   bash hermes-install.sh          # install
#   bash hermes-install.sh --uninstall   # uninstall
#
# Respects HERMES_HOME.  Operates entirely outside the Hermes source tree
# so it can be used when the plugin is installed from the git repo.
set -euo pipefail

PLUGIN_ID="memory-manager"
REPO_BASE="https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# --- Resolve Python / config tool -------------------------------------------
HERMES_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
if [[ ! -x "$HERMES_PY" ]]; then
    HERMES_PY="python3"
fi

# --- Helpers -----------------------------------------------------------------
enable_plugin() {
    # Add plugin to plugins.enabled in config.yaml via Hermes' own config
    # helper so the format stays consistent with `hermes plugins enable`.
    "$HERMES_PY" - "$HERMES_HOME" "$PLUGIN_ID" <<'PY'
import sys
from pathlib import Path
hermes_home = Path(sys.argv[1])
plugin_id = sys.argv[2]

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
        print(f'  Added {plugin_id} to plugins.enabled')
    else:
        print(f'  {plugin_id} already in plugins.enabled')
except Exception as exc:
    # Fallback: touch config.yaml via Hermes CLI itself
    import subprocess
    subprocess.run(['hermes', 'plugins', 'enable', plugin_id], check=False)
PY
}

install_files() {
    local backend_dir="$HERMES_HOME/plugins/$PLUGIN_ID/dashboard"
    local desktop_dir="$HERMES_HOME/desktop-plugins/$PLUGIN_ID"

    mkdir -p "$backend_dir"
    mkdir -p "$desktop_dir"

    # Determine source: prefer local repo files over remote download
    local src_backend="$SOURCE_DIR/python/dashboard"
    local src_desktop="$SOURCE_DIR/desktop"

    if [[ -f "$src_backend/plugin_api.py" ]]; then
        cp "$src_backend/plugin_api.py" "$backend_dir/plugin_api.py"
        cp "$src_backend/manifest.json" "$backend_dir/manifest.json"
    else
        curl -fsSL "$REPO_BASE/python/dashboard/plugin_api.py" -o "$backend_dir/plugin_api.py"
        curl -fsSL "$REPO_BASE/python/dashboard/manifest.json" -o "$backend_dir/manifest.json"
    fi

    if [[ -f "$src_desktop/plugin.js" ]]; then
        cp "$src_desktop/plugin.js" "$desktop_dir/plugin.js"
    else
        curl -fsSL "$REPO_BASE/desktop/plugin.js" -o "$desktop_dir/plugin.js"
    fi

    # Write plugin.yaml for Hermes native discovery
    cp "$SOURCE_DIR/plugin.yaml" "$HERMES_HOME/plugins/$PLUGIN_ID/plugin.yaml"

    # Write uninstall script
    cat > "$HERMES_HOME/plugins/$PLUGIN_ID/uninstall.sh" <<UEOF
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ID="$PLUGIN_ID"
HERMES_HOME="$HERMES_HOME"
echo "Uninstalling \$PLUGIN_ID..."
rm -rf "\$HERMES_HOME/plugins/\$PLUGIN_ID"
rm -rf "\$HERMES_HOME/desktop-plugins/\$PLUGIN_ID"
hermes plugins disable "\$PLUGIN_ID" 2>/dev/null || true
echo "Done."
UEOF
    chmod +x "$HERMES_HOME/plugins/$PLUGIN_ID/uninstall.sh"
}

# --- Main ---------------------------------------------------------------------
case "${1:-install}" in
    install)
        echo "Installing $PLUGIN_ID → $HERMES_HOME"
        install_files
        enable_plugin
        echo ""
        echo "$PLUGIN_ID installed successfully."
        echo "Next: restart Hermes Desktop or run 'hermes gateway restart'."
        echo "Then open the sidebar — you'll see a 'Memory Manager' entry."
        ;;
    uninstall|remove)
        echo "Uninstalling $PLUGIN_ID from $HERMES_HOME"
        rm -rf "$HERMES_HOME/plugins/$PLUGIN_ID"
        rm -rf "$HERMES_HOME/desktop-plugins/$PLUGIN_ID"
        "$HERMES_PY" - "$HERMES_HOME" "$PLUGIN_ID" uninstall <<'PY'
import sys
from pathlib import Path
hermes_home = Path(sys.argv[1])
plugin_id = sys.argv[2]
try:
    sys.path.insert(0, str(hermes_home / 'hermes-agent'))
    from hermes_cli.config import load_config, save_config
    cfg = load_config()
    plugins = cfg.setdefault('plugins', {})
    enabled = plugins.get('enabled') or []
    if plugin_id in enabled:
        enabled.remove(plugin_id)
        plugins['enabled'] = sorted(enabled)
        save_config(cfg)
        print(f'  Removed {plugin_id} from plugins.enabled')
except Exception:
    import subprocess
    subprocess.run(['hermes', 'plugins', 'disable', plugin_id], check=False)
PY
        echo "Done. Restart Hermes Desktop to apply."
        ;;
    *)
        echo "Usage: bash hermes-install.sh [install|uninstall]" >&2
        exit 1
        ;;
esac

#!/usr/bin/env bash
# hermes-install.sh — Install/uninstall memory-manager plugin for Hermes Agent.
#
# Usage:
#   bash hermes-install.sh          # install
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
    # Try plain "python" first (Windows native Python), then "python3"
    if command -v python &>/dev/null && python --version &>/dev/null; then
        HERMES_PY="python"
    elif command -v python3 &>/dev/null; then
        HERMES_PY="python3"
    else
        echo "Python not found. Install Hermes or Python first." >&2
        exit 1
    fi
fi

# --- Resolve config.py path -------------------------------------------------
# Hermes CLI config helpers may not be importable in all Hermes installs.
# We try to locate hermes_cli.config directly.
HERMES_CLI_DIR=""
if [[ -d "$HERMES_HOME/hermes-agent/hermes_cli" ]]; then
    HERMES_CLI_DIR="$HERMES_HOME/hermes-agent"
elif [[ -d "$HERMES_HOME/src/hermes_cli" ]]; then
    HERMES_CLI_DIR="$HERMES_HOME/src"
fi

# --- Helpers -----------------------------------------------------------------
enable_plugin() {
    # Add plugin to plugins.enabled in config.yaml.
    # Strategy: write a tiny Python helper to a temp file and run it.
    # This avoids bash heredoc issues on Windows (MSYS passes stdin oddly).
    local python_script
    python_script=$(mktemp --suffix=.py)
    cat > "$python_script" <<'PYEOF'
import sys
import os
from pathlib import Path

hermes_home = Path(sys.argv[1])
plugin_id = sys.argv[2]
hermes_cli_dir = sys.argv[3] if len(sys.argv) > 3 else ""

# Ensure hermes_cli is importable
if hermes_cli_dir and hermes_cli_dir not in sys.path:
    sys.path.insert(0, hermes_cli_dir)

try:
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
    # Last resort: use Hermes CLI itself
    print(f"  hermes_cli.config not available ({exc}); falling back to hermes CLI")
    import subprocess
    subprocess.run(["hermes", "plugins", "enable", plugin_id], check=False)
PYEOF
    "$HERMES_PY" "$python_script" "$HERMES_HOME" "$HERMES_CLI_DIR"
    rm -f "$python_script"
}

disable_plugin() {
    local python_script
    python_script=$(mktemp --suffix=.py)
    cat > "$python_script" <<'PYEOF'
import sys
from pathlib import Path

hermes_home = Path(sys.argv[1])
plugin_id = sys.argv[2]
hermes_cli_dir = sys.argv[3] if len(sys.argv) > 3 else ""

if hermes_cli_dir and hermes_cli_dir not in sys.path:
    sys.path.insert(0, hermes_cli_dir)

try:
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
PYEOF
    "$HERMES_PY" "$python_script" "$HERMES_HOME" "$HERMES_CLI_DIR"
    rm -f "$python_script"
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

    # Write uninstall.sh helper in the plugin directory
    cat > "$backend_dir/uninstall.sh" <<'UNINST'
#!/usr/bin/env bash
PLUGIN_ID="memory-manager"
HERMES_HOME="$(cd "$(dirname "$0")/../../../.." && pwd)"
# Navigate up from plugins/<id>/dashboard/ to HERMES_HOME
HERMES_HOME="$(cd "$HERMES_HOME/../../.." && pwd)"
echo "Uninstalling $PLUGIN_ID..."
rm -rf "$HERMES_HOME/plugins/$PLUGIN_ID"
rm -rf "$HERMES_HOME/desktop-plugins/$PLUGIN_ID"
hermes plugins disable "$PLUGIN_ID" 2>/dev/null || true
echo "Done."
UNINST
    chmod +x "$backend_dir/uninstall.sh"
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
        echo ""
        echo "To uninstall, run: hermes-install.sh uninstall"
        ;;
    uninstall|remove)
        echo "Uninstalling $PLUGIN_ID from $HERMES_HOME"
        rm -rf "$HERMES_HOME/plugins/$PLUGIN_ID"
        rm -rf "$HERMES_HOME/desktop-plugins/$PLUGIN_ID"
        disable_plugin
        echo "Done. Restart Hermes Desktop to apply."
        ;;
    *)
        echo "Usage: bash hermes-install.sh [install|uninstall]" >&2
        exit 1
        ;;
esac

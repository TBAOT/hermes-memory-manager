# Hermes Memory Manager ☤

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)](https://github.com/nousresearch/hermes-agent)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Hermes Agent](https://img.shields.io/badge/Hermes_Agent-Desktop_Plugin-8A2BE2)](https://github.com/nousresearch/hermes-agent)

A desktop plugin for [Hermes Agent](https://github.com/nousresearch/hermes-agent) that lets you view and edit your agent's **MEMORY.md** and **USER.md** directly from the desktop UI — with automatic profile switching.

> No more `cat ~/.hermes/memories/MEMORY.md` in the terminal. Open the sidebar, edit, and save — that's it.

---

## Features

| Feature | Description |
|---------|-------------|
| **Sidebar entry** | One click to open the memory editor |
| **Tabbed editing** | Switch between **Agent Memory** and **User Profile** |
| **Profile-aware** | Switch profiles in the desktop, memory content follows automatically |
| **Safe saves** | Creates `.bak` backup before every write |
| **Unsaved change detection** | Warns before switching tabs with dirty state |
| **Command palette** | Press `Ctrl+K` and search "Open Memory Manager" |
| **Character counter + progress bar** | Shows usage against your configured char limit |

---

## Screenshots

| Sidebar Entry | Memory Editor |
|---------------|---------------|
| ![Sidebar Entry](screenshots/sidebar-entry.png) | ![Memory Editor](screenshots/memory-editor.png) |

> Click **Memory Manager** in the left sidebar to open the memory editor, where you can view and edit **Agent Memory** / **User Profile** with automatic multi-profile switching.

---

## Installation

### One-liner (recommended)

**Windows (PowerShell 5+)**

```powershell
irm https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.ps1 | iex
```

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.sh | bash
```

The installer will:

1. Place backend files → `<HERMES_HOME>/plugins/memory-manager/dashboard/`
2. Place desktop plugin → `<HERMES_HOME>/desktop-plugins/memory-manager/plugin.js`
3. Enable the plugin in `config.yaml` (`hermes plugins enable memory-manager`)
4. Link the backend into every existing profile (so memory-manager works no matter which profile is active)
5. Wire an **auto-link hook** into the Hermes gateway startup script — so any profile you create later automatically gets the memory-manager backend mounted too. You don't need to re-run the installer when you add a new profile.
6. Prompt you to restart Hermes Desktop

### Manual installation

```bash
# 1. Backend
mkdir -p ~/.hermes/plugins/memory-manager/dashboard
cp python/dashboard/{manifest.json,plugin_api.py} ~/.hermes/plugins/memory-manager/dashboard/

# 2. Desktop plugin
mkdir -p ~/.hermes/desktop-plugins/memory-manager
cp desktop/plugin.js ~/.hermes/desktop-plugins/memory-manager/

# 3. Enable
hermes plugins enable memory-manager

# 4. Restart the gateway
hermes gateway restart
```

---

## Usage

1. **Launch** Hermes Desktop
2. Click **Memory Manager** (database icon) in the left sidebar, or press `Ctrl+K` and search "Open Memory Manager"
3. Switch between **Agent Memory** / **User Profile** tabs
4. Edit freely — click **Save** to persist (a `.bak` copy is kept alongside)
5. Switch profiles from the top bar — content reloads automatically

---

## Project Structure

```text
hermes-memory-manager/
├── python/
│   └── dashboard/
│       ├── manifest.json          # Dashboard plugin manifest
│       └── plugin_api.py          # FastAPI router (GET/POST /content, GET /profile)
├── desktop/
│   └── plugin.js                  # Desktop runtime plugin (route, sidebar, palette)
├── install.ps1                    # Windows installer (+ ensure-links subcommand)
├── install.sh                     # Unix installer (+ ensure-links subcommand)
├── plugin.yaml                    # Native Hermes plugin manifest
└── README.md
```

---

## Multi-Profile Support

Hermes uses **profiles** (separate config/memory directories for different contexts). The one-line installer wires up two things:

1. **One-shot link** — every existing profile under `<HERMES_HOME>/profiles/*` gets a `plugins` junction pointing at `<HERMES_HOME>/plugins`, so the memory-manager backend is visible immediately.
2. **Auto-link on startup** — the installer appends an idempotent line to `<HERMES_HOME>/gateway-service/Hermes_Gateway.cmd` (Windows) that calls `install.ps1 ensure-links` (or `install.sh ensure-links` on Linux/macOS) every time the gateway starts. Whenever you create a brand-new profile in the Hermes UI, the next gateway restart automatically creates the missing junction for it. No manual re-install needed.

The auto-link logic is safe and cheap to run repeatedly: it only creates the junction when it's missing, never overwrites a real directory, and exits silently when there are no profiles yet.

If you ever need to run the auto-link check manually:

- **Windows:** `powershell -ExecutionPolicy Bypass -File <HERMES_HOME>\plugins\memory-manager\dashboard\ensure.ps1 ensure-links`
- **Linux / macOS:** `bash <HERMES_HOME>/plugins/memory-manager/dashboard/ensure.sh ensure-links`

---

## API Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/plugins/memory-manager/content` | Returns `{memory, user}` strings |
| POST | `/api/plugins/memory-manager/content` | Saves `{memory?, user?}` (only provided keys) |
| GET | `/api/plugins/memory-manager/profile` | Returns `{profile, hermes_home, memory_dir}` |

All routes are profile-aware — `get_hermes_home()` resolves to the active profile's directory automatically.

---

## Uninstall

**Windows:**

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 uninstall
```

**Linux / macOS:**

```bash
bash install.sh uninstall
```

Both variants:

- remove the backend at `<HERMES_HOME>/plugins/memory-manager/`
- remove the desktop plugin at `<HERMES_HOME>/desktop-plugins/memory-manager/`
- strip the auto-link lines that the installer added to `Hermes_Gateway.cmd`
- remove `memory-manager` from `plugins.enabled` in `config.yaml`

---

## Development

- **Desktop plugin** is hot-reloaded: edit `plugin.js`, save, and the changes apply immediately — no restart needed.
- **Backend API** requires a gateway restart: `hermes gateway restart` (or restart Hermes Desktop).
- The plugin uses the Hermes Plugin SDK (`@hermes/plugin-sdk`) — available imports: `host`, `useValue`, `useQuery`, `Button`, `Textarea`, `Loader`, etc.

---

## Compatibility

- Hermes Agent Desktop (supports `desktop-plugins/` runtime plugin system)
- Python 3.10+ (FastAPI + Pydantic v2, bundled with Hermes)
- Windows / Linux / macOS

---

## License

MIT

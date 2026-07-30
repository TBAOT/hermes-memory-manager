"""Memory Manager plugin backend.

Provides REST endpoints for reading and writing the profile-scoped
MEMORY.md and USER.md files. Routes are mounted by the Hermes web
server under ``/api/plugins/memory-manager/``.

The plugin uses :func:`hermes_constants.get_hermes_home` so the same
code correctly resolves the active profile's memory directory whether
the gateway is launched per-profile (desktop default) or scoped via
a context-local HERMES_HOME override.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Dict

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from hermes_constants import get_hermes_home


router = APIRouter()


# Memory files live under ``<hermes_home>/memories/``. The ``memories``
# directory is profile-scoped because ``get_hermes_home()`` follows the
# active profile's HERMES_HOME.
MEMORY_FILES: Dict[str, str] = {
    "memory": "MEMORY.md",
    "user": "USER.md",
}

# Default size limit: 1 MiB total for both files.
DEFAULT_MAX_SIZE_BYTES = 1_048_576


class MemoryContent(BaseModel):
    """Request body for saving memory content."""

    memory: str | None = None
    user: str | None = None


class MemorySettings(BaseModel):
    """Request / response body for plugin settings."""

    max_size_bytes: int = DEFAULT_MAX_SIZE_BYTES


def _memory_dir() -> Path:
    """Return the active profile's memories directory."""
    return get_hermes_home() / "memories"


def _settings_path() -> Path:
    """Return the path to the plugin's settings JSON file."""
    return _memory_dir() / ".memory-manager-settings.json"


def _load_settings() -> MemorySettings:
    """Load persisted settings or return defaults."""
    path = _settings_path()
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            return MemorySettings(**raw)
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    return MemorySettings()


def _save_settings(settings: MemorySettings) -> None:
    """Persist settings to disk."""
    path = _settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(settings.model_dump_json(indent=2), encoding="utf-8")
    except OSError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to save settings: {exc}",
        ) from exc


def _read_file(path: Path) -> str:
    """Read a memory file, returning empty string when missing."""
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to read {path.name}: {exc}",
        ) from exc


def _write_file(path: Path, content: str) -> None:
    """Write a memory file, backing up the previous version first."""
    path.parent.mkdir(parents=True, exist_ok=True)
    # Back up the existing file so users can recover from accidental edits.
    if path.exists():
        bak_path = path.with_suffix(path.suffix + ".bak")
        try:
            shutil.copy2(path, bak_path)
        except OSError:
            # Backup failure should not block the write — just skip it.
            pass
    try:
        path.write_text(content, encoding="utf-8")
    except OSError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to save {path.name}: {exc}",
        ) from exc


def _file_size(path: Path) -> int:
    """Return the size of a file in bytes, or 0 if missing."""
    try:
        return path.stat().st_size if path.exists() else 0
    except OSError:
        return 0


def _format_size(bytes_val: int) -> str:
    """Human-readable size string."""
    if bytes_val >= 1_048_576:
        return f"{bytes_val / 1_048_576:.2f} MB"
    if bytes_val >= 1024:
        return f"{bytes_val / 1024:.1f} KB"
    return f"{bytes_val} B"


@router.get("/content")
async def get_memory_content() -> Dict[str, str]:
    """Return the current profile's MEMORY.md and USER.md contents."""
    mem_dir = _memory_dir()
    return {key: _read_file(mem_dir / fname) for key, fname in MEMORY_FILES.items()}


@router.post("/content")
async def save_memory_content(body: MemoryContent) -> Dict[str, object]:
    """Save updated memory content for the current profile.

    Only keys present in the request body are written; missing keys are
    left untouched. A ``.bak`` snapshot of the previous file is kept
    next to the original.
    """
    mem_dir = _memory_dir()
    settings = _load_settings()
    written: list[str] = []
    total_after = 0
    for key, fname in MEMORY_FILES.items():
        value = getattr(body, key)
        if value is None:
            total_after += _file_size(mem_dir / fname)
            continue
        _write_file(mem_dir / fname, value)
        written.append(fname)
        total_after += len(value.encode("utf-8"))

    if total_after > settings.max_size_bytes:
        # Warn but don't block — the UI will show over-limit state.
        pass

    return {"status": "success", "written": written}


@router.get("/profile")
async def get_profile_info() -> Dict[str, object]:
    """Return the active profile's name and memory directory path.

    Helps the UI show which profile the user is currently editing, and
    confirms that the backend is resolving the same HERMES_HOME the
    desktop is showing.
    """
    home = get_hermes_home()
    mem_dir = home / "memories"
    # The profile name is the last path component when running under a
    # profile-scoped HERMES_HOME (``~/.hermes/profiles/<name>``). When
    # running under the default home, fall back to ``default``.
    parts = home.parts
    if len(parts) >= 2 and parts[-2] == "profiles":
        profile_name = parts[-1]
    else:
        profile_name = "default"
    return {
        "profile": profile_name,
        "hermes_home": str(home),
        "memory_dir": str(mem_dir),
    }


@router.get("/stats")
async def get_memory_stats() -> Dict[str, object]:
    """Return file sizes and usage statistics."""
    mem_dir = _memory_dir()
    settings = _load_settings()
    sizes = {}
    total = 0
    for key, fname in MEMORY_FILES.items():
        size = _file_size(mem_dir / fname)
        sizes[key] = {
            "bytes": size,
            "formatted": _format_size(size),
        }
        total += size

    return {
        "sizes": sizes,
        "total_bytes": total,
        "total_formatted": _format_size(total),
        "max_size_bytes": settings.max_size_bytes,
        "max_size_formatted": _format_size(settings.max_size_bytes),
        "usage_percent": round(total / settings.max_size_bytes * 100, 1) if settings.max_size_bytes else 0,
    }


@router.get("/settings")
async def get_memory_settings() -> MemorySettings:
    """Return the current plugin settings."""
    return _load_settings()


@router.post("/settings")
async def save_memory_settings(body: MemorySettings) -> MemorySettings:
    """Save plugin settings."""
    _save_settings(body)
    return body

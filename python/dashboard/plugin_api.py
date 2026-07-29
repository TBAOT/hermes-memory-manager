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


class MemoryContent(BaseModel):
    """Request body for saving memory content."""

    memory: str | None = None
    user: str | None = None


def _memory_dir() -> Path:
    """Return the active profile's memories directory."""
    return get_hermes_home() / "memories"


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
    written: list[str] = []
    for key, fname in MEMORY_FILES.items():
        value = getattr(body, key)
        if value is None:
            continue
        _write_file(mem_dir / fname, value)
        written.append(fname)
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

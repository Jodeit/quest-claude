"""Scans on disk: one folder per scan holding the RoomPlan export, the edits and the built model.

    $ROOMSCAN_HOME (default ~/.local/share/roomscan)/scans/<id>/
        capture.json      the RoomPlan export, exactly as received
        meta.json         name, when it last arrived, where from, stage (live while the phone is
                          still scanning, final once RoomPlan has processed it)
        edits.json        everything the LLM changed (see edits.py)
        model.ifc         the last model built
"""

from __future__ import annotations

import json
import os
import re
import secrets
import time
from pathlib import Path
from typing import Any

from . import edits as E
from .capture import Capture, read_capture

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,80}$")


def default_home() -> Path:
    return Path(os.environ.get("ROOMSCAN_HOME") or Path.home() / ".local/share/roomscan")


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "scan"


class ScanNotFound(KeyError):
    pass


class Store:
    def __init__(self, home: Path | None = None):
        self.home = Path(home) if home else default_home()
        self.scans = self.home / "scans"
        self.scans.mkdir(parents=True, exist_ok=True)
        self._cache: dict[str, tuple[float, Capture]] = {}

    def dir(self, scan_id: str) -> Path:
        if not ID_RE.match(scan_id or ""):
            raise ScanNotFound(f"not a scan id: {scan_id!r}")
        d = self.scans / scan_id
        if not (d / "capture.json").exists():
            raise ScanNotFound(f"no scan {scan_id!r}; list_scans shows the ones there are")
        return d

    # ------------------------------------------------------------ scans

    def add(self, data: dict, name: str | None = None, source: str = "upload", stage: str = "final") -> str:
        read_capture(data)  # refuse anything that won't parse before storing it
        base = f"{time.strftime('%Y%m%d-%H%M%S')}-{_slug(name or 'scan')}"
        scan_id = base
        while (self.scans / scan_id).exists():
            scan_id = f"{base}-{secrets.token_hex(2)}"
        d = self.scans / scan_id
        d.mkdir(parents=True)
        (d / "capture.json").write_text(json.dumps(data))
        (d / "meta.json").write_text(json.dumps(
            {"name": name or scan_id, "received": time.time(), "source": source, "stage": stage, "updates": 1}))
        return scan_id

    def replace(self, scan_id: str, data: dict, stage: str = "final", name: str | None = None) -> dict:
        """Swap in a newer capture of the same room (a phone streaming while it scans). Edits stay;
        they refer to element ids, which can shift while a scan is still live. A name renames it (the
        phone starts scanning before the room is named)."""
        d = self.dir(scan_id)
        read_capture(data)
        tmp = d / "capture.tmp"
        tmp.write_text(json.dumps(data))
        tmp.replace(d / "capture.json")
        meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}
        meta.update({"received": time.time(), "stage": stage, "updates": int(meta.get("updates", 1)) + 1})
        if name:
            meta["name"] = name
        (d / "meta.json").write_text(json.dumps(meta))
        self._cache.pop(scan_id, None)
        return meta

    def import_file(self, path: str | Path, name: str | None = None) -> str:
        p = Path(path).expanduser()
        return self.add(json.loads(p.read_text()), name or p.stem, source=str(p))

    def list(self) -> list[dict[str, Any]]:
        out = []
        for d in sorted(self.scans.iterdir(), reverse=True):
            if not (d / "capture.json").exists():
                continue
            meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}
            out.append({
                "id": d.name,
                "name": meta.get("name", d.name),
                "received": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(meta.get("received", 0))),
                "stage": meta.get("stage", "final"),
                "has_edits": (d / "edits.json").exists(),
                "has_model": (d / "model.ifc").exists(),
            })
        return out

    def capture(self, scan_id: str) -> Capture:
        p = self.dir(scan_id) / "capture.json"
        mtime = p.stat().st_mtime
        hit = self._cache.get(scan_id)
        if hit and hit[0] == mtime:
            return hit[1]
        cap = read_capture(json.loads(p.read_text()))
        self._cache[scan_id] = (mtime, cap)
        return cap

    # ------------------------------------------------------------ edits

    def edits(self, scan_id: str) -> dict:
        p = self.dir(scan_id) / "edits.json"
        return E.normalise(json.loads(p.read_text()) if p.exists() else None)

    def save_edits(self, scan_id: str, e: dict) -> None:
        p = self.dir(scan_id) / "edits.json"
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(e, indent=1))
        tmp.replace(p)

    def model_path(self, scan_id: str) -> Path:
        return self.dir(scan_id) / "model.ifc"

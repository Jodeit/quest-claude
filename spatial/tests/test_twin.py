"""roomscan twin: a scan bundle -> a twin page folder. The sample has no mesh or frames, which is
the RoomPlan-only case: walls, spots and the page, no photo-real model."""

import json
import shutil
from pathlib import Path

from roomscan.twin import build_twin, publish_files

SAMPLE = Path(__file__).resolve().parents[1] / "samples" / "living-room.json"


def test_twin_from_roomplan_only_bundle(tmp_path):
    bundle = tmp_path / "scan"
    bundle.mkdir()
    shutil.copyfile(SAMPLE, bundle / "room.json")
    (bundle / "info.json").write_text(json.dumps({"name": "Living room", "date": "2026-11-23T20:00:00Z"}))
    out = tmp_path / "twin"
    twin = build_twin(bundle, out)
    assert twin["name"] == "Living room"
    assert twin["mesh"] is None
    assert len(twin["walls"]) >= 4 and all(w["length"] > 0 for w in twin["walls"])
    assert all(o["key"][0].isdigit() for o in twin["objects"])
    page = (out / "index.html").read_text()
    assert "<title>Living room Twin</title>" in page and "{{" not in page
    assert "twin.json" in publish_files(out)
    # Walls face into the room: the middle of the room is on each wall's normal side.
    c = twin["centre"]
    for w in twin["walls"]:
        mid = [(w["a"][0] + w["b"][0]) / 2, (w["a"][1] + w["b"][1]) / 2]
        assert (c[0] - mid[0]) * w["normal"][0] + (c[2] - mid[1]) * w["normal"][1] > 0

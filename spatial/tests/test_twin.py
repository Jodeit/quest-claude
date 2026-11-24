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


def _box_room():
    """A 4 x 3 m room, 2.5 m high, floor at y = 0, with a floor outline."""
    from roomscan.twin import Room
    def wall(cx, cz, ang, w):
        import math
        c, s = math.cos(ang), math.sin(ang)
        return {"transform": [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, cx, 1.25, cz, 1], "dimensions": [w, 2.5, 0]}
    import math
    walls = [wall(0, -1.5, 0, 4), wall(0, 1.5, 0, 4), wall(-2, 0, math.pi / 2, 3), wall(2, 0, math.pi / 2, 3)]
    floor = {"transform": [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1],
             "polygonCorners": [[-2, 1.5, 0], [2, 1.5, 0], [2, -1.5, 0], [-2, -1.5, 0]]}
    return Room({"walls": walls, "floors": [floor]})


def test_level_offset_finds_a_raised_floor():
    import numpy as np
    from roomscan.twin import level_offset
    room = _box_room()
    # A floor and a ceiling sheet, both 0.42 m too high, plus a table top.
    P, F = [], []
    for y, flip in ((0.42, False), (2.92, True), (1.17, False)):
        n = len(P)
        size = 0.6 if y == 1.17 else 1.8
        P += [[-size, y, -size], [size, y, -size], [size, y, size], [-size, y, size]]
        F += [[n, n + 2, n + 1], [n, n + 3, n + 2]] if not flip else [[n, n + 1, n + 2], [n, n + 2, n + 3]]
    off = level_offset(np.array(P, float), np.array(F), room)
    assert abs(off + 0.42) < 0.02


def test_room_outline_crops_outside():
    import numpy as np
    room = _box_room()
    inside = room.inside(np.array([[0, 0], [1.9, 1.4], [2.05, 0], [2.5, 0], [0, -3]], float))
    assert inside.tolist() == [True, True, True, False, False]

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


def _unit_mesh(with_front=True):
    """Triangles (centroids, areas, edge lengths) sampled on a 1 x 1 x 0.4 m unit's faces, centred on
    the origin, front facing +z."""
    import numpy as np
    pts = []
    g = np.linspace(-0.5, 0.5, 21)
    for a in g:
        for b in g:
            pts += [[a, b, -0.2], [-0.5, b, a * 0.4], [0.5, b, a * 0.4], [a, 0.5, b * 0.4], [a, -0.5, b * 0.4]]
            if with_front:
                pts.append([a, b, 0.2])
    cen = np.array(pts)
    return cen, np.full(len(cen), 0.0025), np.full(len(cen), 0.0254)


def test_measure_unit_confirms_edges_and_flags_missing_mesh():
    import numpy as np
    from roomscan.twin import measure_unit
    c, x, n, size = np.zeros(3), np.array([1.0, 0, 0]), np.array([0, 0, 1.0]), (1.0, 1.0, 0.4)
    m = measure_unit(c, x, n, size, *_unit_mesh())
    assert all(m["edges"][k]["confirmed"] for k in ("left", "right", "top", "bottom", "depth"))
    assert m["confidence"] == "high" and not m["confirm_with_tape"] and m["tolerance_in"] <= 1.5
    # No mesh anywhere near: everything unconfirmed, low confidence, wide tolerance.
    z = measure_unit(c, x, n, size, np.zeros((0, 3)), np.zeros(0), np.zeros(0))
    assert z["confidence"] == "low" and z["confirm_with_tape"] and z["tolerance_in"] >= 2.0
    # Mesh only on the right side: fewer confirmed edges, larger width tolerance.
    cen, area, el = _unit_mesh(with_front=False)
    part = cen[:, 0] > 0.3
    p = measure_unit(c, x, n, size, cen[part], area[part], el[part])
    assert not p["edges"]["left"]["confirmed"] and p["tolerance_in_by_dim"]["width"] > m["tolerance_in_by_dim"]["width"]


def test_spot_closeups_writes_upright_crop_and_falls_back(tmp_path):
    import numpy as np
    from roomscan.twin import Frame, Room, spot_closeups
    room = _box_room()
    # A 0.8 x 0.8 x 0.3 m unit against the back wall (z = -1.5), front toward +z.
    obj = {"transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0.5, -1.35, 1], "dimensions": [0.8, 0.8, 0.3], "category": {"storage": {}}}
    rd = {"objects": [obj, dict(obj, transform=[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1.2, 0.5, -1.35, 1])]}
    folder = tmp_path / "frames"
    folder.mkdir()
    rng = np.random.default_rng(0)
    Image = __import__("PIL.Image", fromlist=["Image"])
    Image.fromarray(rng.integers(60, 200, (480, 640, 3), dtype=np.uint8)).save(folder / "A.jpg")
    # Camera 2 m in front of unit 0, looking down -z; unit 1 is also in view but left out of the mesh test.
    pose = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0.5, 0.65, 1]
    f = Frame(dict(file="A.jpg", transform=pose, fx=500, fy=500, cx=320, cy=240, width=640, height=480), folder)
    # Mesh: the wall behind the units (z = -1.5) as a grid of small triangles.
    g = np.linspace(-1.9, 1.9, 40)
    P = np.array([[a, b, -1.35 + 0.15] for a in g for b in np.linspace(0, 2.4, 25)])
    F = np.array([[i, i + 1, i + 25] for i in range(len(P) - 26)])
    objects = [dict(key="1 Storage"), dict(key="2 Storage")]
    out = tmp_path / "out"
    (out / "img").mkdir(parents=True)
    done = spot_closeups(out, P, F, [f], rd, room, objects)
    assert done >= 1 and objects[0]["photos"] and (out / objects[0]["photos"][0]["path"]).exists()
    ph = objects[0]["photos"][0]
    assert ph["kind"] == "closeup" and ph["view_angle_deg"] < 20 and len(ph["camera"]) == 3
    assert all("measurement" in o for o in objects)
    # No frames at all: no photos, measurement still present and flagged.
    objects2 = [dict(key="1 Storage"), dict(key="2 Storage")]
    assert spot_closeups(out, P, F, [], rd, room, objects2) == 0
    assert objects2[0]["photos"] == [] and objects2[0]["measurement"]["confirm_with_tape"] is not None


def test_roomplan_only_twin_has_photos_and_measurement_fields(tmp_path):
    bundle = tmp_path / "scan"
    bundle.mkdir()
    shutil.copyfile(SAMPLE, bundle / "room.json")
    twin = build_twin(bundle, tmp_path / "twin")
    for o in twin["objects"]:
        assert o["photos"] == [] and o["measurement"]["confirm_with_tape"] is True

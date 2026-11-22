import copy
import json
from pathlib import Path

import pytest
from conftest import to_room

from roomscan.capture import read_capture


def approx_pt(p, q, tol=0.005):
    return abs(p[0] - q[0]) < tol and abs(p[1] - q[1]) < tol


def test_walls_land_on_the_room_corners(sample):
    cap = read_capture(sample)
    corners = [(0, 0), (5, 0), (5, 4), (0, 4)]
    assert len(cap.walls) == 4
    for w in cap.walls:
        ends = [to_room(*w.start), to_room(*w.end)]
        assert all(any(approx_pt(e, c) for c in corners) for e in ends), ends
        assert w.base_z == pytest.approx(0, abs=1e-6)
        assert w.height == pytest.approx(2.6)


def test_floor_is_shifted_to_zero_and_space_found(sample):
    cap = read_capture(sample)
    assert cap.floor_z[0] == pytest.approx(-1.45)
    (sp,) = cap.spaces
    assert sp.closed
    assert sp.area == pytest.approx(20.0, abs=0.01)
    assert sp.perimeter == pytest.approx(18.0, abs=0.01)
    assert sp.label == "livingRoom"


def test_openings_find_their_walls_with_and_without_parent_links(sample):
    cap = read_capture(sample)
    byid = {o.id: o for o in cap.openings}
    walls = {w.id: w for w in cap.walls}
    door = byid["door-1"]  # the sample's door has no parentIdentifier: found by distance
    assert door.wall_id == "wall-1"
    assert door.offset == pytest.approx(1.0, abs=0.005)
    assert door.sill == pytest.approx(0, abs=1e-6)
    assert door.is_open is False
    w1 = byid["window-1"]
    assert w1.wall_id == "wall-2" and w1.offset == pytest.approx(2.0, abs=0.005)
    assert w1.sill == pytest.approx(0.9)
    # wall-3 runs east to west, so offsets count from the east end
    assert walls["wall-3"].start[0] > walls["wall-3"].end[0]
    assert byid["window-2"].offset == pytest.approx(5 - 1.4, abs=0.005)


def test_objects_keep_size_height_and_rotation(sample):
    cap = read_capture(sample)
    objs = {o.id: o for o in cap.objects}
    sofa = objs["sofa-1"]
    assert sofa.size == pytest.approx((2.1, 0.95, 0.85))
    assert to_room(*sofa.center[:2]) == pytest.approx((2.5, 3.45), abs=0.005)
    assert sofa.center[2] == pytest.approx(0.425)
    tv = objs["television-1"]
    assert tv.center[2] - tv.size[2] / 2 == pytest.approx(0.55)
    assert {o.category for o in cap.objects} == {"sofa", "table", "chair", "storage", "television"}


def test_low_confidence_is_warned(sample):
    cap = read_capture(sample)
    assert any("chair-2" in w and "low" in w for w in cap.warnings)


def test_transform_as_nested_columns_and_string_categories(sample):
    alt = copy.deepcopy(sample)
    for key in ("walls", "doors", "windows", "objects"):
        for s in alt[key]:
            t = s["transform"]
            s["transform"] = [t[i * 4 : i * 4 + 4] for i in range(4)]
            s["category"] = next(iter(s["category"]))
            s["confidence"] = next(iter(s["confidence"]))
    a, b = read_capture(sample), read_capture(alt)
    assert [w.start for w in a.walls] == [w.start for w in b.walls]
    assert [o.category for o in a.objects] == [o.category for o in b.objects]


def test_captured_structure_with_rooms(sample):
    structure = {"rooms": [sample], "version": 2}
    cap = read_capture(structure)
    assert len(cap.walls) == 4 and len(cap.objects) == 6


def test_open_wall_loop_falls_back_to_hull(sample):
    s = copy.deepcopy(sample)
    s["walls"].pop(1)
    s["windows"] = [w for w in s["windows"] if w["parentIdentifier"] is None or w["parentIdentifier"] != sample["walls"][1]["identifier"]]
    cap = read_capture(s)
    (sp,) = cap.spaces
    assert not sp.closed
    assert any("don't close" in w for w in cap.warnings)


def test_shipped_sample_matches_generator(sample):
    shipped = json.loads((Path(__file__).parents[1] / "samples/living-room.json").read_text())
    assert shipped == json.loads(json.dumps(sample))

import ifcopenshell
import ifcopenshell.geom
import ifcopenshell.util.element as U
import numpy as np
import pytest
from conftest import to_room

from roomscan.capture import read_capture
from roomscan.ifc import build_ifc, count, validate


def room_bbox(f, el):
    st = ifcopenshell.geom.settings()
    st.set("use-world-coords", True)
    v = np.array(ifcopenshell.geom.create_shape(st, el).geometry.verts).reshape(-1, 3)
    xy = np.array([to_room(x, y) for x, y in v[:, :2]])
    return np.concatenate([xy.min(0), [v[:, 2].min()]]), np.concatenate([xy.max(0), [v[:, 2].max()]])


def by_name(f, cls, name):
    (el,) = [e for e in f.by_type(cls) if e.Name == name]
    return el


@pytest.fixture
def model(sample):
    f, log = build_ifc(read_capture(sample), None, "test")
    return f, log


def test_valid_and_complete(model):
    f, log = model
    assert validate(f) == []
    assert log == []
    assert count(f) == {
        "IfcAudioVisualAppliance": 1, "IfcDoor": 1, "IfcFurniture": 5, "IfcOpeningElement": 4,
        "IfcSlab": 1, "IfcSpace": 1, "IfcWall": 4, "IfcWindow": 3,
    }
    assert f.by_type("IfcSpace")[0].Name == "Living room"


def test_walls_thicken_outward_and_close_corners(model):
    f, _ = model
    lo, hi = room_bbox(f, by_name(f, "IfcWall", "Wall 1"))  # south wall, room is to its north
    assert lo == pytest.approx([-0.15, -0.15, 0], abs=0.002)
    assert hi == pytest.approx([5.15, 0, 2.6], abs=0.002)
    lo, hi = room_bbox(f, by_name(f, "IfcWall", "Wall 4"))  # scanned backwards; still outward
    assert lo == pytest.approx([-0.15, -0.15, 0], abs=0.002)
    assert hi == pytest.approx([0, 4.15, 2.6], abs=0.002)


def test_doors_and_windows_sit_in_their_walls(model):
    f, _ = model
    lo, hi = room_bbox(f, by_name(f, "IfcWindow", "Window 1"))  # east wall, 1.4 wide centred at y=2
    assert lo == pytest.approx([5.0, 1.3, 0.9], abs=0.002)
    assert hi == pytest.approx([5.15, 2.7, 2.2], abs=0.002)
    lo, hi = room_bbox(f, by_name(f, "IfcDoor", "Door 1"))  # south wall, 0.9 wide centred at x=1
    assert lo[0] == pytest.approx(0.55, abs=0.03) and hi[0] == pytest.approx(1.45, abs=0.03)
    assert lo[1] >= -0.2 and hi[1] <= 0.02
    for el in f.by_type("IfcDoor") + f.by_type("IfcWindow"):
        assert el.FillsVoids, f"{el.Name} doesn't fill an opening"
        assert el.FillsVoids[0].RelatingOpeningElement.VoidsElements


def test_furniture_matches_layout(model):
    f, _ = model
    lo, hi = room_bbox(f, by_name(f, "IfcFurniture", "Sofa 1"))
    assert lo == pytest.approx([1.45, 2.975, 0], abs=0.002)
    assert hi == pytest.approx([3.55, 3.925, 0.85], abs=0.002)
    tv = by_name(f, "IfcAudioVisualAppliance", "Television 1")
    assert tv.PredefinedType == "DISPLAY"
    assert room_bbox(f, tv)[0][2] == pytest.approx(0.55, abs=0.002)


def test_scan_provenance_and_quantities(model):
    f, _ = model
    wall = by_name(f, "IfcWall", "Wall 1")
    ps = U.get_psets(wall)
    assert ps["Pset_QlaudeScan"]["ElementId"] == "wall-1"
    assert ps["Pset_QlaudeScan"]["Confidence"] == "high"
    assert ps["Qto_WallBaseQuantities"]["Length"] == pytest.approx(5.0)
    space = f.by_type("IfcSpace")[0]
    assert U.get_psets(space)["Qto_SpaceBaseQuantities"]["NetFloorArea"] == pytest.approx(20.0, abs=0.01)


def test_edits_change_the_model(sample):
    edits = {
        "names": {"project": "Flat 3", "storeys": {"0": "Ground floor"}},
        "defaults": {"wall_thickness": 0.1},
        "elements": {
            "wall-2": {"thickness": 0.3, "side": "center", "properties": {"Pset_WallCommon": {"IsExternal": True}}},
            "storage-1": {"name": "TV unit", "ifc_class": "IfcFurniture", "predefined_type": "USERDEFINED"},
            "chair-2": {"removed": True},
            "space-1": {"name": "Lounge"},
        },
        "added": [{"id": "added-1", "ifc_class": "IfcSpaceHeater", "name": "Radiator", "story": 0,
                   "center": [3.0, 0.5, 0.45], "size": [1.0, 0.1, 0.6], "predefined_type": "RADIATOR"}],
    }
    f, log = build_ifc(read_capture(sample), edits, "t")
    assert validate(f) == [] and log == []
    assert f.by_type("IfcProject")[0].Name == "Flat 3"
    assert f.by_type("IfcBuildingStorey")[0].Name == "Ground floor"
    assert f.by_type("IfcSpace")[0].Name == "Lounge"
    assert "Chair 2" not in {e.Name for e in f.by_type("IfcFurniture")}
    assert "TV unit" in {e.Name for e in f.by_type("IfcFurniture")}
    (rad,) = f.by_type("IfcSpaceHeater")
    assert rad.PredefinedType == "RADIATOR"
    lo, hi = room_bbox(f, by_name(f, "IfcWall", "Wall 2"))  # 0.3 centred on the scanned face x=5
    assert lo[0] == pytest.approx(4.85, abs=0.002) and hi[0] == pytest.approx(5.15, abs=0.002)
    lo, hi = room_bbox(f, by_name(f, "IfcWall", "Wall 1"))
    assert lo[1] == pytest.approx(-0.1, abs=0.002)
    assert U.get_psets(by_name(f, "IfcWall", "Wall 2"))["Pset_WallCommon"]["IsExternal"] is True


def test_bad_class_from_an_edit_degrades_to_proxy(sample):
    f, log = build_ifc(read_capture(sample), {"elements": {"sofa-1": {"ifc_class": "IfcSofaThing"}}}, "t")
    assert validate(f) == []
    assert "Sofa 1" in {e.Name for e in f.by_type("IfcBuildingElementProxy")}
    assert any("IfcSofaThing" in m for m in log)

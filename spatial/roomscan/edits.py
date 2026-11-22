"""The edits an LLM (or a person) makes on top of a scan, kept apart from the scan itself.

The capture is never changed: rescanning or re-importing keeps the edits, and building the IFC
model is always capture + edits. Stored as plain JSON next to the capture:

{
  "names":    {"project": "...", "site": "...", "building": "...", "storeys": {"0": "Ground floor"}},
  "defaults": {"wall_thickness": 0.15, "wall_side": "outside"},
  "elements": {"wall-2": {"thickness": 0.3, "side": "center", "name": "...", "ifc_class": "...",
                          "predefined_type": "...", "removed": false,
                          "properties": {"Pset_WallCommon": {"IsExternal": true}}},
               "space-1": {"name": "Living room", "long_name": "..."}},
  "added":    [{"id": "added-1", "ifc_class": "IfcSpaceHeater", "name": "Radiator", "story": 0,
                "center": [x, y, z], "size": [dx, dy, dz], "yaw_deg": 0, "properties": {...}}],
  "notes":    ["..."]
}
"""

from __future__ import annotations

import copy
from typing import Any

WALL_SIDES = ("outside", "inside", "center")
DEFAULTS = {"wall_thickness": 0.15, "wall_side": "outside"}

# RoomPlan object category -> (IFC class, predefined type). Anything missing becomes a proxy.
CATEGORY_CLASS: dict[str, tuple[str, str | None]] = {
    "storage": ("IfcFurniture", "USERDEFINED"),
    "refrigerator": ("IfcElectricAppliance", "REFRIGERATOR"),
    "stove": ("IfcElectricAppliance", "ELECTRICCOOKER"),
    "oven": ("IfcElectricAppliance", "ELECTRICCOOKER"),
    "dishwasher": ("IfcElectricAppliance", "DISHWASHER"),
    "washerDryer": ("IfcElectricAppliance", "WASHINGMACHINE"),
    "bed": ("IfcFurniture", "BED"),
    "sofa": ("IfcFurniture", "SOFA"),
    "chair": ("IfcFurniture", "CHAIR"),
    "table": ("IfcFurniture", "TABLE"),
    "sink": ("IfcSanitaryTerminal", "SINK"),
    "toilet": ("IfcSanitaryTerminal", "TOILETPAN"),
    "bathtub": ("IfcSanitaryTerminal", "BATH"),
    "television": ("IfcAudioVisualAppliance", "DISPLAY"),
    "fireplace": ("IfcBuildingElementProxy", "USERDEFINED"),
    "stairs": ("IfcStair", "NOTDEFINED"),
}

# RoomPlan section labels -> readable space names.
SECTION_NAMES = {
    "livingRoom": "Living room",
    "bedroom": "Bedroom",
    "bathroom": "Bathroom",
    "kitchen": "Kitchen",
    "diningRoom": "Dining room",
    "unidentified": None,
}


def empty() -> dict[str, Any]:
    return {"names": {}, "defaults": dict(DEFAULTS), "elements": {}, "added": [], "notes": []}


def normalise(e: dict[str, Any] | None) -> dict[str, Any]:
    out = empty()
    for k, v in copy.deepcopy(e or {}).items():
        if k == "defaults":
            out["defaults"].update(v)
        else:
            out[k] = v
    return out


def element(e: dict, element_id: str) -> dict[str, Any]:
    return e["elements"].get(element_id, {})


def wall_thickness(e: dict, wall_id: str) -> float:
    return float(element(e, wall_id).get("thickness", e["defaults"]["wall_thickness"]))


def wall_side(e: dict, wall_id: str) -> str:
    return element(e, wall_id).get("side", e["defaults"]["wall_side"])


def object_class(e: dict, element_id: str, category: str) -> tuple[str, str | None]:
    cls, pre = CATEGORY_CLASS.get(category, ("IfcBuildingElementProxy", "USERDEFINED"))
    el = element(e, element_id)
    if "ifc_class" in el:
        return el["ifc_class"], el.get("predefined_type")
    return cls, el.get("predefined_type", pre)


def is_removed(e: dict, element_id: str) -> bool:
    return bool(element(e, element_id).get("removed"))

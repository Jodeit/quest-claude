"""Make a RoomPlan-shaped CapturedRoom JSON for a room we know the true layout of.

A 5.0 m x 4.0 m living room, 2.6 m high, turned 20 degrees in ARKit's frame, with the phone having
started 1.45 m above the floor. One door, three windows, a wall-wide opening on none (kept simple),
and a sofa, table, two chairs, a TV on a storage unit. One wall runs clockwise and one door has no
parentIdentifier, the way older RoomPlan versions export them, to exercise both code paths.
"""

from __future__ import annotations

import json
import math
import uuid

ROOM_W, ROOM_D, ROOM_H = 5.0, 4.0, 2.6
YAW = math.radians(20)
ORIGIN = (0.8, -1.2)  # where the room's (0, 0) corner is in IFC plan coords
FLOOR_Y = -1.45  # ARKit y of the floor


def _uuid(seed: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "qlaude-sample/" + seed)).upper()


def room_to_ifc(x: float, y: float) -> tuple[float, float]:
    c, s = math.cos(YAW), math.sin(YAW)
    return (ORIGIN[0] + c * x - s * y, ORIGIN[1] + s * x + c * y)


def _arkit_transform(cx: float, cy: float, z: float, yaw: float) -> list[float]:
    """simd_float4x4, column-major, for a pose given in IFC plan coords and height above the floor."""
    c, s = math.cos(yaw), math.sin(yaw)
    col_x = [c, 0.0, -s, 0.0]  # IFC (c, s, 0) -> ARKit (x, up, z) = (c, 0, -s)
    col_y = [0.0, 1.0, 0.0, 0.0]
    col_z = [s, 0.0, c, 0.0]
    pos = [cx, FLOOR_Y + z, -cy, 1.0]
    return [round(v, 6) for v in col_x + col_y + col_z + pos]


def _surface(seed, cat, center_room, z, yaw_room, dims, parent=None, confidence="high"):
    cx, cy = room_to_ifc(*center_room)
    return {
        "identifier": _uuid(seed),
        "category": cat,
        "confidence": {confidence: {}},
        "dimensions": [round(d, 4) for d in dims],
        "transform": _arkit_transform(cx, cy, z, YAW + yaw_room),
        "parentIdentifier": parent,
        "story": 0,
        "completedEdges": [{"top": {}}, {"bottom": {}}, {"left": {}}, {"right": {}}],
        "polygonCorners": [],
        "curve": None,
    }


def make_sample() -> dict:
    corners = [(0, 0), (ROOM_W, 0), (ROOM_W, ROOM_D), (0, ROOM_D)]
    walls = []
    for i in range(4):
        a, b = corners[i], corners[(i + 1) % 4]
        if i == 3:
            a, b = b, a  # one wall scanned "backwards"
        cx, cy = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        yaw = math.atan2(b[1] - a[1], b[0] - a[0])
        L = math.dist(a, b)
        walls.append(_surface(f"wall{i}", {"wall": {}}, (cx, cy), ROOM_H / 2, yaw, [L, ROOM_H, 0]))
    w = [x["identifier"] for x in walls]

    doors = [
        # Door in the south wall (wall 0), its centre 1.0 m from the west corner. No parent link.
        _surface("door0", {"door": {"isOpen": False}}, (1.0, 0), 2.05 / 2, 0, [0.9, 2.05, 0]),
    ]
    windows = [
        _surface("win0", {"window": {}}, (ROOM_W, 2.0), 0.9 + 0.65, math.pi / 2, [1.4, 1.3, 0], w[1]),
        _surface("win1", {"window": {}}, (1.4, ROOM_D), 0.9 + 0.65, math.pi, [1.2, 1.3, 0], w[2]),
        _surface("win2", {"window": {}}, (3.6, ROOM_D), 0.9 + 0.65, math.pi, [1.2, 1.3, 0], w[2], "medium"),
    ]

    def obj(seed, cat, center, size, yaw=0.0, z=None, conf="high"):
        # size = (plan x, plan y, height); RoomPlan dimensions are ARKit-local (x, up, z).
        dx, dy, h = size
        zc = (z if z is not None else 0.0) + h / 2
        d = _surface(seed, {cat: {}}, center, zc, yaw, [dx, h, dy], confidence=conf)
        for k in ("completedEdges", "polygonCorners", "curve"):
            d.pop(k)
        d["attributes"] = {}
        return d

    objects = [
        obj("sofa", "sofa", (2.5, ROOM_D - 0.55), (2.1, 0.95, 0.85), yaw=math.pi),
        obj("table", "table", (2.5, 2.2), (1.2, 0.7, 0.45)),
        obj("chair0", "chair", (4.3, 1.0), (0.6, 0.6, 0.9), yaw=math.radians(-30)),
        obj("chair1", "chair", (4.3, 2.6), (0.6, 0.6, 0.9), yaw=math.radians(210), conf="low"),
        obj("storage", "storage", (2.5, 0.3), (1.8, 0.45, 0.5)),
        obj("tv", "television", (2.5, 0.3), (1.2, 0.08, 0.7), z=0.55),
    ]
    sc = room_to_ifc(ROOM_W / 2, ROOM_D / 2)
    return {
        "identifier": _uuid("room"),
        "story": 0,
        "version": 2,
        "walls": walls,
        "doors": doors,
        "windows": windows,
        "openings": [],
        "objects": objects,
        "floors": [],
        "sections": [{"label": {"livingRoom": {}}, "center": [sc[0], FLOOR_Y, -sc[1]], "story": 0}],
    }


if __name__ == "__main__":
    print(json.dumps(make_sample(), indent=1))

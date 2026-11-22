"""Read an Apple RoomPlan export (CapturedRoom or CapturedStructure, as JSON) into a plan model.

RoomPlan works in ARKit world space: metres, right-handed, Y up, origin wherever the phone started.
IFC is Z up. Everything here is converted on the way in:

    ifc.x = ar.x      ifc.y = -ar.z      ifc.z = ar.y

and shifted so the lowest wall base of each story sits at z = 0.

Shapes of the JSON this accepts (what `JSONEncoder().encode(capturedRoom)` produces):
  - `category`: {"wall": {}} / {"door": {"isOpen": false}} / {"sofa": {}}, or a plain string
  - `confidence`: {"high": {}} or a string
  - `transform`: simd_float4x4, either 16 floats column-major or 4 columns of 4
  - `dimensions`: [x, y, z] in the element's own frame (walls: [width, height, 0])
A CapturedStructure has `rooms: [...]`; its top-level walls/doors/... are the merged result and win.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

KINDS_OF_OPENING = ("door", "window", "opening")
SURFACE_KEYS = {"walls": "wall", "doors": "door", "windows": "window", "openings": "opening"}


@dataclass
class Wall:
    id: str
    uuid: str
    story: int
    start: tuple[float, float]
    end: tuple[float, float]
    base_z: float
    height: float
    confidence: str
    curved: bool = False

    @property
    def length(self) -> float:
        return math.dist(self.start, self.end)

    @property
    def direction(self) -> tuple[float, float]:
        L = self.length or 1.0
        return ((self.end[0] - self.start[0]) / L, (self.end[1] - self.start[1]) / L)

    @property
    def midpoint(self) -> tuple[float, float]:
        return ((self.start[0] + self.end[0]) / 2, (self.start[1] + self.end[1]) / 2)


@dataclass
class Opening:
    id: str
    uuid: str
    kind: str  # door | window | opening
    story: int
    center: tuple[float, float, float]
    width: float
    height: float
    yaw: float
    confidence: str
    is_open: bool | None = None
    wall_id: str | None = None
    offset: float | None = None  # from the host wall's start to the opening's centre, along the wall

    @property
    def sill(self) -> float:
        return self.center[2] - self.height / 2


@dataclass
class Obj:
    id: str
    uuid: str
    category: str
    story: int
    center: tuple[float, float, float]
    size: tuple[float, float, float]  # x, y (plan) and z (height) in the object's own frame
    yaw: float
    confidence: str
    attributes: dict[str, Any] = field(default_factory=dict)


@dataclass
class Section:
    label: str
    story: int
    center: tuple[float, float]


@dataclass
class Space:
    id: str
    story: int
    polygon: list[tuple[float, float]]
    height: float
    closed: bool  # True when the walls chained into a loop; False means a convex-hull guess
    label: str | None = None

    @property
    def area(self) -> float:
        return abs(_signed_area(self.polygon))

    @property
    def perimeter(self) -> float:
        p = self.polygon
        return sum(math.dist(p[i], p[(i + 1) % len(p)]) for i in range(len(p)))

    @property
    def centroid(self) -> tuple[float, float]:
        return _centroid(self.polygon)


@dataclass
class Capture:
    walls: list[Wall]
    openings: list[Opening]
    objects: list[Obj]
    sections: list[Section]
    spaces: list[Space]
    floor_z: dict[int, float]  # per story, in the ARKit frame before shifting (kept for reference)
    warnings: list[str]
    version: Any = None

    @property
    def stories(self) -> list[int]:
        s = {w.story for w in self.walls} | {o.story for o in self.objects}
        return sorted(s) or [0]


# ---------------------------------------------------------------- parsing helpers


def _tag(v: Any) -> tuple[str, dict]:
    """{"door": {"isOpen": true}} -> ("door", {"isOpen": true}); "door" -> ("door", {})."""
    if isinstance(v, str):
        return v, {}
    if isinstance(v, dict) and len(v) == 1:
        k, inner = next(iter(v.items()))
        return k, inner if isinstance(inner, dict) else {}
    return "unknown", {}


def _matrix(t: Any) -> list[list[float]]:
    """Return the 4 columns of a simd_float4x4, whatever way it was encoded."""
    if t is None:
        return [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    if len(t) == 16:
        return [list(map(float, t[i * 4 : i * 4 + 4])) for i in range(4)]
    if len(t) == 4 and all(len(c) == 4 for c in t):
        return [list(map(float, c)) for c in t]
    raise ValueError(f"transform is neither 16 floats nor 4x4: {t!r}")


def _to_ifc(v: list[float]) -> tuple[float, float, float]:
    return (v[0], -v[2], v[1])


def _pose(t: Any) -> tuple[tuple[float, float, float], float]:
    """Centre (IFC axes) and yaw (radians, about +Z) of an element's local X axis."""
    cols = _matrix(t)
    pos = _to_ifc(cols[3])
    ax = _to_ifc(cols[0])
    return pos, math.atan2(ax[1], ax[0])


def _signed_area(p: list[tuple[float, float]]) -> float:
    return sum(p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1] for i in range(len(p))) / 2


def _centroid(p: list[tuple[float, float]]) -> tuple[float, float]:
    a = _signed_area(p)
    if abs(a) < 1e-9:
        return (sum(x for x, _ in p) / len(p), sum(y for _, y in p) / len(p))
    cx = cy = 0.0
    for i in range(len(p)):
        x0, y0 = p[i]
        x1, y1 = p[(i + 1) % len(p)]
        f = x0 * y1 - x1 * y0
        cx += (x0 + x1) * f
        cy += (y0 + y1) * f
    return (cx / (6 * a), cy / (6 * a))


def _convex_hull(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
    pts = sorted(set(pts))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lo: list = []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    hi: list = []
    for p in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], p) <= 0:
            hi.pop()
        hi.append(p)
    return lo[:-1] + hi[:-1]


def point_in_polygon(pt: tuple[float, float], poly: list[tuple[float, float]]) -> bool:
    x, y = pt
    inside = False
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        if (y0 > y) != (y1 > y) and x < (x1 - x0) * (y - y0) / (y1 - y0) + x0:
            inside = not inside
    return inside


def chain_walls(walls: list[Wall], tol: float = 0.35) -> list[tuple[float, float]] | None:
    """Corner points of the loop the walls form, or None if they don't close into one."""
    if len(walls) < 3:
        return None
    left = list(walls[1:])
    corners = [walls[0].start]
    tip = walls[0].end
    while left:
        best, best_d, flip = None, tol, False
        for w in left:
            for end, f in ((w.start, False), (w.end, True)):
                d = math.dist(tip, end)
                if d < best_d:
                    best, best_d, flip = w, d, f
        if best is None:
            return None
        left.remove(best)
        a, b = (best.end, best.start) if flip else (best.start, best.end)
        corners.append(((tip[0] + a[0]) / 2, (tip[1] + a[1]) / 2))
        tip = b
    if math.dist(tip, corners[0]) > tol:
        return None
    corners[0] = ((tip[0] + corners[0][0]) / 2, (tip[1] + corners[0][1]) / 2)
    return corners


def _seg_distance(p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    """Distance from p to segment ab, and how far along ab (in metres) the closest point is."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy or 1e-12
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2))
    q = (a[0] + t * dx, a[1] + t * dy)
    return math.dist(p, q), t * math.sqrt(L2)


# ---------------------------------------------------------------- the reader


def read_capture(data: dict) -> Capture:
    if "walls" not in data and "rooms" in data:
        merged: dict[str, list] = {k: [] for k in (*SURFACE_KEYS, "objects", "sections", "floors")}
        for room in data["rooms"]:
            for k in merged:
                merged[k].extend(room.get(k) or [])
        data = {**data, **merged}

    warnings: list[str] = []
    counters: dict[str, int] = {}

    def next_id(prefix: str) -> str:
        counters[prefix] = counters.get(prefix, 0) + 1
        return f"{prefix}-{counters[prefix]}"

    # Walls first, in ARKit Y, so each story's floor height is known before anything is shifted.
    raw_walls = []
    for s in data.get("walls") or []:
        (cx, cy, cz), yaw = _pose(s.get("transform"))
        w, h = float(s["dimensions"][0]), float(s["dimensions"][1])
        raw_walls.append((s, (cx, cy, cz), yaw, w, h))

    floor_z: dict[int, float] = {}
    for s, (_, _, cz), _, _, h in raw_walls:
        st = int(s.get("story") or 0)
        floor_z[st] = min(floor_z.get(st, math.inf), cz - h / 2)
    if not floor_z:
        floor_z[0] = 0.0
        warnings.append("No walls in this capture; nothing to build walls or a space from.")

    def fz(story: int) -> float:
        return floor_z.get(story, floor_z.get(0, next(iter(floor_z.values()))))

    walls: list[Wall] = []
    by_uuid: dict[str, Wall] = {}
    for s, (cx, cy, cz), yaw, w, h in raw_walls:
        st = int(s.get("story") or 0)
        ux, uy = math.cos(yaw), math.sin(yaw)
        wall = Wall(
            id=next_id("wall"),
            uuid=str(s.get("identifier", "")),
            story=st,
            start=(cx - ux * w / 2, cy - uy * w / 2),
            end=(cx + ux * w / 2, cy + uy * w / 2),
            base_z=cz - h / 2 - fz(st),
            height=h,
            confidence=_tag(s.get("confidence", "unknown"))[0],
            curved=bool(s.get("curve")),
        )
        if wall.curved:
            warnings.append(f"{wall.id} is curved in the scan; it is modelled as a straight wall.")
        walls.append(wall)
        by_uuid[wall.uuid] = wall

    openings: list[Opening] = []
    for key, kind in SURFACE_KEYS.items():
        if kind == "wall":
            continue
        for s in data.get(key) or []:
            st = int(s.get("story") or 0)
            (cx, cy, cz), yaw = _pose(s.get("transform"))
            cat, attrs = _tag(s.get("category", kind))
            o = Opening(
                id=next_id(kind),
                uuid=str(s.get("identifier", "")),
                kind=kind,
                story=st,
                center=(cx, cy, cz - fz(st)),
                width=float(s["dimensions"][0]),
                height=float(s["dimensions"][1]),
                yaw=yaw,
                confidence=_tag(s.get("confidence", "unknown"))[0],
                is_open=attrs.get("isOpen") if kind == "door" else None,
            )
            host = by_uuid.get(str(s.get("parentIdentifier") or ""))
            if host is None:  # older RoomPlan versions don't link openings to walls: nearest wall wins
                best = None
                for w in walls:
                    if w.story != st:
                        continue
                    d, _ = _seg_distance((cx, cy), w.start, w.end)
                    if d < 0.3 and (best is None or d < best[0]):
                        best = (d, w)
                host = best[1] if best else None
            if host is not None:
                o.wall_id = host.id
                o.offset = _seg_distance((cx, cy), host.start, host.end)[1]
            else:
                warnings.append(f"{o.id} isn't in any wall; it will be left out of the IFC model.")
            openings.append(o)

    objects: list[Obj] = []
    for s in data.get("objects") or []:
        st = int(s.get("story") or 0)
        (cx, cy, cz), yaw = _pose(s.get("transform"))
        cat, _ = _tag(s.get("category", "unknown"))
        d = [float(x) for x in s["dimensions"]]
        objects.append(
            Obj(
                id=next_id(cat),
                uuid=str(s.get("identifier", "")),
                category=cat,
                story=st,
                center=(cx, cy, cz - fz(st)),
                size=(d[0], d[2], d[1]),  # ARKit local (x, y-up, z) -> plan x, plan y, height
                yaw=yaw,
                confidence=_tag(s.get("confidence", "unknown"))[0],
                attributes=s.get("attributes") or {},
            )
        )

    sections: list[Section] = []
    for s in data.get("sections") or []:
        lab, _ = _tag(s.get("label", "unidentified"))
        c = s.get("center") or [0, 0, 0]
        x, y, _ = _to_ifc([float(v) for v in c])
        sections.append(Section(label=lab, story=int(s.get("story") or 0), center=(x, y)))

    spaces: list[Space] = []
    for st in sorted(floor_z):
        sw = [w for w in walls if w.story == st]
        if not sw:
            continue
        poly = chain_walls(sw)
        closed = poly is not None
        if not closed:
            poly = _convex_hull([p for w in sw for p in (w.start, w.end)])
            warnings.append(
                f"Story {st}: the walls don't close into one loop (a gap, or several rooms); "
                "the space outline is a convex hull of the wall ends."
            )
        if _signed_area(poly) < 0:
            poly = poly[::-1]  # counter-clockwise
        space = Space(
            id=next_id("space"),
            story=st,
            polygon=poly,
            height=sum(w.height for w in sw) / len(sw),
            closed=closed,
        )
        inside = [s for s in sections if s.story == st and point_in_polygon(s.center, poly)]
        if inside:
            space.label = inside[0].label
        spaces.append(space)

    for w in walls:
        if w.confidence == "low":
            warnings.append(f"{w.id} has low scan confidence; check it.")
    for o in [*openings, *objects]:
        if o.confidence == "low":
            warnings.append(f"{o.id} has low scan confidence; check it.")

    return Capture(walls, openings, objects, sections, spaces, floor_z, warnings, data.get("version"))

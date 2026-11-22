"""What an LLM sees of a scan: compact JSON, and a floor plan it can look at.

Coordinates are IFC plan metres (x east-ish, y north-ish: whatever the phone faced), z up from the
story's floor, rounded to the centimetre. Edits are already applied: names, classes, removals,
thickness, and added elements all show up here the way they will in the IFC model.
"""

from __future__ import annotations

import io
import math
from typing import Any

from . import edits as E
from .capture import Capture


def _r(v: float) -> float:
    return round(v, 2)


def _pt(p) -> list[float]:
    return [_r(c) for c in p]


def summarise(cap: Capture, edits: dict | None = None) -> dict[str, Any]:
    e = E.normalise(edits)
    removed = lambda i: E.is_removed(e, i)  # noqa: E731

    walls = []
    for w in cap.walls:
        walls.append({
            "id": w.id,
            "name": E.element(e, w.id).get("name"),
            "story": w.story,
            "start": _pt(w.start),
            "end": _pt(w.end),
            "length": _r(w.length),
            "height": _r(w.height),
            "thickness": E.wall_thickness(e, w.id),
            "thickness_side": E.wall_side(e, w.id),
            "confidence": w.confidence,
            **({"curved_in_scan": True} if w.curved else {}),
            **({"removed": True} if removed(w.id) else {}),
            "openings": [o.id for o in cap.openings if o.wall_id == w.id],
        })

    openings = []
    for o in cap.openings:
        openings.append({
            "id": o.id,
            "kind": o.kind,
            "name": E.element(e, o.id).get("name"),
            "story": o.story,
            "wall": o.wall_id,
            "offset_along_wall": _r(o.offset) if o.offset is not None else None,
            "width": _r(o.width),
            "height": _r(o.height),
            "sill": _r(o.sill),
            "confidence": o.confidence,
            **({"open_when_scanned": o.is_open} if o.is_open is not None else {}),
            **({"removed": True} if removed(o.id) else {}),
        })

    objects = []
    for o in cap.objects:
        cls, pre = E.object_class(e, o.id, o.category)
        objects.append({
            "id": o.id,
            "category": o.category,
            "name": E.element(e, o.id).get("name"),
            "ifc_class": cls,
            "predefined_type": pre,
            "story": o.story,
            "center": _pt(o.center),
            "size": _pt(o.size),
            "yaw_deg": round(math.degrees(o.yaw) % 360, 1),
            "confidence": o.confidence,
            **({"removed": True} if removed(o.id) else {}),
        })

    spaces = []
    for sp in cap.spaces:
        el = E.element(e, sp.id)
        spaces.append({
            "id": sp.id,
            "name": el.get("name") or E.SECTION_NAMES.get(sp.label or "") or f"Room {sp.id.split('-')[1]}",
            "roomplan_label": sp.label,
            "story": sp.story,
            "outline": [_pt(p) for p in sp.polygon],
            "outline_closed": sp.closed,
            "floor_area_m2": _r(sp.area),
            "perimeter_m": _r(sp.perimeter),
            "height_m": _r(sp.height),
        })

    names = e["names"]
    return {
        "units": "metres; z is height above the story's floor",
        "names": {
            "project": names.get("project", "Room scan"),
            "building": names.get("building", "Building"),
            "storeys": {str(s): names.get("storeys", {}).get(str(s), f"Story {s}") for s in cap.stories},
        },
        "defaults": e["defaults"],
        "spaces": spaces,
        "walls": walls,
        "openings": openings,
        "objects": objects,
        "added": e["added"],
        "notes": e["notes"],
        "warnings": cap.warnings,
        "counts": {
            "walls": sum(1 for w in walls if not w.get("removed")),
            "doors": sum(1 for o in openings if o["kind"] == "door" and not o.get("removed")),
            "windows": sum(1 for o in openings if o["kind"] == "window" and not o.get("removed")),
            "openings": sum(1 for o in openings if o["kind"] == "opening" and not o.get("removed")),
            "objects": sum(1 for o in objects if not o.get("removed")) + sum(1 for a in e["added"] if not a.get("removed")),
        },
    }


# ---------------------------------------------------------------- floor plan


def _box_corners(cx, cy, dx, dy, yaw):
    c, s = math.cos(yaw), math.sin(yaw)
    return [(cx + c * x - s * y, cy + s * x + c * y) for x, y in ((-dx / 2, -dy / 2), (dx / 2, -dy / 2), (dx / 2, dy / 2), (-dx / 2, dy / 2))]


def _plan_shapes(cap: Capture, edits: dict | None, story: int):
    """Everything to draw, in plan metres: (kind, points, label)."""
    e = E.normalise(edits)
    out = []
    for sp in cap.spaces:
        if sp.story == story and not E.is_removed(e, sp.id):
            out.append(("space", sp.polygon, sp.id))
    for w in cap.walls:
        if w.story != story or E.is_removed(e, w.id):
            continue
        t = E.wall_thickness(e, w.id)
        ux, uy = w.direction
        cx, cy = w.midpoint
        # draw the wall's thickness centred on the scanned face; the plan is for checking, not drafting
        out.append(("wall", _box_corners(cx, cy, w.length, t, math.atan2(uy, ux)), w.id))
    for o in cap.openings:
        if o.story != story or E.is_removed(e, o.id):
            continue
        out.append((o.kind, _box_corners(o.center[0], o.center[1], o.width, 0.25, o.yaw), o.id))
    for o in cap.objects:
        if o.story != story or E.is_removed(e, o.id):
            continue
        out.append(("object", _box_corners(o.center[0], o.center[1], o.size[0], o.size[1], o.yaw), o.id))
    for a in e["added"]:
        if int(a.get("story", 0)) != story or a.get("removed"):
            continue
        cx, cy, _ = a["center"]
        dx, dy, _ = a["size"]
        out.append(("added", _box_corners(cx, cy, dx, dy, math.radians(a.get("yaw_deg", 0))), a["id"]))
    return out


def _label_positions(shapes, tx) -> list[tuple[str, float, float, int]]:
    """(label, x, y, font px) in image coordinates, nudged down so no two labels sit on each other."""
    placed: list[tuple[float, float]] = []
    out = []
    for kind, ps, label in sorted(shapes, key=lambda s: s[0] != "space"):
        if kind not in ("object", "added", "door", "window", "space"):
            continue
        x, y = tx((sum(p[0] for p in ps) / len(ps), sum(p[1] for p in ps) / len(ps)))
        if kind == "space":
            y -= 40  # keep the room name clear of whatever stands in the middle of the room
        while any(abs(x - px) < 60 and abs(y - py) < 13 for px, py in placed):
            y += 13
        placed.append((x, y))
        out.append((label, x, y, 16 if kind == "space" else 11))
    return out


STYLE = {
    "space": ("#f1efe8", None),
    "wall": ("#2b2b2b", None),
    "door": ("#d2691e", None),
    "window": ("#3a86c8", None),
    "opening": ("#ffffff", "#999999"),
    "object": ("#e7e1cf", "#7a6f55"),
    "added": ("#d8f0d0", "#3c8a2e"),
}


def plan_svg(cap: Capture, edits: dict | None = None, story: int = 0, px_per_m: int = 100) -> str:
    shapes = _plan_shapes(cap, edits, story)
    pts = [p for _, ps, _ in shapes for p in ps] or [(0, 0), (1, 1)]
    x0, x1 = min(p[0] for p in pts) - 0.5, max(p[0] for p in pts) + 0.5
    y0, y1 = min(p[1] for p in pts) - 0.5, max(p[1] for p in pts) + 0.5
    W, H = (x1 - x0) * px_per_m, (y1 - y0) * px_per_m

    def tx(p):  # y up in plan -> y down in SVG
        return f"{(p[0] - x0) * px_per_m:.1f},{(y1 - p[1]) * px_per_m:.1f}"

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}">',
           f'<rect width="100%" height="100%" fill="#ffffff"/>']
    for kind, ps, label in shapes:
        fill, stroke = STYLE[kind]
        st = f' stroke="{stroke}" stroke-width="1.5"' if stroke else ""
        out.append(f'<polygon points="{" ".join(tx(p) for p in ps)}" fill="{fill}"{st}><title>{label}</title></polygon>')
    xy = lambda p: tuple(float(v) for v in tx(p).split(","))  # noqa: E731
    for label, x, y, size in _label_positions(shapes, xy):
        out.append(f'<text x="{x:.1f}" y="{y:.1f}" font-family="sans-serif" font-size="{size}" '
                   f'text-anchor="middle" dominant-baseline="middle" fill="#333">{label}</text>')
    # 1 m scale bar
    out.append(f'<line x1="10" y1="{H - 12:.0f}" x2="{10 + px_per_m}" y2="{H - 12:.0f}" stroke="#000" stroke-width="3"/>'
               f'<text x="{14 + px_per_m}" y="{H - 8:.0f}" font-family="sans-serif" font-size="11">1 m</text>')
    out.append("</svg>")
    return "\n".join(out)


def plan_png(cap: Capture, edits: dict | None = None, story: int = 0, px_per_m: int = 100) -> bytes:
    """The same plan as a PNG (needs Pillow). Labels use Pillow's built-in font."""
    from PIL import Image, ImageDraw

    shapes = _plan_shapes(cap, edits, story)
    pts = [p for _, ps, _ in shapes for p in ps] or [(0, 0), (1, 1)]
    x0, x1 = min(p[0] for p in pts) - 0.5, max(p[0] for p in pts) + 0.5
    y0, y1 = min(p[1] for p in pts) - 0.5, max(p[1] for p in pts) + 0.5
    W, H = int((x1 - x0) * px_per_m), int((y1 - y0) * px_per_m)
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    def tx(p):
        return ((p[0] - x0) * px_per_m, (y1 - p[1]) * px_per_m)

    for kind, ps, _ in shapes:
        fill, stroke = STYLE[kind]
        d.polygon([tx(p) for p in ps], fill=fill, outline=stroke)
    for label, x, y, _ in _label_positions(shapes, tx):
        d.text((x, y), label, fill="#333333", anchor="mm")
    d.line([(10, H - 12), (10 + px_per_m, H - 12)], fill="black", width=3)
    d.text((14 + px_per_m, H - 18), "1 m", fill="black")
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()

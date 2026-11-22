"""Build an IFC4 model from a Capture plus its edits.

Walls: the scan sees one face of each wall (the face in the room). The wall's thickness is added on
the side its edits ask for (default: outside the room), and each wall runs on past both corners by
its thickness so outside corners close.
Doors and windows: an IfcOpeningElement cuts the host wall, and the IfcDoor/IfcWindow fills it.
Furniture and fixtures: a box the size of RoomPlan's bounding box, as the class the category maps to.
Spaces: the floor outline, extruded to the average wall height, over a 200 mm floor slab.
Every element from the scan carries Pset_QlaudeScan (its scan id, RoomPlan UUID and confidence).
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import numpy as np

import ifcopenshell
import ifcopenshell.api.aggregate
import ifcopenshell.api.attribute
import ifcopenshell.api.context
import ifcopenshell.api.feature
import ifcopenshell.api.geometry
import ifcopenshell.api.project
import ifcopenshell.api.pset
import ifcopenshell.api.root
import ifcopenshell.api.spatial
import ifcopenshell.api.unit
from ifcopenshell.util.shape_builder import ShapeBuilder

from . import edits as E
from .capture import Capture, Obj, Opening, Wall, point_in_polygon

SLAB_DEPTH = 0.2


def _matrix(x: float, y: float, z: float, yaw: float = 0.0) -> np.ndarray:
    c, s = math.cos(yaw), math.sin(yaw)
    m = np.eye(4)
    m[:3, :3] = [[c, -s, 0], [s, c, 0], [0, 0, 1]]
    m[:3, 3] = [x, y, z]
    return m


def _local(m: np.ndarray, x: float, y: float, z: float) -> np.ndarray:
    return m @ _matrix(x, y, z)


class _Builder:
    def __init__(self, cap: Capture, edits: dict, scan_id: str):
        self.cap, self.e, self.scan_id = cap, E.normalise(edits), scan_id
        self.f = ifcopenshell.api.project.create_file(version="IFC4")
        self.sb = ShapeBuilder(self.f)
        self.log: list[str] = []

    # ------------------------------------------------------------ helpers

    def entity(self, cls: str, name: str | None, predefined: str | None = None):
        try:
            el = ifcopenshell.api.root.create_entity(self.f, ifc_class=cls, name=name)
        except Exception as ex:  # an unknown class from an edit: keep the element as a proxy
            self.log.append(f"{name}: can't make {cls} ({ex}); used IfcBuildingElementProxy")
            el = ifcopenshell.api.root.create_entity(self.f, ifc_class="IfcBuildingElementProxy", name=name)
        if predefined:
            try:
                el.PredefinedType = predefined
            except Exception:
                el.PredefinedType = "USERDEFINED"
                el.ObjectType = predefined.lower()
                self.log.append(f"{name}: {el.is_a()} has no PredefinedType {predefined}; used USERDEFINED")
            if el.PredefinedType == "USERDEFINED" and not getattr(el, "ObjectType", None):
                el.ObjectType = (name or "").lower() or "userdefined"
        return el

    def place(self, el, m: np.ndarray):
        ifcopenshell.api.geometry.edit_object_placement(self.f, product=el, matrix=m)

    def box(self, dx: float, dy: float, dz: float):
        prof = self.sb.rectangle(size=np.array([max(dx, 0.01), max(dy, 0.01)]))
        solid = self.sb.extrude(prof, magnitude=max(dz, 0.01))
        return self.sb.get_representation(self.body, [solid])

    def psets(self, el, element_id: str, uuid: str | None, confidence: str | None):
        p = ifcopenshell.api.pset.add_pset(self.f, product=el, name="Pset_QlaudeScan")
        props = {"ScanId": self.scan_id, "ElementId": element_id}
        if uuid:
            props["RoomPlanIdentifier"] = uuid
        if confidence:
            props["Confidence"] = confidence
        ifcopenshell.api.pset.edit_pset(self.f, pset=p, properties=props)
        for name, values in (E.element(self.e, element_id).get("properties") or {}).items():
            self.custom_pset(el, name, values)

    def custom_pset(self, el, name: str, values: dict[str, Any]):
        if not values:
            return
        p = ifcopenshell.api.pset.add_pset(self.f, product=el, name=name)
        ifcopenshell.api.pset.edit_pset(self.f, pset=p, properties=values)

    def qto(self, el, name: str, values: dict[str, float]):
        q = ifcopenshell.api.pset.add_qto(self.f, product=el, name=name)
        ifcopenshell.api.pset.edit_qto(self.f, qto=q, properties={k: round(v, 4) for k, v in values.items()})

    def name(self, element_id: str, default: str) -> str:
        return E.element(self.e, element_id).get("name") or default

    # ------------------------------------------------------------ structure

    def build(self) -> ifcopenshell.file:
        f, names = self.f, self.e["names"]
        project = ifcopenshell.api.root.create_entity(f, ifc_class="IfcProject", name=names.get("project", "Room scan"))
        # Metres throughout: the scan is in metres, and ShapeBuilder takes raw numbers in project units.
        ifcopenshell.api.unit.assign_unit(f, units=[
            ifcopenshell.api.unit.add_si_unit(f, unit_type=t) for t in ("LENGTHUNIT", "AREAUNIT", "VOLUMEUNIT")
        ] + [ifcopenshell.api.unit.add_si_unit(f, unit_type="PLANEANGLEUNIT")])
        model = ifcopenshell.api.context.add_context(f, context_type="Model")
        self.body = ifcopenshell.api.context.add_context(
            f, context_type="Model", context_identifier="Body", target_view="MODEL_VIEW", parent=model
        )
        site = ifcopenshell.api.root.create_entity(f, ifc_class="IfcSite", name=names.get("site", "Site"))
        building = ifcopenshell.api.root.create_entity(f, ifc_class="IfcBuilding", name=names.get("building", "Building"))
        ifcopenshell.api.aggregate.assign_object(f, products=[site], relating_object=project)
        ifcopenshell.api.aggregate.assign_object(f, products=[building], relating_object=site)
        for el in (site, building):
            self.place(el, np.eye(4))

        storey_names = names.get("storeys", {})
        base0 = self.cap.floor_z.get(0, 0.0)
        self.storeys = {}
        for st in self.cap.stories:
            elev = self.cap.floor_z.get(st, base0) - base0
            s = ifcopenshell.api.root.create_entity(
                f, ifc_class="IfcBuildingStorey", name=storey_names.get(str(st), f"Story {st}")
            )
            s.Elevation = round(elev, 4)
            self.place(s, _matrix(0, 0, elev))
            ifcopenshell.api.aggregate.assign_object(f, products=[s], relating_object=building)
            self.storeys[st] = (s, elev)

        self.walls = {}
        for w in self.cap.walls:
            if not E.is_removed(self.e, w.id):
                self.wall(w)
        for o in self.cap.openings:
            if not E.is_removed(self.e, o.id):
                self.opening(o)
        for o in self.cap.objects:
            if not E.is_removed(self.e, o.id):
                self.obj(o)
        for sp in self.cap.spaces:
            if not E.is_removed(self.e, sp.id):
                self.space(sp)
        for a in self.e["added"]:
            if not a.get("removed"):
                self.added(a)
        return f

    def contain(self, el, story: int):
        s, _ = self.storeys.get(story, next(iter(self.storeys.values())))
        ifcopenshell.api.spatial.assign_container(self.f, products=[el], relating_structure=s)

    def elev(self, story: int) -> float:
        return self.storeys.get(story, (None, 0.0))[1]

    # ------------------------------------------------------------ elements

    def _outside_is_left(self, w: Wall) -> bool:
        """True when the room is on the right of the wall's start->end direction."""
        rooms = [sp for sp in self.cap.spaces if sp.story == w.story]
        if not rooms:
            return True
        cx, cy = rooms[0].centroid
        ux, uy = w.direction
        mx, my = w.midpoint
        left = (-uy, ux)
        return (mx - cx) * left[0] + (my - cy) * left[1] > 0

    def wall(self, w: Wall):
        t = E.wall_thickness(self.e, w.id)
        side = E.wall_side(self.e, w.id)
        left_out = self._outside_is_left(w)
        # In the wall's own frame +Y is to the left. Where the thickness goes:
        if side == "center":
            offset = -t / 2
        elif side == "inside":
            offset = -t if left_out else 0.0
        else:
            offset = 0.0 if left_out else -t
        ext = t if side != "inside" else 0.0
        ux, uy = w.direction
        yaw = math.atan2(uy, ux)
        m = _matrix(w.start[0] - ux * ext, w.start[1] - uy * ext, w.base_z, yaw)
        el = self.entity("IfcWall", self.name(w.id, f"Wall {w.id.split('-')[1]}"), "STANDARD")
        self.place(el, m)
        rep = ifcopenshell.api.geometry.add_wall_representation(
            self.f, context=self.body, length=w.length + 2 * ext, height=w.height, thickness=t, offset=offset
        )
        ifcopenshell.api.geometry.assign_representation(self.f, product=el, representation=rep)
        self.contain(el, w.story)
        self.psets(el, w.id, w.uuid, w.confidence)
        self.qto(el, "Qto_WallBaseQuantities", {"Length": w.length, "Height": w.height, "Width": t})
        self.walls[w.id] = (el, m, offset, t, ext)

    def opening(self, o: Opening):
        if o.wall_id not in self.walls:
            return
        wall, m, offset, t, ext = self.walls[o.wall_id]
        x0 = ext + o.offset - o.width / 2
        margin = 0.05
        om = _local(m, x0, 0, o.sill)
        void = ifcopenshell.api.root.create_entity(self.f, ifc_class="IfcOpeningElement", name=f"{o.id} opening")
        void.PredefinedType = "OPENING"
        self.place(void, om)
        rep = ifcopenshell.api.geometry.add_wall_representation(
            self.f, context=self.body, length=o.width, height=o.height, thickness=t + 2 * margin, offset=offset - margin
        )
        ifcopenshell.api.geometry.assign_representation(self.f, product=void, representation=rep)
        ifcopenshell.api.feature.add_feature(self.f, feature=void, element=wall)
        if o.kind == "opening":
            self.psets(void, o.id, o.uuid, o.confidence)
            return

        num = o.id.split("-")[1]
        if o.kind == "door":
            el = self.entity("IfcDoor", self.name(o.id, f"Door {num}"), "DOOR")
            rep = self._try(
                lambda: ifcopenshell.api.geometry.add_door_representation(
                    self.f, context=self.body, overall_height=o.height, overall_width=o.width,
                    lining_properties={"LiningDepth": t, "LiningThickness": 0.05},
                )
            )
        else:
            el = self.entity("IfcWindow", self.name(o.id, f"Window {num}"), "WINDOW")
            rep = self._try(
                lambda: ifcopenshell.api.geometry.add_window_representation(
                    self.f, context=self.body, overall_height=o.height, overall_width=o.width,
                    # The panel stands 25 mm proud of the lining; this keeps the whole window in the wall.
                    lining_properties={"LiningDepth": max(t - 0.025, 0.03), "LiningThickness": 0.05, "LiningOffset": 0.0},
                )
            )
        el.OverallHeight, el.OverallWidth = round(o.height, 4), round(o.width, 4)
        # Door and window shapes run from y=0 to y=+lining depth in their own frame, like the wall's
        # body does from y=offset, so both share the placement.
        self.place(el, _local(m, x0, offset, o.sill))
        if rep is None:
            rep = self.box(o.width, t, o.height)
        ifcopenshell.api.geometry.assign_representation(self.f, product=el, representation=rep)
        ifcopenshell.api.feature.add_filling(self.f, opening=void, element=el)
        self.contain(el, o.story)
        self.psets(el, o.id, o.uuid, o.confidence)
        if o.kind == "door" and o.is_open is not None:
            self.custom_pset(el, "Pset_QlaudeScan_Door", {"WasOpenWhenScanned": bool(o.is_open)})

    def _try(self, fn):
        try:
            return fn()
        except Exception as ex:
            self.log.append(f"parametric shape failed ({ex}); used a box")
            return None

    def obj(self, o: Obj):
        cls, pre = E.object_class(self.e, o.id, o.category)
        label = o.category[0].upper() + o.category[1:]
        el = self.entity(cls, self.name(o.id, f"{label} {o.id.rsplit('-', 1)[1]}"), pre)
        dx, dy, dz = o.size
        m = _matrix(o.center[0], o.center[1], o.center[2], o.yaw) @ _matrix(-dx / 2, -dy / 2, -dz / 2)
        self.place(el, m)
        ifcopenshell.api.geometry.assign_representation(self.f, product=el, representation=self.box(dx, dy, dz))
        self.contain(el, o.story)
        self.psets(el, o.id, o.uuid, o.confidence)
        self.custom_pset(el, "Pset_QlaudeScan_Object", {"RoomPlanCategory": o.category})

    def space(self, sp):
        el_edit = E.element(self.e, sp.id)
        default = E.SECTION_NAMES.get(sp.label or "", None) or f"Room {sp.id.split('-')[1]}"
        s, elev = self.storeys.get(sp.story, next(iter(self.storeys.values())))
        poly = [(x, y) for x, y in sp.polygon]

        slab = self.entity("IfcSlab", f"Floor of {el_edit.get('name') or default}", "FLOOR")
        self.place(slab, _matrix(0, 0, elev - SLAB_DEPTH))
        rep = ifcopenshell.api.geometry.add_slab_representation(
            self.f, context=self.body, depth=SLAB_DEPTH, polyline=poly + [poly[0]]
        )
        ifcopenshell.api.geometry.assign_representation(self.f, product=slab, representation=rep)
        self.contain(slab, sp.story)
        self.psets(slab, f"{sp.id}-floor", None, None)

        el = ifcopenshell.api.root.create_entity(self.f, ifc_class="IfcSpace", name=el_edit.get("name") or default)
        el.PredefinedType = "INTERNAL"
        if el_edit.get("long_name"):
            el.LongName = el_edit["long_name"]
        self.place(el, _matrix(0, 0, elev))
        rep = ifcopenshell.api.geometry.add_slab_representation(
            self.f, context=self.body, depth=sp.height, polyline=poly + [poly[0]]
        )
        ifcopenshell.api.geometry.assign_representation(self.f, product=el, representation=rep)
        ifcopenshell.api.aggregate.assign_object(self.f, products=[el], relating_object=s)
        self.psets(el, sp.id, None, None)
        self.qto(el, "Qto_SpaceBaseQuantities", {
            "NetFloorArea": sp.area, "GrossPerimeter": sp.perimeter, "Height": sp.height,
            "NetVolume": sp.area * sp.height,
        })

    def added(self, a: dict):
        cx, cy, cz = (float(v) for v in a["center"])
        dx, dy, dz = (float(v) for v in a["size"])
        story = int(a.get("story", 0))
        el = self.entity(a.get("ifc_class", "IfcBuildingElementProxy"), a.get("name", a["id"]), a.get("predefined_type"))
        yaw = math.radians(float(a.get("yaw_deg", 0)))
        self.place(el, _matrix(cx, cy, cz + self.elev(story), yaw) @ _matrix(-dx / 2, -dy / 2, -dz / 2))
        ifcopenshell.api.geometry.assign_representation(self.f, product=el, representation=self.box(dx, dy, dz))
        self.contain(el, story)
        p = ifcopenshell.api.pset.add_pset(self.f, product=el, name="Pset_QlaudeScan")
        ifcopenshell.api.pset.edit_pset(
            self.f, pset=p, properties={"ScanId": self.scan_id, "ElementId": a["id"], "Source": "added by edit"}
        )
        for name, values in (a.get("properties") or {}).items():
            self.custom_pset(el, name, values)


def build_ifc(cap: Capture, edits: dict | None = None, scan_id: str = "scan") -> tuple[ifcopenshell.file, list[str]]:
    b = _Builder(cap, edits or {}, scan_id)
    return b.build(), b.log


def write_ifc(cap: Capture, path: Path, edits: dict | None = None, scan_id: str = "scan") -> dict:
    f, log = build_ifc(cap, edits, scan_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    f.write(str(path))
    return {"path": str(path), "counts": count(f), "log": log}


def count(f: ifcopenshell.file) -> dict[str, int]:
    out: dict[str, int] = {}
    for el in f.by_type("IfcProduct"):
        if el.is_a() in ("IfcSite", "IfcBuilding", "IfcBuildingStorey"):
            continue
        out[el.is_a()] = out.get(el.is_a(), 0) + 1
    return dict(sorted(out.items()))


def validate(f: ifcopenshell.file) -> list[str]:
    import logging

    import ifcopenshell.validate

    class Collect(logging.Handler):
        def __init__(self):
            super().__init__()
            self.msgs: list[str] = []

        def emit(self, record):
            self.msgs.append(self.format(record))

    logger = logging.getLogger("roomscan.validate")
    logger.propagate = False
    h = Collect()
    logger.handlers = [h]
    logger.setLevel(logging.ERROR)
    ifcopenshell.validate.validate(f, logger, express_rules=False)
    return h.msgs


def in_space(cap: Capture, story: int, xy: tuple[float, float]) -> str | None:
    for sp in cap.spaces:
        if sp.story == story and point_in_polygon(xy, sp.polygon):
            return sp.id
    return None

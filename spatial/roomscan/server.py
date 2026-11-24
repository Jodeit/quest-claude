"""The MCP server: room scans in, IFC models out, with an LLM checking and enriching in between.

Transports:
  stdio            for a Claude Code (or any MCP client) on the same machine
  streamable HTTP  for clients on the network; needs a bearer token. Also takes scans pushed by a
                   phone (POST /scans) and serves built models (GET /scans/<id>/model.ifc).
"""

from __future__ import annotations

import json
import secrets
from typing import Any

from mcp.server.mcpserver import Context, Image, MCPServer
from mcp.server.subscriptions import ResourcesListChanged, ResourceUpdated
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response

from . import edits as E
from .ifc import build_ifc as _build_model, count, validate
from .store import ScanNotFound, Store
from .summary import plan_png, plan_svg, summarise

INSTRUCTIONS = """\
Room scans (Apple RoomPlan exports) become IFC4 building models here.

Typical flow:
1. list_scans (or import_scan a RoomPlan JSON file) and get_scan to read one: spaces, walls,
   doors, windows and furniture with sizes and positions in metres, plus warnings.
   A scan whose stage is "live" is still being captured by a phone and updates every few
   seconds: read it to coach the person scanning ("the north wall is missing"), but edit only
   once it is "final".
2. get_plan to look at the floor plan and check the scan makes sense.
3. Fix and enrich with edit_element (rename, reclassify, wall thickness, remove a false detection),
   set_properties, add_element (things the scan missed: radiators, columns, built-ins),
   set_names and set_defaults. Ask the user when unsure rather than guessing.
4. build_ifc writes the model and reports what's in it and whether it validates.

The scan sees only the room side of each wall: wall thickness is a default (0.15 m) unless set.
Element ids (wall-1, door-1, sofa-1, space-1, added-1) are stable across edits and rebuilds.
"""


def _summary_uri(scan_id: str) -> str:
    return f"scan://{scan_id}/summary"


def make_server(store: Store, public_url: str | None = None) -> MCPServer:
    mcp = MCPServer("roomscan", instructions=INSTRUCTIONS, version="0.1.0")

    def element_ids(scan_id: str) -> set[str]:
        cap = store.capture(scan_id)
        ids = {x.id for x in (*cap.walls, *cap.openings, *cap.objects, *cap.spaces)}
        return ids | {a["id"] for a in store.edits(scan_id)["added"]}

    async def changed(ctx: Context | None, scan_id: str):
        if ctx is None:
            return
        try:
            await ctx.notify_resource_updated(_summary_uri(scan_id))
        except Exception:
            pass  # no listeners, or a client on an older protocol: nothing to tell

    def check(scan_id: str, element_id: str | None = None):
        store.dir(scan_id)
        if element_id is not None and element_id not in element_ids(scan_id):
            raise ValueError(f"{scan_id} has no element {element_id!r}; get_scan lists them")

    # ------------------------------------------------------------ reading

    @mcp.tool()
    def list_scans() -> list[dict[str, Any]]:
        """The room scans stored here, newest first."""
        return store.list()

    @mcp.tool()
    async def import_scan(path: str, name: str | None = None, ctx: Context | None = None) -> dict[str, Any]:
        """Store a RoomPlan export (CapturedRoom or CapturedStructure JSON) from a file on this machine."""
        scan_id = store.import_file(path, name)
        if ctx is not None:
            try:
                await ctx.notify_resources_changed()
            except Exception:
                pass
        return {"scan_id": scan_id, "counts": summarise(store.capture(scan_id))["counts"]}

    @mcp.tool()
    def make_twin(bundle_path: str, out_dir: str | None = None) -> dict[str, Any]:
        """Turn a RoomScan scan bundle (the app's More -> Share scan bundle: a .zip or its unzipped
        folder, on this machine) into a shared 3D twin: a web page with the room as a photo-real
        mesh and a dollhouse, its spots with shelf estimates, products, team notes and measurements.
        Returns the folder and the publish recipe for the Artifact tool. Takes ~10-30 s with a mesh."""
        from pathlib import Path as _P

        from .twin import build_twin, publish_files

        src = _P(bundle_path).expanduser()
        out = _P(out_dir).expanduser() if out_dir else store.home / "twins" / src.stem
        twin = build_twin(src, out)
        return {
            "page": str(out / "index.html"), "root": str(out), "files": publish_files(out),
            "capabilities": {"db": {}, "user": {"scopes": ["profile"]}},
            "name": twin["name"], "spots": [o["key"] for o in twin["objects"]], "processing": twin["processing"],
            "how": "Publish with the Artifact tool: file_path=page, root=root, files=files, capabilities as given. "
                   "The page keeps team edits (names, tape measurements, products, notes, 3D measurements) in its db.",
        }

    @mcp.tool()
    def get_scan(scan_id: str) -> dict[str, Any]:
        """A scan as plan data, with edits applied: spaces (outline, area), walls (ends, length, height,
        thickness, openings), doors/windows (host wall, offset, size, sill), objects (category, IFC class,
        centre, size, rotation), anything added, notes and warnings. Metres; z is above the floor."""
        check(scan_id)
        out = summarise(store.capture(scan_id), store.edits(scan_id))
        meta = next((m for m in store.list() if m["id"] == scan_id), {})
        out["stage"] = meta.get("stage", "final")
        if out["stage"] == "live":
            out["warnings"] = ["The phone is still scanning: this is a live snapshot, and element ids "
                               "can change until the final upload. Hold edits until then."] + out["warnings"]
        return out

    @mcp.tool()
    def get_plan(scan_id: str, story: int = 0) -> Image | str:
        """A floor plan picture of the scan with edits applied, labelled with element ids.
        Walls are black, doors orange, windows blue, furniture beige, added elements green."""
        check(scan_id)
        cap, e = store.capture(scan_id), store.edits(scan_id)
        try:
            return Image(data=plan_png(cap, e, story), format="png")
        except ImportError:
            return plan_svg(cap, e, story)

    # ------------------------------------------------------------ editing

    @mcp.tool()
    async def edit_element(
        scan_id: str,
        element_id: str,
        name: str | None = None,
        ifc_class: str | None = None,
        predefined_type: str | None = None,
        removed: bool | None = None,
        thickness: float | None = None,
        thickness_side: str | None = None,
        long_name: str | None = None,
        ctx: Context | None = None,
    ) -> dict[str, Any]:
        """Change one element. Only the fields given change.
        name: any element or space. ifc_class / predefined_type: reclassify an object (e.g. a "storage"
        that is really a wardrobe: IfcFurniture / USERDEFINED, name "Wardrobe"). removed: true drops a
        false detection from the model (false brings it back). thickness (metres) and thickness_side
        ("outside" the room, "inside", or "center" on the scanned face): walls only. long_name: spaces."""
        check(scan_id, element_id)
        if thickness_side is not None and thickness_side not in E.WALL_SIDES:
            raise ValueError(f"thickness_side must be one of {E.WALL_SIDES}")
        if thickness is not None and not (0.01 <= thickness <= 2.0):
            raise ValueError("thickness is in metres, between 0.01 and 2")
        e = store.edits(scan_id)
        changes = {k: v for k, v in {
            "name": name, "ifc_class": ifc_class, "predefined_type": predefined_type, "removed": removed,
            "thickness": thickness, "side": thickness_side, "long_name": long_name,
        }.items() if v is not None}
        if element_id.startswith("added-"):
            for a in e["added"]:
                if a["id"] == element_id:
                    a.update({k: v for k, v in changes.items() if k in ("name", "ifc_class", "predefined_type", "removed")})
        else:
            e["elements"].setdefault(element_id, {}).update(changes)
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return {"element_id": element_id, "now": e["elements"].get(element_id) or next(
            (a for a in e["added"] if a["id"] == element_id), {})}

    @mcp.tool()
    async def set_properties(
        scan_id: str, element_id: str, pset: str, properties: dict[str, Any], ctx: Context | None = None
    ) -> dict[str, Any]:
        """Set IFC properties on an element, e.g. pset "Pset_WallCommon", {"IsExternal": true,
        "FireRating": "EI60"}, or your own pset name. A value of null removes that property."""
        check(scan_id, element_id)
        e = store.edits(scan_id)
        if element_id.startswith("added-"):
            target = next(a for a in e["added"] if a["id"] == element_id).setdefault("properties", {})
        else:
            target = e["elements"].setdefault(element_id, {}).setdefault("properties", {})
        ps = target.setdefault(pset, {})
        for k, v in properties.items():
            if v is None:
                ps.pop(k, None)
            else:
                ps[k] = v
        if not ps:
            target.pop(pset)
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return {"element_id": element_id, "properties": target}

    @mcp.tool()
    async def add_element(
        scan_id: str,
        ifc_class: str,
        name: str,
        center: list[float],
        size: list[float],
        yaw_deg: float = 0.0,
        story: int = 0,
        predefined_type: str | None = None,
        properties: dict[str, dict[str, Any]] | None = None,
        ctx: Context | None = None,
    ) -> dict[str, Any]:
        """Add something the scan missed, as a box: center [x, y, z] (z is the box's middle above the
        floor) and size [x, y, height] in metres, in the same frame as get_scan. ifc_class e.g.
        IfcSpaceHeater, IfcColumn, IfcFurniture, IfcBuildingElementProxy. Returns the new id."""
        check(scan_id)
        if len(center) != 3 or len(size) != 3 or min(size) <= 0:
            raise ValueError("center is [x, y, z] and size is [x, y, height], all in metres, size > 0")
        e = store.edits(scan_id)
        n = 1 + max([int(a["id"].split("-")[1]) for a in e["added"]] or [0])
        a = {"id": f"added-{n}", "ifc_class": ifc_class, "name": name, "story": story,
             "center": [float(v) for v in center], "size": [float(v) for v in size], "yaw_deg": yaw_deg}
        if predefined_type:
            a["predefined_type"] = predefined_type
        if properties:
            a["properties"] = properties
        e["added"].append(a)
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return a

    @mcp.tool()
    async def set_names(
        scan_id: str,
        project: str | None = None,
        site: str | None = None,
        building: str | None = None,
        storeys: dict[str, str] | None = None,
        ctx: Context | None = None,
    ) -> dict[str, Any]:
        """Name the project, site, building, and storeys ({"0": "Ground floor"})."""
        check(scan_id)
        e = store.edits(scan_id)
        for k, v in (("project", project), ("site", site), ("building", building)):
            if v is not None:
                e["names"][k] = v
        if storeys:
            e["names"].setdefault("storeys", {}).update({str(k): v for k, v in storeys.items()})
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return e["names"]

    @mcp.tool()
    async def set_defaults(
        scan_id: str, wall_thickness: float | None = None, wall_side: str | None = None, ctx: Context | None = None
    ) -> dict[str, Any]:
        """Defaults for walls without their own: wall_thickness in metres, wall_side "outside",
        "inside" or "center" (which side of the scanned face the thickness goes)."""
        check(scan_id)
        if wall_side is not None and wall_side not in E.WALL_SIDES:
            raise ValueError(f"wall_side must be one of {E.WALL_SIDES}")
        e = store.edits(scan_id)
        if wall_thickness is not None:
            e["defaults"]["wall_thickness"] = wall_thickness
        if wall_side is not None:
            e["defaults"]["wall_side"] = wall_side
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return e["defaults"]

    @mcp.tool()
    async def add_note(scan_id: str, note: str, ctx: Context | None = None) -> list[str]:
        """Keep a note with the scan (an assumption made, something to re-check on site)."""
        check(scan_id)
        e = store.edits(scan_id)
        e["notes"].append(note)
        store.save_edits(scan_id, e)
        await changed(ctx, scan_id)
        return e["notes"]

    # ------------------------------------------------------------ the model

    @mcp.tool()
    def build_ifc(scan_id: str) -> dict[str, Any]:
        """Write the IFC4 model for a scan with all edits applied. Returns where it is, how many of each
        IFC class it has, schema validation problems (empty means valid) and anything the builder had
        to work around."""
        check(scan_id)
        f, log = _build(scan_id)
        path = store.model_path(scan_id)
        f.write(str(path))
        out = {"path": str(path), "counts": count(f), "validation_errors": validate(f), "log": log}
        if public_url:
            out["download"] = f"{public_url.rstrip('/')}/scans/{scan_id}/model.ifc"
        return out

    def _build(scan_id: str):
        return _build_model(store.capture(scan_id), store.edits(scan_id), scan_id)

    # ------------------------------------------------------------ resources

    @mcp.resource("scans://index", mime_type="application/json", description="The scans stored here")
    def scans_index() -> str:
        return json.dumps(store.list())

    @mcp.resource("scan://{scan_id}/summary", mime_type="application/json",
                  description="A scan as plan data with edits applied (same as get_scan)")
    def scan_summary(scan_id: str) -> str:
        return json.dumps(summarise(store.capture(scan_id), store.edits(scan_id)))

    @mcp.resource("scan://{scan_id}/plan.svg", mime_type="image/svg+xml", description="Floor plan, story 0")
    def scan_plan(scan_id: str) -> str:
        return plan_svg(store.capture(scan_id), store.edits(scan_id))

    # ------------------------------------------------------------ HTTP extras (token checked by the app wrapper)

    @mcp.custom_route("/health", methods=["GET"])
    async def health(_: Request) -> Response:
        return JSONResponse({"ok": True, "scans": len(store.list())})

    def stage_of(request: Request) -> str:
        return "live" if request.query_params.get("stage") == "live" else "final"

    @mcp.custom_route("/scans", methods=["GET"])
    async def list_route(_: Request) -> Response:
        return JSONResponse({"scans": store.list()})

    @mcp.custom_route("/scans", methods=["POST"])
    async def upload(request: Request) -> Response:
        try:
            data = await request.json()
            scan_id = store.add(data, request.query_params.get("name"), source="http", stage=stage_of(request))
        except Exception as ex:
            return JSONResponse({"error": f"not a RoomPlan export: {ex}"}, status_code=400)
        try:
            await mcp._subscriptions.publish(ResourcesListChanged())  # tell listening clients
        except Exception:
            pass
        return JSONResponse({"scan_id": scan_id}, status_code=201)

    @mcp.custom_route("/scans/{scan_id}", methods=["PUT"])
    async def update(request: Request) -> Response:
        """A newer capture of a scan already here: the phone sends one every couple of seconds while
        scanning (?stage=live) and the processed result at the end (stage final)."""
        scan_id = request.path_params["scan_id"]
        try:
            store.dir(scan_id)
        except ScanNotFound:
            return JSONResponse({"error": "no such scan"}, status_code=404)
        try:
            meta = store.replace(scan_id, await request.json(), stage_of(request))
        except Exception as ex:
            return JSONResponse({"error": f"not a RoomPlan export: {ex}"}, status_code=400)
        try:
            await mcp._subscriptions.publish(ResourceUpdated(uri=_summary_uri(scan_id)))
        except Exception:
            pass
        return JSONResponse({"scan_id": scan_id, "stage": meta["stage"], "updates": meta["updates"]})

    @mcp.custom_route("/scans/{scan_id}/model.ifc", methods=["GET"])
    async def download(request: Request) -> Response:
        try:
            p = store.model_path(request.path_params["scan_id"])
        except ScanNotFound:
            return JSONResponse({"error": "no such scan"}, status_code=404)
        if not p.exists():
            return JSONResponse({"error": "no model yet; call build_ifc"}, status_code=404)
        return FileResponse(p, media_type="application/x-step", filename=f"{p.parent.name}.ifc")

    return mcp


class BearerAuth:
    """ASGI wrapper: every request except GET /health needs `Authorization: Bearer <token>`."""

    def __init__(self, app, token: str):
        self.app, self.token = app, token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope.get("path") != "/health":
            auth = dict(scope.get("headers") or []).get(b"authorization", b"")
            if not (auth.startswith(b"Bearer ") and secrets.compare_digest(auth[7:], self.token)):
                await JSONResponse({"error": "missing or wrong bearer token"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


def load_or_make_token(store: Store) -> str:
    p = store.home / "token"
    if p.exists():
        return p.read_text().strip()
    t = secrets.token_urlsafe(24)
    p.write_text(t + "\n")
    p.chmod(0o600)
    return t


def http_app(store: Store, token: str, public_url: str | None = None):
    mcp = make_server(store, public_url)
    return BearerAuth(mcp.streamable_http_app(host="0.0.0.0"), token)


def serve_http(store: Store, host: str, port: int, token: str, public_url: str | None = None):
    import uvicorn

    uvicorn.run(http_app(store, token, public_url), host=host, port=port, log_level="info")


def serve_stdio(store: Store):
    make_server(store).run("stdio")


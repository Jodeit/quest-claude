import asyncio
import json

import httpx2 as httpx  # the HTTP client mcp 2.x ships with
import pytest

from mcp import Client
from roomscan.server import http_app, make_server
from roomscan.store import Store


def run(coro):
    return asyncio.run(coro)


def data(result):
    """A tool result's value: structured content when there is some, else the parsed text."""
    assert not result.is_error, result.content
    sc = result.structured_content
    if sc is not None:
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc
    return json.loads(result.content[0].text)


def test_full_flow_over_mcp(tmp_path, sample_path):
    store = Store(tmp_path / "home")
    server = make_server(store)

    async def flow():
        async with Client(server) as c:
            names = {t.name for t in (await c.list_tools()).tools}
            assert {"list_scans", "import_scan", "get_scan", "get_plan", "edit_element", "set_properties",
                    "add_element", "set_names", "set_defaults", "add_note", "build_ifc"} <= names

            imp = data(await c.call_tool("import_scan", {"path": str(sample_path), "name": "Living room"}))
            sid = imp["scan_id"]
            assert imp["counts"] == {"walls": 4, "doors": 1, "windows": 3, "openings": 0, "objects": 6}
            assert data(await c.call_tool("list_scans", {}))[0]["id"] == sid

            scan = data(await c.call_tool("get_scan", {"scan_id": sid}))
            assert scan["spaces"][0]["floor_area_m2"] == 20.0

            plan = await c.call_tool("get_plan", {"scan_id": sid})
            assert plan.content[0].type == "image" and plan.content[0].mime_type == "image/png"

            await c.call_tool("edit_element", {"scan_id": sid, "element_id": "storage-1", "name": "TV unit"})
            await c.call_tool("edit_element", {"scan_id": sid, "element_id": "wall-1", "thickness": 0.25})
            await c.call_tool("edit_element", {"scan_id": sid, "element_id": "chair-2", "removed": True})
            await c.call_tool("set_properties", {"scan_id": sid, "element_id": "wall-1", "pset": "Pset_WallCommon",
                                                 "properties": {"IsExternal": True}})
            added = data(await c.call_tool("add_element", {
                "scan_id": sid, "ifc_class": "IfcSpaceHeater", "name": "Radiator", "center": [2, 0.2, 0.4],
                "size": [1, 0.1, 0.6], "predefined_type": "RADIATOR"}))
            assert added["id"] == "added-1"
            await c.call_tool("set_names", {"scan_id": sid, "project": "Flat 3", "storeys": {"0": "Ground"}})
            await c.call_tool("add_note", {"scan_id": sid, "note": "wall-1 is the party wall"})

            scan = data(await c.call_tool("get_scan", {"scan_id": sid}))
            assert scan["counts"]["objects"] == 6  # one removed, one added
            assert next(w for w in scan["walls"] if w["id"] == "wall-1")["thickness"] == 0.25

            bad = await c.call_tool("edit_element", {"scan_id": sid, "element_id": "wall-99", "name": "x"})
            assert bad.is_error

            built = data(await c.call_tool("build_ifc", {"scan_id": sid}))
            assert built["validation_errors"] == []
            assert built["counts"]["IfcSpaceHeater"] == 1
            assert built["counts"]["IfcFurniture"] == 4

            res = await c.read_resource(f"scan://{sid}/summary")
            assert json.loads(res.contents[0].text)["names"]["project"] == "Flat 3"
            return sid

    sid = run(flow())
    assert (tmp_path / "home/scans" / sid / "model.ifc").exists()


def test_http_needs_the_token_and_takes_uploads(tmp_path, sample):
    store = Store(tmp_path / "home")
    app = http_app(store, "s3cret")

    async def go():
        t = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=t, base_url="http://quest") as h:
            assert (await h.get("/health")).status_code == 200
            assert (await h.get("/scans")).status_code == 401
            assert (await h.get("/scans", headers={"Authorization": "Bearer s3cret"})).json() == {"scans": []}
            assert (await h.post("/scans", json=sample)).status_code == 401
            assert (await h.post("/scans", json=sample, headers={"Authorization": "Bearer nope"})).status_code == 401
            r = await h.post("/scans?name=Lounge", json=sample, headers={"Authorization": "Bearer s3cret"})
            assert r.status_code == 201
            sid = r.json()["scan_id"]
            assert sid.endswith("-lounge")
            bad = await h.post("/scans", json={"walls": [{"nope": 1}]}, headers={"Authorization": "Bearer s3cret"})
            assert bad.status_code == 400
            r = await h.get(f"/scans/{sid}/model.ifc", headers={"Authorization": "Bearer s3cret"})
            assert r.status_code == 404  # not built yet
            return sid

    sid = run(go())
    assert store.list()[0]["id"] == sid


def test_scan_ids_cant_escape_the_store(tmp_path):
    store = Store(tmp_path / "home")
    for bad in ("../etc", "a/b", "", "UPPER"):
        with pytest.raises(KeyError):
            store.dir(bad)


def test_live_updates_then_final(tmp_path, sample):
    import copy

    store = Store(tmp_path / "home")
    app = http_app(store, "k")
    auth = {"Authorization": "Bearer k"}
    partial = copy.deepcopy(sample)
    partial["walls"] = partial["walls"][:2]
    partial["windows"], partial["doors"], partial["objects"] = partial["windows"][:1], [], []
    empty = {k: [] for k in ("walls", "doors", "windows", "openings", "objects", "sections")}

    async def go():
        t = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=t, base_url="http://quest") as h:
            r = await h.post("/scans?name=Lounge&stage=live", json=empty, headers=auth)  # first frame: nothing yet
            assert r.status_code == 201
            sid = r.json()["scan_id"]
            assert store.list()[0]["stage"] == "live"
            assert len(store.capture(sid).walls) == 0
            r = await h.put(f"/scans/{sid}?stage=live", json=partial, headers=auth)
            assert r.json() == {"scan_id": sid, "stage": "live", "updates": 2}
            assert len(store.capture(sid).walls) == 2
            r = await h.put(f"/scans/{sid}", json=sample, headers=auth)
            assert r.json()["stage"] == "final" and r.json()["updates"] == 3
            assert (await h.put("/scans/nope-1", json=sample, headers=auth)).status_code == 404
            assert (await h.put(f"/scans/{sid}", json=sample)).status_code == 401
            return sid

    sid = run(go())
    assert len(store.capture(sid).walls) == 4 and store.list()[0]["stage"] == "final"

    async def read():
        async with Client(make_server(store)) as c:
            return data(await c.call_tool("get_scan", {"scan_id": sid}))

    assert run(read())["stage"] == "final"

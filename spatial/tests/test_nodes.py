"""360 view nodes: node picking, the cube-face orientation three.js expects, hole filling, and the
twin.json entries. The scene is a synthetic box room whose surface colour encodes the position
(red ~ x, green ~ y, blue ~ z), photographed by synthetic frames, so any face pixel can be checked."""

import json
import math
import struct

import numpy as np
import pytest
from PIL import Image

from roomscan.nodes import SLOTS, build_nodes, face_dirs, fill_texture, select_nodes
from roomscan.twin import Frame, Room, build_twin, publish_files

LO, HI = np.array([-2.0, 0.0, -1.5]), np.array([2.0, 2.5, 1.5])


def tex(X):
    X = np.atleast_2d(X)
    return np.clip(np.column_stack([128 + 50 * X[:, 0], 40 + 70 * X[:, 1], 128 + 70 * X[:, 2]]), 0, 255)


def box_hit(o, D):
    """Distance from o (inside the box) to the box along unit rays D."""
    with np.errstate(divide="ignore"):
        t = np.where(D > 0, (HI - o) / D, (LO - o) / D)
    return np.where(np.abs(D) < 1e-12, np.inf, t).min(1)


def room_dict(partition=False):
    def wall(cx, cz, ang, w):
        c, s = math.cos(ang), math.sin(ang)
        return {"transform": [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, cx, 1.25, cz, 1], "dimensions": [w, 2.5, 0]}
    walls = [wall(0, -1.5, 0, 4), wall(0, 1.5, 0, 4), wall(-2, 0, math.pi / 2, 3), wall(2, 0, math.pi / 2, 3)]
    floor = {"transform": [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1],
             "polygonCorners": [[-2, 1.5, 0], [2, 1.5, 0], [2, -1.5, 0], [-2, -1.5, 0]]}
    return {"walls": walls, "floors": [floor], "objects": [], "doors": [], "windows": [], "openings": []}


def box_mesh(step=0.1, partition=False):
    """The six inner surfaces of the box as a grid of triangles (and optionally a full-height
    partition at x = 0)."""
    P, F = [], []

    def sheet(origin, u, v, nu, nv):
        base = len(P)
        for i in range(nu + 1):
            for j in range(nv + 1):
                P.append(origin + u * i / nu + v * j / nv)
        for i in range(nu):
            for j in range(nv):
                a = base + i * (nv + 1) + j
                F.extend([[a, a + nv + 1, a + 1], [a + 1, a + nv + 1, a + nv + 2]])

    sx, sy, sz = HI - LO
    n = lambda L: max(1, round(L / step))
    ex, ey, ez = np.array([sx, 0, 0]), np.array([0, sy, 0]), np.array([0, 0, sz])
    for o in (LO, LO + ey):
        sheet(o, ex, ez, n(sx), n(sz))
    for o in (LO, LO + ez):
        sheet(o, ex, ey, n(sx), n(sy))
    for o in (LO, LO + ex):
        sheet(o, ez, ey, n(sz), n(sy))
    if partition:
        sheet(np.array([0.0, 0, -1.5]), ez, ey, n(sz), n(sy))
    return np.array(P, float), np.array(F, np.int64)


def look(L, up=(0, 1, 0)):
    L = np.array(L, float) / np.linalg.norm(L)
    up = np.array(up, float)
    if abs(L @ up) > 0.9:
        up = np.array([0, 0, -1.0]) if L[1] > 0 else np.array([0, 0, 1.0])
    back = -L
    right = np.cross(up, back)
    right /= np.linalg.norm(right)
    return np.column_stack([right, np.cross(back, right), back])


def make_frame(folder, name, pos, L, size=160, fov=100, partition=False):
    """A photo of the box room (colour = tex of the hit) from pos looking along L."""
    R = look(L)
    f = size / 2 / math.tan(math.radians(fov / 2))
    j, i = np.mgrid[0:size, 0:size]
    dc = np.stack([(i - size / 2) / f, -(j - size / 2) / f, -np.ones_like(i, float)], -1).reshape(-1, 3)
    D = dc @ R.T
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    t = box_hit(np.array(pos), D)
    if partition:
        with np.errstate(divide="ignore", invalid="ignore"):
            tp = -pos[0] / D[:, 0]
        t = np.where((tp > 0) & (tp < t), tp, t)
    img = tex(pos + D * t[:, None]).reshape(size, size, 3).astype(np.uint8)
    Image.fromarray(img).save(folder / name)
    M = np.eye(4)
    M[:3, :3], M[:3, 3] = R, pos
    k = dict(file=name, transform=M.T.reshape(-1).tolist(), fx=f, fy=f, cx=size / 2, cy=size / 2, width=size, height=size)
    return k


AXES = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]


def frames_at(folder, centre, dirs=AXES, prefix="F", start=0, partition=False):
    rng = np.random.default_rng(start)
    ks = []
    for n, L in enumerate(dirs):
        pos = np.array(centre) + rng.uniform(-0.05, 0.05, 3)
        ks.append(make_frame(folder, f"{prefix}{start + n:03d}.png", pos, L, partition=partition))
    return ks


def three_sample(faces, d, mirror=True):
    """three.js's cube background lookup: direction (-x, y, z) (no mirror: (x, y, z)), the GL face
    and (s, t) from the OpenGL spec, row 0 = the image's first row (flipY false)."""
    rx, ry, rz = (-d[0] if mirror else d[0]), d[1], d[2]
    ax, ay, az = abs(rx), abs(ry), abs(rz)
    if ax >= ay and ax >= az:
        slot, sc, tc, ma = ("px", -rz, -ry, ax) if rx > 0 else ("nx", rz, -ry, ax)
    elif ay >= az:
        slot, sc, tc, ma = ("py", rx, rz, ay) if ry > 0 else ("ny", rx, -rz, ay)
    else:
        slot, sc, tc, ma = ("pz", rx, -ry, az) if rz > 0 else ("nz", -rx, -ry, az)
    img = faces[slot]
    N = img.shape[0]
    i = min(N - 1, int((sc / ma + 1) / 2 * N))
    j = min(N - 1, int((tc / ma + 1) / 2 * N))
    return img[j, i].astype(float)


def _build(tmp_path, ks, partition=False, **kw):
    folder = tmp_path / "frames"
    room = Room(room_dict())
    frames = [Frame(k, folder) for k in ks]
    P, F = box_mesh(partition=partition)
    out = tmp_path / "out"
    nodes, summary = build_nodes(out, P, F, frames, room, **kw)
    return out, nodes, summary


def test_face_directions_are_the_three_slots():
    # Centre pixel of each slot: three mirrors x, so px looks toward world -x.
    want = {"px": (-1, 0, 0), "nx": (1, 0, 0), "py": (0, 1, 0), "ny": (0, -1, 0), "pz": (0, 0, 1), "nz": (0, 0, -1)}
    for s in SLOTS:
        d = face_dirs(s, 2).mean(0)
        assert np.allclose(d / np.linalg.norm(d), want[s], atol=1e-6)
    # Non-mirrored: looking along +z (pz) with y up, the right-hand side of the image is world -x.
    d = face_dirs("pz", 4).reshape(4, 4, 3)
    assert d[1, 3, 0] < 0 < d[1, 0, 0] and d[0, 1, 1] > 0 > d[3, 1, 1]


def test_cube_faces_match_the_room_through_threes_lookup(tmp_path):
    (tmp_path / "frames").mkdir()
    centre = (0.3, 1.4, -0.2)
    ks = frames_at(tmp_path / "frames", centre)
    out, nodes, summary = _build(tmp_path, ks, face_px=64, depth_px=32)
    assert len(nodes) == 1 and summary["count"] == 1
    n = nodes[0]
    assert set(n["faces"]) == set(SLOTS) and n["coverage"] > 0.95 and n["frames_used"] >= 5
    assert "px shows world -x" in summary["convention"]
    faces = {s: np.asarray(Image.open(out / n["faces"][s])) for s in SLOTS}
    assert all(f.shape == (64, 64, 3) for f in faces.values())
    o = np.array(n["position"])
    assert abs(n["height_above_floor"] - o[1]) < 1e-6
    rng = np.random.default_rng(3)
    D = rng.normal(size=(400, 3))
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    want = tex(o + D * box_hit(o, D)[:, None])
    got = np.array([three_sample(faces, d) for d in D])
    err = np.abs(got - want).max(1)
    assert np.median(err) < 10 and np.percentile(err, 90) < 30
    # The test can tell: sampled without three's x mirror, the colours are wrong.
    bad = np.array([three_sample(faces, d, mirror=False) for d in D])
    assert np.median(np.abs(bad - want).max(1)) > 40
    # Known directions: straight at the -x wall is red-poor, at the +x wall red-rich, up is green-rich.
    assert three_sample(faces, np.array([-1.0, 0, 0]))[0] < 60
    assert three_sample(faces, np.array([1.0, 0, 0]))[0] > 200
    assert three_sample(faces, np.array([0, 1.0, 0]))[1] > 180


def test_unseen_pixels_are_filled_not_black(tmp_path):
    (tmp_path / "frames").mkdir()
    ks = frames_at(tmp_path / "frames", (0, 1.4, 0), dirs=[(1, 0, 0), (-1, 0, 0), (0, 0, 1)])
    out, nodes, _ = _build(tmp_path, ks, face_px=64, depth_px=32)
    n = nodes[0]
    assert 0.2 < n["coverage"] < 0.9
    for s in SLOTS:
        a = np.asarray(Image.open(out / n["faces"][s])).astype(int)
        assert a.sum(2).min() > 30  # nothing black, even on faces no frame saw (up, down, -z)


class _Stub:
    def __init__(self, pos, heading, stop=None):
        self.pos = np.array(pos, float)
        self.pose = np.eye(4)
        self.pose[:3, :3] = look((math.cos(heading), 0, math.sin(heading)))
        self.pose[:3, 3] = self.pos
        self.k = {} if stop is None else {"stop": stop}
        self._sharp = 100.0


def test_select_nodes_clusters_spacing_stops_and_cap():
    room = Room(room_dict())
    spots = [(-1.2, 1.5, 0.0), (1.2, 1.5, 0.0), (1.25, 1.5, 0.3)]  # the last is too close to the second
    frames = [_Stub(np.array(p) + [0.05 * (h % 2), 0, 0.05 * (h % 3)], h * math.pi / 4) for p in spots for h in range(8)]
    nodes = select_nodes(frames, room)
    assert len(nodes) == 2
    xs = sorted(n["position"][0] for n in nodes)
    assert xs[0] < -1 and xs[1] > 1
    assert all(abs(n["position"][1] - 1.5) < 1e-6 for n in nodes)
    # A frame tagged with a stop id makes its own node, honoured first.
    frames.append(_Stub((0.0, 1.6, -1.0), 0.0, stop=7))
    nodes = select_nodes(frames, room)
    assert nodes[0]["stop"] == 7 and np.allclose(nodes[0]["position"], (0, 1.6, -1.0))
    assert len(select_nodes(frames, room, max_nodes=1)) == 1
    # Stops a few tens of centimetres apart (one seated spot, the phone moved about) are one node.
    seated = [_Stub((0.1 * (s % 3), 1.2 + 0.2 * (s % 2), 0.1 * (s % 2)), s, stop=s) for s in range(1, 6)]
    nodes = select_nodes(seated, room)
    assert len(nodes) == 1 and nodes[0]["stop"] == 1 and len(nodes[0]["frames"]) == 5
    # No frames: no nodes; one lone frame: one node.
    assert select_nodes([], room) == []
    assert len(select_nodes([_Stub((0, 1.5, 0), 0)], room)) == 1


@pytest.mark.parametrize("partition", [False, True])
def test_neighbours_see_each_other_unless_blocked(tmp_path, partition):
    (tmp_path / "frames").mkdir()
    dirs = [(1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1), (1, 0, 1), (-1, 0, -1)]
    ks = frames_at(tmp_path / "frames", (-1.0, 1.4, 0), dirs, partition=partition)
    ks += frames_at(tmp_path / "frames", (1.0, 1.4, 0), dirs, start=50, partition=partition)
    _, nodes, _ = _build(tmp_path, ks, partition=partition, face_px=32, depth_px=32)
    assert len(nodes) == 2
    nb = nodes[0]["neighbors"][0]
    assert nb["id"] == nodes[1]["id"] and abs(nb["distance_m"] - 2.0) < 0.15
    assert nb["visible"] is (not partition)


def test_twin_build_writes_nodes(tmp_path):
    b = tmp_path / "scan"
    (b / "frames").mkdir(parents=True)
    (b / "room.json").write_text(json.dumps(room_dict()))
    P, F = box_mesh(step=0.08)  # the twin drops triangles with an edge over 12 cm
    (b / "mesh.bin").write_bytes(b"RSM1" + struct.pack("<II", len(P), F.size) + P.astype("<f4").tobytes() + F.astype("<u4").tobytes())
    ks = frames_at(b / "frames", (0.2, 1.5, 0.1))
    (b / "frames" / "frames.json").write_text(json.dumps(ks))
    out = tmp_path / "twin"
    twin = build_twin(b, out, node_px=32)
    assert len(twin["nodes"]) == 1
    n = twin["nodes"][0]
    assert n["id"] == "N1" and set(n["faces"]) == set(SLOTS) and n["neighbors"] == []
    assert n["faces"]["px"] == "img/nodes/N1_px.jpg" and 0 < n["coverage"] <= 1
    assert twin["processing"]["nodes"]["count"] == 1 and "convention" in twin["processing"]["nodes"]
    files = publish_files(out)
    assert all(p in files for p in n["faces"].values())
    saved = json.loads((out / "twin.json").read_text())
    assert saved["nodes"][0]["faces"] == n["faces"]


def test_floor_and_ceiling_hits_lie_on_roomplans_planes():
    from roomscan.nodes import DepthCube
    room = Room(room_dict())
    P, F = box_mesh()
    rng = np.random.default_rng(1)
    flat = (np.abs(P[:, 1] - LO[1]) < 1e-9) | (np.abs(P[:, 1] - HI[1]) < 1e-9)
    P[flat, 1] += rng.uniform(-0.03, 0.03, flat.sum())  # a noisy scanned floor and ceiling
    o = np.array([0.2, 1.3, 0.1])
    cube = DepthCube(o, P, F, room, 32)
    for s, c, y in (("ny", 1, room.floor_y), ("py", 2, room.ceiling_y)):
        D, X, nrm, t, cls = cube.full(s, 64)
        mid = (cls == c)
        assert mid.mean() > 0.9
        assert np.abs(X[mid, 1] - y).max() < 1e-4 and np.allclose(np.abs(nrm[mid, 1]), 1)


def test_floor_holes_continue_the_texture_not_a_blur():
    from roomscan.nodes import fill_holes, fill_texture
    N = 128
    j, i = np.mgrid[0:N, 0:N]
    img = np.repeat((120 + 60 * np.sin(i / 1.5))[..., None], 3, 2).astype(np.float32)  # floor boards
    seen = np.ones((N, N), bool)
    seen[40:90, 30:100] = False
    cls = np.ones((N, N), np.int8)
    smooth = fill_holes({"ny": img * seen[..., None]}, {"ny": seen.astype(np.float32)})["ny"]
    out = fill_texture(img * seen[..., None], seen, cls, smooth)
    hole = ~seen
    assert smooth[hole].std() < 20  # pull-push alone: a flat smear
    assert out[hole].std() > 30  # copied boards keep their contrast
    assert abs(out[hole].mean() - img[hole].mean()) < 15
    # Away from the floor, holes keep the smooth fill.
    other = fill_texture(img * seen[..., None], seen, np.zeros_like(cls), smooth)
    assert np.allclose(other[hole], smooth[hole])


def test_operator_feet_are_not_used_and_quality_is_reported(tmp_path):
    from roomscan.nodes import _View
    (tmp_path / "frames").mkdir()
    k = make_frame(tmp_path / "frames", "D.png", np.array([0.0, 1.4, 0.0]), (0, -1, 0.5))
    f = Frame(k, tmp_path / "frames")
    zb = (np.full(1, np.inf), 1000, 1, 1)
    v = _View(f, zb, 1.0)
    # Two floor points in view: one under the person (behind the phone), one ahead.
    X = np.array([[0.0, 0.0, -0.2], [0.0, 0.0, 0.8]], np.float32)
    x, y = v.project(X)
    assert ((x > 0) & (x < 160) & (y > 0) & (y < 160)).all()
    nrm = np.array([[0, 1.0, 0]] * 2, np.float32)
    D = (X - np.array([0.0, 1.4, 0.0], np.float32))
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    sc = v.score(X, nrm, D, 0.0, np.zeros(2, np.float32))[0]
    assert sc[0] == 0 and sc[1] > 0
    ks = frames_at(tmp_path / "frames", (0.3, 1.4, -0.2))
    _, nodes, summary = _build(tmp_path, ks, face_px=64, depth_px=32)
    q = summary["quality"][0]
    assert q["id"] == nodes[0]["id"] and set(q) >= {"seam_ratio", "ghost_risk", "blended", "depth_risk"}


def test_floor_fill_copies_floor_not_objects_standing_on_it():
    # A checker floor, an unseen hole at the top and a dark table foot at floor depth lower down:
    # the hole gets checker, never the foot.
    N = 128
    yy, xx = np.mgrid[0:N, 0:N]
    img = np.where(((yy // 8 + xx // 8) % 2)[..., None] == 0, [235.0, 190.0, 110.0], [245.0, 245.0, 240.0]).astype(np.float32)
    foot = (np.hypot(yy - 100, xx - 64) < 10)
    img[foot] = (60.0, 50.0, 45.0)
    seen = yy >= 48
    cls = np.ones((N, N), np.int8)
    smooth = np.full((N, N, 3), 200.0, np.float32)
    out = fill_texture(img, seen, cls, smooth)
    hole = out[:40]
    assert (hole.sum(-1) > 400).all()  # nothing dark copied up
    assert hole.std() > 20  # and texture, not a flat fill

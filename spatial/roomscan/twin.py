"""A scan bundle from the RoomScan app (Share scan bundle, unzipped) -> a small digital twin: the files
a shared web page (a Claude artifact) loads to show the room in 3D, its spots, shelves, photos and
measurements, for a team to work on together.

    roomscan twin <bundle folder> <out folder>

The LiDAR mesh, when the scan has one, is processed the way photogrammetry tools do it:
  - lined up with RoomPlan's room (undoing ARKit's world jump on older scans, then a point-to-plane
    fit onto the walls and floor);
  - trimmed to the room, and walls flattened: vertices within a few cm of a RoomPlan wall snap onto
    it (the clean-up room-plan apps do), so walls read flat instead of LiDAR-wavy;
  - painted from the kept frames: per triangle, the sharpest, most head-on, closest frame in which
    it's the nearest surface (a depth buffer per frame), with each frame's exposure evened out
    against the frames it overlaps (gain compensation, as in MVS texturing and panorama stitching);
  - shrunk for the web by vertex clustering, colours averaged per vertex.
"""

from __future__ import annotations

import json
import math
import shutil
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

FT = 0.3048


def _m(t):
    return np.array(t, dtype=np.float64).reshape(4, 4).T  # column-major 16 floats


def _flat(v):
    h = np.array([v[0], 0.0, v[2]])
    n = np.linalg.norm(h)
    return h / n if n > 1e-9 else np.array([1.0, 0.0, 0.0])


def _label(category: dict | str) -> str:
    raw = next(iter(category)) if isinstance(category, dict) else str(category)
    out = "".join(" " + c.lower() if c.isupper() else c for c in raw)
    return out[:1].upper() + out[1:]


def _rot_y(a, t):
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[:3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    m[:3, 3] = t
    return m


def _yaw_translation(m):
    return _rot_y(math.atan2(m[0, 2], m[0, 0]), m[:3, 3])


def read_mesh(path: Path):
    b = path.read_bytes()
    if b[:4] != b"RSM1":
        raise ValueError("not a RoomScan mesh")
    nv, nf = struct.unpack("<II", b[4:12])
    P = np.frombuffer(b, dtype="<f4", count=nv * 3, offset=12).reshape(nv, 3).astype(np.float64)
    F = np.frombuffer(b, dtype="<u4", count=nf, offset=12 + nv * 12).reshape(-1, 3).astype(np.int64)
    return P, F


class Room:
    def __init__(self, d: dict):
        self.d = d
        self.walls = []
        for i, w in enumerate(d.get("walls", [])):
            t = _m(w["transform"])
            self.walls.append(dict(i=i, c=t[:3, 3], x=_flat(t[:3, 0]), z=_flat(t[:3, 2]),
                                   w=float(w["dimensions"][0]), h=float(w["dimensions"][1])))
        self.holes = []
        for kind in ("doors", "windows", "openings"):
            for s in d.get(kind, []):
                t = _m(s["transform"])
                self.holes.append(dict(kind=kind[:-1], c=t[:3, 3], x=_flat(t[:3, 0]), z=_flat(t[:3, 2]),
                                       w=float(s["dimensions"][0]), h=float(s["dimensions"][1])))
        self.floor_y = min((w["c"][1] - w["h"] / 2 for w in self.walls), default=0.0)
        self.ceiling_y = max((w["c"][1] + w["h"] / 2 for w in self.walls), default=self.floor_y + 2.4)
        ends = [w["c"] + s * w["x"] * w["w"] / 2 for w in self.walls for s in (-1, 1)]
        self.lo = np.min(ends, 0) if ends else np.zeros(3)
        self.hi = np.max(ends, 0) if ends else np.zeros(3)
        self.centre = np.mean([w["c"] for w in self.walls], 0) if self.walls else np.zeros(3)


def fit_mesh(P: np.ndarray, room: Room, iterations: int = 10) -> np.ndarray:
    """Point-to-plane least squares on yaw and shift, onto the walls and floor. Returns the 4x4."""
    rng = np.random.default_rng(1)
    Q = P[rng.choice(len(P), min(len(P), 80000), replace=False)]
    yaw, t = 0.0, np.zeros(3)
    for it in range(iterations):
        R = _rot_y(yaw, t)
        X = Q @ R[:3, :3].T + t
        rows, rhs = [], []
        band = 0.25 if it < 4 else 0.08
        for w in room.walls:
            d = X - w["c"]
            near = (np.abs(d @ w["z"]) < band) & (np.abs(d @ w["x"]) < w["w"] / 2 - 0.1) & (np.abs(d[:, 1]) < w["h"] / 2 - 0.15)
            if near.sum() < 50:
                continue
            Xn = X[near]
            dX = np.stack([Xn[:, 2] - t[2], np.zeros(len(Xn)), -(Xn[:, 0] - t[0])], 1)
            rows.append(np.column_stack([dX @ w["z"], np.full(len(Xn), w["z"][0]), np.zeros(len(Xn)), np.full(len(Xn), w["z"][2])]))
            rhs.append(-((Xn - w["c"]) @ w["z"]))
        fl = np.abs(X[:, 1] - room.floor_y) < band
        if fl.sum():
            rows.append(np.column_stack([np.zeros(fl.sum()), np.zeros(fl.sum()), np.ones(fl.sum()), np.zeros(fl.sum())]))
            rhs.append(room.floor_y - X[fl, 1])
        if not rows:
            break
        A, b = np.vstack(rows), np.concatenate(rhs)
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
        yaw += sol[0]
        t += sol[1:]
    return _rot_y(yaw, t)


def snap_to_walls(P: np.ndarray, room: Room, within: float = 0.04) -> int:
    """Vertices within `within` of a wall plane (inside its extent, away from doors and windows) move
    onto it. Returns how many moved."""
    moved = np.zeros(len(P), bool)
    for w in room.walls:
        d = P - w["c"]
        off = d @ w["z"]
        near = (np.abs(off) < within) & (np.abs(d @ w["x"]) < w["w"] / 2) & (np.abs(d[:, 1]) < w["h"] / 2) & ~moved
        for h in room.holes:
            if abs((h["c"] - w["c"]) @ w["z"]) > 0.3:
                continue
            e = P - h["c"]
            near &= ~((np.abs(e @ h["x"]) < h["w"] / 2 + 0.05) & (np.abs(e[:, 1]) < h["h"] / 2 + 0.05))
        P[near] -= np.outer(off[near], w["z"])
        moved |= near
    return int(moved.sum())


class Frame:
    def __init__(self, k: dict, folder: Path, fix: np.ndarray | None = None):
        self.k = k
        pose = _m(k["transform"])
        if fix is not None:
            pose = fix @ pose
        self.pose = pose
        self.inv = np.linalg.inv(pose)
        self.pos = pose[:3, 3]
        self.file = folder / k["file"]
        self._img = None
        self.gain = np.ones(3)

    @property
    def img(self):
        if self._img is None:
            self._img = np.asarray(Image.open(self.file).convert("RGB"), dtype=np.float32)
        return self._img

    def project(self, P):
        c = P @ self.inv[:3, :3].T + self.inv[:3, 3]
        d = -c[:, 2]
        k = self.k
        x = k["cx"] + k["fx"] * c[:, 0] / np.maximum(d, 1e-6)
        y = k["cy"] - k["fy"] * c[:, 1] / np.maximum(d, 1e-6)
        return x, y, d

    def sharpness(self) -> float:
        """Variance of the Laplacian: how much fine detail survived (blurry frames score low)."""
        g = Image.open(self.file).convert("L").filter(ImageFilter.Kernel((3, 3), [0, 1, 0, 1, -4, 1, 0, 1, 0], 1, 128))
        return float(np.asarray(g, dtype=np.float32).var())

    def sample(self, x, y):
        I = self.img
        h, w, _ = I.shape
        x = np.clip(x, 0, w - 1.001)
        y = np.clip(y, 0, h - 1.001)
        x0, y0 = x.astype(int), y.astype(int)
        fx, fy = (x - x0)[:, None], (y - y0)[:, None]
        top = I[y0, x0] * (1 - fx) + I[y0, x0 + 1] * fx
        bot = I[y0 + 1, x0] * (1 - fx) + I[y0 + 1, x0 + 1] * fx
        return top * (1 - fy) + bot * fy


def paint(P: np.ndarray, F: np.ndarray, frames: list[Frame], report: dict, centre=None):
    """Per-vertex colours (uint8 RGB) for the mesh, from the frames, and the faces re-wound so each
    faces the frame that painted it (else the room's middle): drawn one-sided, walls between a
    viewer and the room then vanish from outside, as in a dollhouse view."""
    A, B, C = P[F[:, 0]], P[F[:, 1]], P[F[:, 2]]
    cen = (A + B + C) / 3
    n = np.cross(B - A, C - A)
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    sharp = np.array([f.sharpness() for f in frames])
    rel = np.clip(sharp / (np.median(sharp) + 1e-6), 0.3, 1.5)  # blurrier frames count for less
    report["frame_sharpness"] = {"min": round(float(sharp.min()), 1), "median": round(float(np.median(sharp)), 1)}

    best = np.full(len(F), -1.0)
    choice = np.full(len(F), -1)
    visible_by = []  # per frame: mask of triangles visible in it (for gain compensation)
    for fi, f in enumerate(frames):
        k = f.k
        ds = 4
        W, H = k["width"] // ds, k["height"] // ds
        x, y, d = f.project(P)
        x /= ds
        y /= ds
        ok = (d > 0.1) & (x >= 0) & (y >= 0) & (x < W - 1) & (y < H - 1)
        zb = np.full(W * H, np.inf)
        for ox in (0, 1):
            for oy in (0, 1):
                np.minimum.at(zb, (y[ok].astype(int) + oy) * W + x[ok].astype(int) + ox, d[ok])
        cx, cy, cd = f.project(cen)
        inside = (cd > 0.2) & (cd < 6) & (cx > 8) & (cy > 8) & (cx < k["width"] - 8) & (cy < k["height"] - 8)
        zi = np.where(inside, np.clip(cy / ds, 0, H - 1).astype(int) * W + np.clip(cx / ds, 0, W - 1).astype(int), 0)
        vis = inside & (cd <= zb[zi] + 0.04 + 0.02 * cd)
        toc = f.pos - cen
        dist = np.linalg.norm(toc, axis=1)
        facing = np.abs((toc / dist[:, None] * n).sum(1))
        vis &= facing > 0.2
        visible_by.append(vis)
        score = np.where(vis, facing ** 2 / dist * rel[fi], -1)
        upd = score > best
        best[upd] = score[upd]
        choice[upd] = fi

    # Gain compensation: per frame RGB gain so overlapping frames agree, least squares in log space,
    # anchored so the gains average to 1.
    nF = len(frames)
    sel = np.random.default_rng(2).choice(len(F), min(len(F), 40000), replace=False)
    obs = {}  # frame -> (triangle ids, mean colours)
    for fi, f in enumerate(frames):
        ids = sel[visible_by[fi][sel]]
        if len(ids) == 0:
            continue
        x, y, _ = f.project(cen[ids])
        obs[fi] = (ids, np.log(np.maximum(f.sample(x, y), 4.0)))
    rows, rhs = [], []
    keys = list(obs)
    for ai, a in enumerate(keys):
        ia, la = obs[a]
        for b in keys[ai + 1:]:
            ib, lb = obs[b]
            common, pa, pb = np.intersect1d(ia, ib, return_indices=True)
            if len(common) < 30:
                continue
            diff = np.median(la[pa] - lb[pb], axis=0)  # log(gain_b) - log(gain_a) should cancel this
            r = np.zeros(nF)
            r[a], r[b] = -1, 1
            rows.append((r, diff, math.sqrt(len(common))))
    logg = np.zeros((nF, 3))
    if rows:
        A = np.array([r * w for r, _, w in rows] + [np.ones(nF) * 3.0])
        for ch in range(3):
            b = np.array([d[ch] * w for _, d, w in rows] + [0.0])
            logg[:, ch], *_ = np.linalg.lstsq(A, b, rcond=None)
    for fi, f in enumerate(frames):
        f.gain = np.exp(np.clip(logg[fi], -0.7, 0.7))
    report["exposure_gain_range"] = [round(float(np.exp(logg.min())), 2), round(float(np.exp(logg.max())), 2)]

    # Colour each triangle's corners from its frame, then average per vertex.
    acc = np.zeros((len(P), 3))
    cnt = np.zeros(len(P))
    for fi in np.unique(choice[choice >= 0]):
        f = frames[fi]
        tri = np.nonzero(choice == fi)[0]
        for j in range(3):
            v = F[tri, j]
            x, y, _ = f.project(P[v])
            col = f.sample(x, y) * f.gain
            np.add.at(acc, v, col)
            np.add.at(cnt, v, 1)
    report["triangles_painted"] = round(float((choice >= 0).mean()), 3)
    colours = np.full((len(P), 3), 205.0)
    m = cnt > 0
    colours[m] = acc[m] / cnt[m, None]
    toward = np.where((choice >= 0)[:, None], np.array([f.pos for f in frames])[np.maximum(choice, 0)],
                      (centre if centre is not None else cen.mean(0)))
    flip = ((toward - cen) * n).sum(1) < 0
    F = F.copy()
    F[flip] = F[flip][:, [0, 2, 1]]
    return np.clip(colours, 0, 255).astype(np.uint8), F


def decimate(P, F, Cl, cell: float):
    """Vertex clustering: one vertex per `cell`-sized cube (mean position and colour)."""
    key = np.floor((P - P.min(0)) / cell).astype(np.int64)
    _, inv, counts = np.unique(key, axis=0, return_inverse=True, return_counts=True)
    inv = inv.reshape(-1)
    nP = np.zeros((len(counts), 3))
    nC = np.zeros((len(counts), 3))
    np.add.at(nP, inv, P)
    np.add.at(nC, inv, Cl.astype(np.float64))
    nP /= counts[:, None]
    nC /= counts[:, None]
    nF = inv[F]
    keep = (nF[:, 0] != nF[:, 1]) & (nF[:, 1] != nF[:, 2]) & (nF[:, 0] != nF[:, 2])
    nF = nF[keep]
    return nP, nF, nC.astype(np.uint8)


def write_web_mesh(path: Path, P, F, Cl, ceiling: np.ndarray):
    """RTW1: vertex count, model index count, ceiling index count; positions f32, colours u8 RGB,
    then model indices and ceiling indices (u32)."""
    model, ceil = F[~ceiling], F[ceiling]
    with open(path, "wb") as fh:
        fh.write(b"RTW1")
        fh.write(struct.pack("<III", len(P), model.size, ceil.size))
        fh.write(P.astype("<f4").tobytes())
        fh.write(Cl.astype(np.uint8).tobytes())
        if (len(P) * 3) % 4:
            fh.write(b"\0" * (4 - (len(P) * 3) % 4))  # keep the indices 4-byte aligned
        fh.write(model.astype("<u4").tobytes())
        fh.write(ceil.astype("<u4").tobytes())


def _photo_subject(pos, fwd, room_objects, room: Room):
    best = None
    for i, (c, _) in enumerate(room_objects):
        d = c - pos
        d[1] = 0
        l = np.linalg.norm(d)
        if l > 0.05 and (d / l) @ fwd > math.cos(math.radians(30)) and (best is None or l < best[1]):
            best = (("object", i), l)
    if best:
        return best[0]
    for w in room.walls:
        d = w["c"] - pos
        d[1] = 0
        l = np.linalg.norm(d)
        if l > 0.05 and (d / l) @ fwd > math.cos(math.radians(40)) and (best is None or l < best[1]):
            best = (("wall", w["i"]), l)
    return best[0] if best else None


def build_twin(bundle: Path, out: Path, cell: float = 0.025) -> dict:
    bundle, out = Path(bundle), Path(out)
    if not (bundle / "room.json").exists():  # a zip of the Scans folder: one scan inside
        inner = sorted(p.parent for p in bundle.rglob("room.json"))
        if not inner:
            raise FileNotFoundError("no room.json in the bundle")
        bundle = inner[0]
    out.mkdir(parents=True, exist_ok=True)
    (out / "img").mkdir(exist_ok=True)
    info = json.loads((bundle / "info.json").read_text()) if (bundle / "info.json").exists() else {}
    rd = json.loads((bundle / "room.json").read_text())
    room = Room(rd)
    report: dict = {}

    def load(rel, default):
        p = bundle / rel
        return json.loads(p.read_text()) if p.exists() else default

    names = load("names.json", {})
    products = load("products.json", [])
    measured = load("measurements.json", {})
    elevations = load("elevations/elevations.json", [])
    fronts = load("elevations/storage.json", [])
    floor = load("elevations/floor.json", None)
    photos = load("photos/photos.json", [])
    frames_meta = load("frames/frames.json", [])

    def copy(src: Path, name: str, max_side: int | None = None) -> str | None:
        if not src.exists():
            return None
        dst = out / "img" / name
        if max_side:
            im = Image.open(src)
            im.thumbnail((max_side, max_side))
            im.convert("RGB").save(dst, quality=85)
        else:
            shutil.copyfile(src, dst)
        return f"img/{name}"

    # Walls, openings, objects, as the page draws them.
    elev_by_wall = {e["wall"]: e for e in elevations}
    walls = []
    for w in room.walls:
        e = elev_by_wall.get(w["i"])
        flipped = bool(e["flipped"]) if e else ((room.centre - w["c"]) @ w["z"] < 0)
        normal = -w["z"] if flipped else w["z"]
        along = -w["x"] if flipped else w["x"]
        a = w["c"] - along * w["w"] / 2
        b = w["c"] + along * w["w"] / 2
        key = f"Wall W{w['i'] + 1}"
        walls.append(dict(key=key, name=names.get(key), a=[a[0], a[2]], b=[b[0], b[2]], y0=w["c"][1] - w["h"] / 2,
                          height=w["h"], length=w["w"], normal=[normal[0], normal[2]],
                          elevation=copy(bundle / "elevations" / e["file"], e["file"]) if e else None))
    holes = [dict(kind=h["kind"], center=h["c"].tolist(), along=[h["x"][0], h["x"][2]], width=h["w"], height=h["h"])
             for h in room.holes]
    objects, obj_centres = [], []
    front_by_obj = {f["object"]: f for f in fronts}
    for i, o in enumerate(rd.get("objects", [])):
        t = _m(o["transform"])
        label = _label(o["category"])
        key = f"{i + 1} {label}"
        wdt, hgt, dep = (float(v) for v in o["dimensions"])
        fr = front_by_obj.get(i)
        front = None
        if fr:
            edges = [0.0] + sorted(fr["shelves"]) + [fr["height"]]
            openings = [edges[k] - edges[k - 1] for k in range(1, len(edges)) if edges[k] - edges[k - 1] > 0.05]
            front = dict(image=copy(bundle / "elevations" / fr["file"], fr["file"]), shelves=fr["shelves"],
                         openings_top_first=openings[::-1], width=fr["width"], height=fr["height"], depth=fr["depth"])
        objects.append(dict(key=key, label=label, name=names.get(key), center=t[:3, 3].tolist(),
                            axis=[t[0, 0], t[2, 0]], size=[wdt, hgt, dep], front=front))
        obj_centres.append((t[:3, 3], key))

    floor_poly = []
    fls = rd.get("floors", [])
    if fls and fls[0].get("polygonCorners"):
        ft = _m(fls[0]["transform"])
        floor_poly = [(ft @ np.array([*p, 1]))[[0, 2]].tolist() for p in fls[0]["polygonCorners"]]
    floor_out = dict(polygon=floor_poly)
    if floor:
        floor_out.update(image=copy(bundle / "elevations" / floor["file"], floor["file"]),
                         bounds=[floor["minX"], floor["minZ"], floor["maxX"], floor["maxZ"]], y=floor["y"])

    photo_out = []
    for n_, p in enumerate(photos):
        pose = _m(p["transform"])
        pos, fwd = pose[:3, 3], _flat(-pose[:3, 2])
        subj = _photo_subject(pos, fwd, obj_centres, room)
        subject = None
        if subj and subj[0] == "object":
            subject = obj_centres[subj[1]][1]
        elif subj:
            subject = f"Wall W{subj[1] + 1}"
        photo_out.append(dict(id=f"P{n_ + 1}", image=copy(bundle / "photos" / p["file"], p["file"], 1600),
                              position=pos.tolist(), direction=[fwd[0], fwd[2]], subject=subject, date=p.get("date")))

    # The mesh.
    mesh_out = None
    if (bundle / "mesh.bin").exists():
        P, F = read_mesh(bundle / "mesh.bin")
        report["mesh_in"] = {"vertices": len(P), "triangles": len(F)}
        m_frames = [k for k in frames_meta if k["file"].startswith("M")]
        fix = np.eye(4)
        # Older scans: ARKit's mesh mode moved the world origin and nothing undid it. The first mesh
        # frame was taken before the move, the second after; the phone barely moved between them.
        if len(m_frames) > 1:
            a, b = _m(m_frames[0]["transform"]), _m(m_frames[1]["transform"])
            if np.linalg.norm(a[:3, 3] - b[:3, 3]) > 0.5:
                fix = _yaw_translation(a @ np.linalg.inv(b))
                report["undid_world_jump_m"] = round(float(np.linalg.norm(fix[:3, 3])), 2)
        P = P @ fix[:3, :3].T + fix[:3, 3]
        fit = fit_mesh(P, room)
        P = P @ fit[:3, :3].T + fit[:3, 3]
        report["fit"] = {"yaw_deg": round(math.degrees(math.atan2(fit[0, 2], fit[0, 0])), 2),
                         "shift_m": [round(float(v), 3) for v in fit[:3, 3]]}
        # Frames into the same coordinates: mesh-pass frames after the jump get both moves.
        frames = []
        for idx, k in enumerate(frames_meta):
            if not (bundle / "frames" / k["file"]).exists():
                continue
            is_m = k["file"].startswith("M")
            jumped = is_m and "undid_world_jump_m" in report and k is not m_frames[0]
            frames.append(Frame(k, bundle / "frames", fit @ fix if jumped else (fit if is_m else None)))
        frames = [f for f in frames if f.img.mean() >= 40]  # nearly black frames out
        # Trim to the room.
        cen = P[F].mean(1)
        lo, hi = room.lo - 0.4, room.hi + 0.4
        keep = (cen[:, 0] > lo[0]) & (cen[:, 0] < hi[0]) & (cen[:, 2] > lo[2]) & (cen[:, 2] < hi[2]) \
            & (cen[:, 1] > room.floor_y - 0.3) & (cen[:, 1] < room.ceiling_y + 0.3)
        F = F[keep]
        report["snapped_to_walls"] = snap_to_walls(P, room)
        colours, F = paint(P, F, frames, report, centre=room.centre)
        P2, F2, C2 = decimate(P, F, colours, cell)
        cen2 = P2[F2].mean(1)
        nrm = np.cross(P2[F2[:, 1]] - P2[F2[:, 0]], P2[F2[:, 2]] - P2[F2[:, 0]])
        nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
        ceiling = (cen2[:, 1] > room.ceiling_y - 0.3) & (np.abs(nrm[:, 1]) > 0.7)
        write_web_mesh(out / "mesh.bin", P2, F2, C2, ceiling)
        mesh_out = dict(file="mesh.bin", vertices=len(P2), triangles=int(len(F2)), ceiling_triangles=int(ceiling.sum()))
        report["mesh_out"] = mesh_out

    twin = dict(
        name=info.get("name", bundle.name), date=info.get("date"), units="imperial",
        floor_y=room.floor_y, ceiling_y=room.ceiling_y, centre=room.centre.tolist(),
        bounds=[room.lo.tolist(), room.hi.tolist()],
        walls=walls, openings=holes, objects=objects, floor=floor_out, photos=photo_out, mesh=mesh_out,
        seed=dict(names=names, products=products, measured=measured), processing=report,
    )
    (out / "twin.json").write_text(json.dumps(twin, separators=(",", ":"), default=float))
    return twin

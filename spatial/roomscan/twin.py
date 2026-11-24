"""A scan bundle from the RoomScan app (Share scan bundle, unzipped) -> a small digital twin: a folder
holding a web page (index.html) and everything it loads, ready to publish as a shared Claude artifact,
where a team walks the room in 3D, opens its spots (shelves, sizes, products, notes) and measures.

    roomscan twin <bundle folder or .zip> <out folder>

Publish it with the Artifact tool: file_path out/index.html, root out, files = every other file in out
(twin.json, mesh.b64.txt, img/*), capabilities {db: {}, user: {scopes: ["profile"]}, assets: {}}.

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
        # RoomPlan's floor outline (iOS 17+), in world x, z: the room's true shape, for cropping.
        self.outline = None
        for f in d.get("floors", []):
            corners = f.get("polygonCorners") or []
            if len(corners) >= 3:
                t = _m(f["transform"])
                c = np.array(corners, dtype=np.float64)[:, :2]
                world = t[:3, 3] + c[:, :1] * t[:3, 0] + c[:, 1:2] * t[:3, 1]
                self.outline = world[:, [0, 2]]
                break

    def inside(self, xz: np.ndarray, margin: float = 0.12) -> np.ndarray:
        """Which points (x, z) lie inside the floor outline or within `margin` of it. Without an
        outline, the walls' bounding box grown by `margin`."""
        if self.outline is None:
            lo, hi = self.lo - margin, self.hi + margin
            return (xz[:, 0] > lo[0]) & (xz[:, 0] < hi[0]) & (xz[:, 1] > lo[2]) & (xz[:, 1] < hi[2])
        poly = self.outline
        x, z = xz[:, 0:1], xz[:, 1:2]
        a, b = poly[None, :, :], np.roll(poly, -1, 0)[None, :, :]
        ax, az, bx, bz = a[..., 0], a[..., 1], b[..., 0], b[..., 1]
        crosses = ((az > z) != (bz > z)) & (x < (bx - ax) * (z - az) / np.where(bz == az, 1e-12, bz - az) + ax)
        inside = crosses.sum(1) % 2 == 1
        ex, ez = bx - ax, bz - az
        s = np.clip(((x - ax) * ex + (z - az) * ez) / np.maximum(ex * ex + ez * ez, 1e-12), 0, 1)
        dist = np.hypot(x - (ax + s * ex), z - (az + s * ez)).min(1)
        return inside | (dist < margin)


def level_offset(P: np.ndarray, F: np.ndarray, room: Room) -> float:
    """How far to move the mesh up to put its floor on RoomPlan's (the ceiling cross-checks). The
    switch into the LiDAR pass can shift the world by tens of centimetres vertically, more than the
    fit's search band. The floor is the lowest strong peak of upward-facing area by height, the
    ceiling the highest of downward-facing area. 0 when there's no clear floor."""
    if len(F) == 0:
        return 0.0
    A, B = P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]]
    n = np.cross(A, B)
    area = np.linalg.norm(n, axis=1) / 2
    ny = n[:, 1] / (2 * area + 1e-12)
    y = P[F].mean(1)[:, 1]

    def peak(mask, lowest):
        if area[mask].sum() < 0.5:
            return None
        lo, hi = y[mask].min(), y[mask].max()
        edges = np.arange(lo, hi + 0.04, 0.02)
        if len(edges) < 2:
            return None
        h, _ = np.histogram(y[mask], bins=edges, weights=area[mask])
        strong = np.nonzero(h >= max(0.25 * h.max(), 0.3))[0]
        if not len(strong):
            return None
        i = strong[0] if lowest else strong[-1]
        near = mask & (np.abs(y - (edges[i] + 0.01)) < 0.03)
        return float(np.median(y[near]))

    f, c = peak(ny > 0.9, True), peak(ny < -0.9, False)
    df = room.floor_y - f if f is not None else None
    dc = room.ceiling_y - c if c is not None else None
    if df is None:
        return 0.0
    if dc is not None and abs(df - dc) < 0.06:
        return (df + dc) / 2
    return df


def fit_mesh(P: np.ndarray, room: Room, iterations: int = 10, F: np.ndarray | None = None) -> np.ndarray:
    """Point-to-plane least squares on yaw and shift, onto the walls and floor. Returns the 4x4.
    With the faces, it first levels the mesh's floor onto RoomPlan's."""
    rng = np.random.default_rng(1)
    Q = P[rng.choice(len(P), min(len(P), 80000), replace=False)]
    yaw, t = 0.0, np.zeros(3)
    if F is not None:
        t[1] = level_offset(P, F, room)
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


def smooth_choice(F: np.ndarray, bs: np.ndarray, bf: np.ndarray, iterations: int = 3, keep: float = 0.6) -> np.ndarray:
    """Neighbouring triangles painted from different frames make speckle (each frame's exposure,
    focus and small misalignments differ). Like the label smoothing in mesh texturing tools: a
    triangle takes the frame most of its edge neighbours use, among its top three frames scoring at
    least `keep` of its best."""
    choice = bf[0].copy()
    e = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]])
    t = np.tile(np.arange(len(F)), 3)
    key = np.minimum(e[:, 0], e[:, 1]).astype(np.int64) * (int(F.max()) + 1) + np.maximum(e[:, 0], e[:, 1])
    order = np.argsort(key, kind="stable")
    ks, ts = key[order], t[order]
    same = ks[1:] == ks[:-1]
    a, b = ts[:-1][same], ts[1:][same]
    pa, pb = np.concatenate([a, b]), np.concatenate([b, a])  # neighbour pairs, both ways
    ok = (bf >= 0) & (bs >= keep * bs[0])
    for _ in range(iterations):
        votes = np.stack([np.bincount(pa, weights=(choice[pb] == bf[j][pa]).astype(float), minlength=len(F)) for j in range(3)])
        votes = np.where(ok, votes + 1e-3 * bs, -1)
        pick = votes.argmax(0)
        choice = np.where(bf[0] >= 0, bf[pick, np.arange(len(F))], -1)
    return choice


def drop_slivers(P: np.ndarray, F: np.ndarray, longest: float = 0.12) -> np.ndarray:
    """Triangles with an edge longer than `longest`: stretched shards from LiDAR noise and clustering."""
    a, b, c = P[F[:, 0]], P[F[:, 1]], P[F[:, 2]]
    edge = np.maximum.reduce([np.linalg.norm(a - b, axis=1), np.linalg.norm(b - c, axis=1), np.linalg.norm(c - a, axis=1)])
    return F[edge <= longest]


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

    # The three best frames per triangle (score, frame), for smoothing the choice afterwards.
    bs = np.full((3, len(F)), -1.0)
    bf = np.full((3, len(F)), -1)
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
        m1 = score > bs[0]
        m2 = ~m1 & (score > bs[1])
        m3 = ~m1 & ~m2 & (score > bs[2])
        bs[2, m1 | m2], bf[2, m1 | m2] = bs[1, m1 | m2], bf[1, m1 | m2]
        bs[1, m1], bf[1, m1] = bs[0, m1], bf[0, m1]
        bs[0, m1], bf[0, m1] = score[m1], fi
        bs[1, m2], bf[1, m2] = score[m2], fi
        bs[2, m3], bf[2, m3] = score[m3], fi
    choice = smooth_choice(F, bs, bf)
    report["frame_switches_smoothed"] = int((choice != bf[0]).sum())

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
    report["_choice"] = choice  # the frame per triangle, for textured output
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
    then model indices and ceiling indices (u32). Written base64-encoded as text: artifacts serve
    text, not raw binary."""
    import base64

    model, ceil = F[~ceiling], F[ceiling]
    parts = [b"RTW1", struct.pack("<III", len(P), model.size, ceil.size), P.astype("<f4").tobytes(),
             Cl.astype(np.uint8).tobytes()]
    if (len(P) * 3) % 4:
        parts.append(b"\0" * (4 - (len(P) * 3) % 4))  # keep the indices 4-byte aligned
    parts += [model.astype("<u4").tobytes(), ceil.astype("<u4").tobytes()]
    path.write_text(base64.b64encode(b"".join(parts)).decode("ascii"))


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


def confirm_shelves(P: np.ndarray, F: np.ndarray, rd: dict, objects: list, tol: float = 0.04) -> int:
    """Shelf edges found in a unit's front photo, checked against the LiDAR mesh: a shelf is a flat,
    upward-facing surface inside the unit's box, so peaks in the height histogram of those triangles
    (weighted by area) confirm an edge within `tol`. The mesh misses shelves covered by bins (it sees
    the bins' tops) and the photo can take a box edge for a shelf, so each edge gets a flag rather than
    either replacing the other. On a real closet the two agreed within an inch where both found one,
    and the mesh didn't back the box edge the photo had taken for a shelf. Returns how many confirmed."""
    A, B, C = P[F[:, 0]], P[F[:, 1]], P[F[:, 2]]
    nrm = np.cross(B - A, C - A)
    area = np.linalg.norm(nrm, axis=1) / 2
    up = nrm[:, 1] / (2 * area + 1e-12) > 0.9
    cen = (A + B + C) / 3
    confirmed = 0
    for i, o in enumerate(objects):
        fr = o.get("front")
        if not fr or not fr["shelves"]:
            continue
        t = _m(rd["objects"][i]["transform"])
        c, x, z = t[:3, 3], t[:3, 0], t[:3, 2]
        W, H, D = (float(v) for v in rd["objects"][i]["dimensions"])
        d = cen - c
        inside = up & (np.abs(d @ x) < W / 2 - 0.03) & (np.abs(d @ z) < D / 2 + 0.03) & (np.abs(d[:, 1]) < H / 2 + 0.02)
        hs = cen[inside, 1] - (c[1] - H / 2)
        bins = np.arange(-0.02, H + 0.04, 0.01)
        hist, _ = np.histogram(hs, bins=bins, weights=area[inside])
        sm = np.convolve(hist, [0.25, 0.5, 0.25], "same")
        peaks = []
        for k in np.argsort(-sm):
            if sm[k] < 0.04 * (sm.sum() + 1e-9):
                break
            if all(abs(k - q) > 6 for q in peaks):
                peaks.append(k)
        tops = [bins[k] + 0.005 for k in peaks]
        fr["confirmed"] = [any(abs(sh - tp) < tol for tp in tops) for sh in fr["shelves"]]
        confirmed += sum(fr["confirmed"])
    return confirmed


def write_textured_mesh(out: Path, P, F, choice, frames: list, room: "Room", width: int = 960) -> dict:
    """RTW2: triangle count, the box positions are measured in (min xyz, size xyz, f32), then per
    corner positions as u16 across that box (a fraction of a millimetre) and texture coordinates as
    u16 across the frame (v up, as WebGL samples it); triangles sorted into groups by frame, ceiling
    groups apart. The frames used are written, exposure-corrected, to img/f/. Base64 text, as RTW1."""
    import base64

    cen = P[F].mean(1)
    nrm = np.cross(P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]])
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
    ceiling = (cen[:, 1] > room.ceiling_y - 0.3) & (np.abs(nrm[:, 1]) > 0.7)
    order = np.lexsort((choice, ceiling))  # model groups first, then ceiling; by frame within each
    F, choice, ceiling = F[order], choice[order], ceiling[order]
    (out / "img" / "f").mkdir(parents=True, exist_ok=True)
    uv = np.zeros((len(F), 3, 2))
    groups, names = [], {}
    start = 0
    while start < len(F):
        k, c = choice[start], ceiling[start]
        end = start
        while end < len(F) and choice[end] == k and ceiling[end] == c:
            end += 1
        image = None
        if k >= 0:
            f = frames[k]
            if k not in names:
                im = Image.fromarray(np.clip(f.img * f.gain, 0, 255).astype(np.uint8))
                if im.width > width:
                    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
                names[k] = f"img/f/{Path(f.k['file']).stem}.jpg"
                im.save(out / names[k], quality=82)
            image = names[k]
            for j in range(3):
                x, y, _ = f.project(P[F[start:end, j]])
                uv[start:end, j, 0] = x / f.k["width"]
                uv[start:end, j, 1] = 1 - y / f.k["height"]
        groups.append(dict(start=start, count=end - start, image=image, ceiling=bool(c)))
        start = end
    corners = P[F].reshape(-1, 3)
    lo = corners.min(0)
    size = np.maximum(corners.max(0) - lo, 1e-6)
    pos = np.clip(np.round((corners - lo) / size * 65535), 0, 65535).astype("<u2").reshape(-1)
    uvq = np.clip(np.round(uv * 65535), 0, 65535).astype("<u2").reshape(-1)
    blob = b"RTW2" + struct.pack("<I", len(F)) + np.concatenate([lo, size]).astype("<f4").tobytes() + pos.tobytes() + uvq.tobytes()
    (out / "mesh.b64.txt").write_text(base64.b64encode(blob).decode("ascii"))
    return dict(file="mesh.b64.txt", format="RTW2", triangles=int((~ceiling).sum()), ceiling_triangles=int(ceiling.sum()),
                frames=len(names), groups=groups)


def build_twin(bundle: Path, out: Path, cell: float = 0.025, textured: bool = True) -> dict:
    bundle, out = Path(bundle), Path(out)
    if bundle.suffix == ".zip":
        import tempfile
        import zipfile

        tmp = Path(tempfile.mkdtemp(prefix="roomscan-bundle-"))
        with zipfile.ZipFile(bundle) as z:
            for m in z.namelist():  # unpack only inside tmp
                if m.startswith("/") or ".." in Path(m).parts:
                    raise ValueError(f"unsafe path in zip: {m}")
            z.extractall(tmp)
        bundle = tmp
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
        fit = fit_mesh(P, room, F=F)
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
        keep = room.inside(cen[:, [0, 2]]) & (cen[:, 1] > room.floor_y - 0.1) & (cen[:, 1] < room.ceiling_y + 0.15)
        report["outside_room_dropped"] = int((~keep).sum())
        F = F[keep]
        report["shelf_edges_confirmed_by_depth"] = confirm_shelves(P, F, rd, objects)
        report["snapped_to_walls"] = snap_to_walls(P, room)
        if textured:
            # Shrink first, then paint with real texture: each triangle mapped onto its frame's photo
            # (exposure correction baked into the photo), as photogrammetry tools texture a mesh.
            dummy = np.zeros((len(P), 3), np.uint8)
            P2, F2, _ = decimate(P, F, dummy, cell)
            n0 = len(F2)
            F2 = drop_slivers(P2, F2)
            report["slivers_dropped"] = n0 - len(F2)
            _, F2 = paint(P2, F2, frames, report, centre=room.centre)
            choice = report.pop("_choice")
            mesh_out = write_textured_mesh(out, P2, F2, choice, frames, room)
        else:
            colours, F = paint(P, F, frames, report, centre=room.centre)
            report.pop("_choice", None)
            P2, F2, C2 = decimate(P, F, colours, cell)
            cen2 = P2[F2].mean(1)
            nrm = np.cross(P2[F2[:, 1]] - P2[F2[:, 0]], P2[F2[:, 2]] - P2[F2[:, 0]])
            nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
            ceiling = (cen2[:, 1] > room.ceiling_y - 0.3) & (np.abs(nrm[:, 1]) > 0.7)
            write_web_mesh(out / "mesh.b64.txt", P2, F2, C2, ceiling)
            mesh_out = dict(file="mesh.b64.txt", vertices=len(P2), triangles=int(len(F2)), ceiling_triangles=int(ceiling.sum()))
        report["mesh_out"] = mesh_out

    twin = dict(
        name=info.get("name", bundle.name), date=info.get("date"), units="imperial",
        floor_y=room.floor_y, ceiling_y=room.ceiling_y, centre=room.centre.tolist(),
        bounds=[room.lo.tolist(), room.hi.tolist()],
        walls=walls, openings=holes, objects=objects, floor=floor_out, photos=photo_out, mesh=mesh_out,
        seed=dict(names=names, products=products, measured=measured), processing=report,
    )
    (out / "twin.json").write_text(json.dumps(twin, separators=(",", ":"), default=float))
    page = (Path(__file__).with_name("twin_page.html")).read_text()
    name = str(twin["name"]).replace("<", "").replace("&", "and")
    (out / "index.html").write_text(page.replace("{{TITLE}}", f"{name} Twin").replace("{{NAME}}", name))
    return twin


def publish_files(out: Path) -> dict:
    """The Artifact tool's `files` map for a twin folder (everything but index.html)."""
    out = Path(out)
    return {str(p.relative_to(out)): str(p.relative_to(out)) for p in sorted(out.rglob("*"))
            if p.is_file() and p.name != "index.html"}

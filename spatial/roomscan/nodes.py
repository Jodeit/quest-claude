"""360 view nodes for the twin: standing spots picked from the keyframes, each with a cube panorama
re-rendered from the textured room, so the page can offer a Matterport-style photo-hop tour.

Per node:
  - a depth cube: the cleaned room mesh rasterised from the node (perspective-correct z-buffer, one
    pinhole camera per face), with RoomPlan's walls, floor and ceiling as planes behind it, so a hole
    in the mesh still gets a depth. Each depth pixel keeps the plane of what it hit, so the full-size
    face intersects every pixel's own ray with that plane (sharp, no depth stair-steps);
  - colour: each 3D hit projected into the frames that see it (a z-buffer per frame), scored by frame
    sharpness x how squarely the frame faces the surface x how close the frame stood to the node (less
    parallax) / distance, the best two blended with the frames' exposure gains;
  - pixels no frame sees are filled by pull-push (averages pushed in from their neighbours), never
    black. `coverage` is the fraction of cube pixels coloured from a real frame.

CONVENTION (three.js). Files are named by the slot they take in
    new THREE.CubeTextureLoader().load([px, nx, py, ny, pz, nz])
and are oriented so that texture, set as scene.background with the camera at the node, shows the
room upright and unmirrored in the twin's own world coordinates (x right, y up, z toward the viewer,
the same axes three.js uses). three.js mirrors x when it samples a CubeTexture background
(flipEnvMap = -1: it looks up (-x, y, z)), so a slot's image shows the world direction with x negated:
    px: looking toward world -x      nx: toward world +x
    py: looking up (+y)              ny: down (-y)
    pz: toward world +z              nz: toward world -z
Each image is what a camera at the node sees looking that way (right-handed, no mirror): e.g. in pz
(looking along +z, up +y) the right-hand side of the image is world -x; in px (looking along -x) the
right-hand side is world -z, top is +y. py's top edge is world -z, ny's top edge world +z (both with
world -x to the right). Do not set backgroundRotation or flip the texture. The page's camera must sit
at the node position (or use the node's background with the camera's rotation only).
In GL terms: slot s, pixel column i, row j (row 0 = top of the jpg; three uploads cube faces with
flipY = false), sc = 2(i+.5)/N - 1, tc = 2(j+.5)/N - 1, r = the GL cube-map direction for that face
and (sc, tc), world direction = (-r.x, r.y, r.z).
"""

from __future__ import annotations

import functools
import math
import time
from pathlib import Path

import numpy as np
from PIL import Image

SLOTS = ("px", "nx", "py", "ny", "pz", "nz")

# GL cube-map direction r = A + sc * S + tc * T for each face (OpenGL spec, table 3.21 inverted).
_GL = {
    "px": ((1, 0, 0), (0, 0, -1), (0, -1, 0)),
    "nx": ((-1, 0, 0), (0, 0, 1), (0, -1, 0)),
    "py": ((0, 1, 0), (1, 0, 0), (0, 0, 1)),
    "ny": ((0, -1, 0), (1, 0, 0), (0, 0, -1)),
    "pz": ((0, 0, 1), (1, 0, 0), (0, -1, 0)),
    "nz": ((0, 0, -1), (-1, 0, 0), (0, -1, 0)),
}
_FLIP = np.array([-1.0, 1.0, 1.0])  # three.js samples a CubeTexture background at (-x, y, z)

CONVENTION = ("three.js CubeTextureLoader().load([px,nx,py,ny,pz,nz]) as scene.background, camera at the "
              "node, no backgroundRotation: upright, unmirrored, twin world axes. three mirrors x for cube "
              "backgrounds, so px shows world -x, nx world +x, py up (+y, top edge toward -z), ny down "
              "(top edge toward +z), pz world +z (image right = world -x), nz world -z (image right = +x). "
              "Slot s, column i, row j (row 0 = jpg top): sc=2(i+.5)/N-1, tc=2(j+.5)/N-1, r = GL cube "
              "direction(s, sc, tc), world dir = (-r.x, r.y, r.z).")


def face_axes(slot: str):
    """World-space forward a, and the directions sc (image right) and tc (image down) add, for a slot.
    A pixel's (unnormalised) world direction is a + sc * right + tc * down."""
    A, S, T = (np.array(v, float) * _FLIP for v in _GL[slot])
    return A, S, T


@functools.lru_cache(maxsize=32)
def face_dirs(slot: str, n: int) -> np.ndarray:
    """Unit world directions of an n x n face's pixel centres, row-major (row 0 = image top). Cached:
    don't modify the result."""
    a, r, d = face_axes(slot)
    s = (np.arange(n) + 0.5) / n * 2 - 1
    sc, tc = np.meshgrid(s, s)  # sc varies along columns, tc along rows
    v = a + sc[..., None] * r + tc[..., None] * d
    v = (v / np.linalg.norm(v, axis=-1, keepdims=True)).reshape(-1, 3).astype(np.float32)
    v.flags.writeable = False
    return v


def raster(P, F, o, M, fx, fy, cx, cy, W, H, near=0.02, chunk=6_000_000):
    """Z-buffer of triangles (P, F) seen by a pinhole camera at `o` whose world axes are M's columns
    (x right, y up, looking along -z, as Frame.project). Pixel (i, j) samples screen point (i+.5, j+.5).
    Returns (depth along the view axis, inf where empty; triangle id, -1 where empty), both H*W."""
    c = (P - o) @ M
    z = -c[:, 2]
    zf = z[F]
    ok = (zf[:, 0] > near) & (zf[:, 1] > near) & (zf[:, 2] > near)
    zs = np.maximum(z, near)
    sx, sy = cx + fx * c[:, 0] / zs, cy - fy * c[:, 1] / zs
    X, Y = sx[F], sy[F]
    lo3, hi3 = lambda q: np.minimum(np.minimum(q[:, 0], q[:, 1]), q[:, 2]), lambda q: np.maximum(np.maximum(q[:, 0], q[:, 1]), q[:, 2])
    x0 = np.ceil(lo3(X) - 0.5)
    x1 = np.floor(hi3(X) - 0.5)
    y0 = np.ceil(lo3(Y) - 0.5)
    y1 = np.floor(hi3(Y) - 0.5)
    ok &= (x1 >= 0) & (y1 >= 0) & (x0 <= W - 1) & (y0 <= H - 1)
    x0, y0 = np.clip(x0, 0, W - 1), np.clip(y0, 0, H - 1)
    x1, y1 = np.clip(x1, 0, W - 1), np.clip(y1, 0, H - 1)
    ok &= (x1 >= x0) & (y1 >= y0)
    T = np.nonzero(ok)[0]
    zb = np.full(W * H, np.inf)
    tid = np.full(W * H, -1, np.int64)
    if len(T) == 0:
        return zb, tid
    X, Y, Z = X[T], Y[T], zf[T]
    x0, y0 = x0[T].astype(np.int64), y0[T].astype(np.int64)
    bw = x1[T].astype(np.int64) - x0 + 1
    nc = bw * (y1[T].astype(np.int64) - y0 + 1)
    ax, ay, bx, by, qx, qy = X[:, 0], Y[:, 0], X[:, 1], Y[:, 1], X[:, 2], Y[:, 2]
    area = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
    good = np.abs(area) > 1e-12
    inv_area = np.where(good, 1.0 / np.where(good, area, 1.0), 0.0)
    iz = 1.0 / Z
    ends = np.cumsum(nc)
    start = 0
    while start < len(T):
        stop = int(np.searchsorted(ends, (ends[start - 1] if start else 0) + chunk, side="right"))
        stop = max(stop, start + 1)
        sel = np.arange(start, stop)
        n = nc[sel]
        t = np.repeat(sel, n)
        off = np.arange(int(n.sum())) - np.repeat(np.cumsum(n) - n, n)
        px = x0[t] + off % bw[t]
        py = y0[t] + off // bw[t]
        ux, uy = px + 0.5, py + 0.5
        w0 = ((qx[t] - bx[t]) * (uy - by[t]) - (qy[t] - by[t]) * (ux - bx[t])) * inv_area[t]
        w1 = ((ax[t] - qx[t]) * (uy - qy[t]) - (ay[t] - qy[t]) * (ux - qx[t])) * inv_area[t]
        w2 = 1 - w0 - w1
        e = -1e-6
        ins = (w0 >= e) & (w1 >= e) & (w2 >= e) & good[t]
        t, px, py = t[ins], px[ins], py[ins]
        d = 1.0 / (w0[ins] * iz[t, 0] + w1[ins] * iz[t, 1] + w2[ins] * iz[t, 2])
        pix = py * W + px
        np.minimum.at(zb, pix, d)
        win = d <= zb[pix]
        tid[pix[win]] = T[t[win]]
        start = stop
    return zb, tid


def _planes(room):
    """RoomPlan's surfaces as (normal, offset, kind, extra) for the fallback depth."""
    out = [(np.array([0.0, 1.0, 0.0]), room.floor_y, "floor", None),
           (np.array([0.0, -1.0, 0.0]), -room.ceiling_y, "ceiling", None)]
    for w in room.walls:
        out.append((w["z"], float(w["c"] @ w["z"]), "wall", w))
    return out


def plane_hits(o, D, room):
    """For rays (o, D): the nearest RoomPlan wall, floor or ceiling (walls within their extent, a
    little grown). Returns (t, normal) with t = 8 m and normal = -D where nothing is hit."""
    t = np.full(len(D), np.inf)
    nrm = -D.copy()
    for n, k, kind, w in _planes(room):
        dn = D @ n
        with np.errstate(divide="ignore", invalid="ignore"):
            tt = (k - o @ n) / dn
        good = np.abs(dn) > 1e-6
        tt = np.where(good & (tt > 0.02), tt, np.inf)
        if w is not None:
            h = o + D * np.where(np.isfinite(tt), tt, 0)[:, None]
            d = h - w["c"]
            inside = (np.abs(d @ w["x"]) < w["w"] / 2 + 0.3) & (np.abs(d[:, 1]) < w["h"] / 2 + 0.3)
            tt = np.where(inside, tt, np.inf)
        m = tt < t
        t[m] = tt[m]
        nrm[m] = n
    miss = ~np.isfinite(t)
    t[miss] = 8.0
    return t, nrm


class DepthCube:
    """Depth (Euclidean distance) and the plane hit per pixel, for the six faces, at `n` px."""

    def __init__(self, o, P, F, room, n: int):
        self.o, self.n = np.asarray(o, float), n
        A, B, C = P[F[:, 0]], P[F[:, 1]], P[F[:, 2]]
        tn = np.cross(B - A, C - A)
        tn /= np.linalg.norm(tn, axis=1, keepdims=True) + 1e-12
        self.faces = {}
        hit = 0
        for s in SLOTS:
            a, r, d = face_axes(s)
            M = np.column_stack([r, -d, -a])
            zb, tid = raster(P, F, self.o, M, n / 2, n / 2, n / 2, n / 2, n, n)
            D = face_dirs(s, n)
            cosa = D @ a
            dist = zb / cosa
            nrm = np.where((tid >= 0)[:, None], tn[np.maximum(tid, 0)], 0.0)
            koff = np.where(tid >= 0, (nrm * A[np.maximum(tid, 0)]).sum(1), 0.0)
            miss = tid < 0
            if miss.any():
                pt, pn = plane_hits(self.o, D[miss], room)
                dist[miss] = pt
                nrm[miss] = pn
                koff[miss] = (pn * (self.o + D[miss] * pt[:, None])).sum(1)
            hit += int((~miss).sum())
            self.faces[s] = dict(dist=dist, nrm=nrm, k=koff, mesh=~miss)
        self.mesh_fraction = hit / (6 * n * n)

    def lookup(self, d):
        """Distance along unit direction d (nearest depth pixel)."""
        d = np.asarray(d, float)
        best = max(SLOTS, key=lambda s: d @ face_axes(s)[0])
        a, r, dn = face_axes(best)
        sc, tc = (d @ r) / (d @ a), (d @ dn) / (d @ a)
        i = int(np.clip((sc + 1) / 2 * self.n, 0, self.n - 1))
        j = int(np.clip((tc + 1) / 2 * self.n, 0, self.n - 1))
        return float(self.faces[best]["dist"][j * self.n + i])

    def full(self, s, N):
        """Hits and normals for an N x N face (N a multiple of n): each pixel's own ray meets the
        plane its depth pixel hit (falling back to that pixel's distance when the plane is grazing)."""
        f = self.faces[s]
        k = N // self.n
        idx = np.arange(N) // k
        lo = (idx[:, None] * self.n + idx[None, :]).reshape(-1)
        D = face_dirs(s, N)
        nrm = f["nrm"].astype(np.float32)[lo]
        koff = (f["k"] - f["nrm"] @ self.o).astype(np.float32)[lo]
        dist = f["dist"].astype(np.float32)[lo]
        dn = np.einsum("ij,ij->i", D, nrm)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = koff / dn
        bad = ~np.isfinite(t) | (t <= 0.02) | (np.abs(dn) < 0.05) | (t > dist * 1.6 + 0.05) | (t < dist / 1.6 - 0.05)
        t = np.where(bad, dist, t)
        X = self.o.astype(np.float32) + D * t[:, None]
        nrm = np.where((dn > 0)[:, None], -nrm, nrm)  # toward the node
        return D, X, nrm, t


def _up2(x: np.ndarray) -> np.ndarray:
    """Bilinear 2x upsample of an (h, w, c) array."""
    def ax(a, axis):
        p = np.concatenate([np.take(a, [0], axis), a, np.take(a, [-1], axis)], axis)
        n = a.shape[axis]
        prev, cur, nxt = (np.take(p, range(i, i + n), axis) for i in (0, 1, 2))
        even, odd = 0.75 * cur + 0.25 * prev, 0.75 * cur + 0.25 * nxt
        out = np.stack([even, odd], axis + 1)
        shape = list(a.shape)
        shape[axis] *= 2
        return out.reshape(shape)
    return ax(ax(x, 0), 1)


def fill_holes(faces: dict, weights: dict, default=(160.0, 160.0, 160.0)) -> dict:
    """Pull-push: every pixel with weight < 1 takes a smooth average of its seen neighbours, coarser
    and coarser until something is found; a face no frame saw at all takes the cube's mean colour."""
    pyr = {}
    for s, img in faces.items():
        w = weights[s].astype(np.float32)
        c, a = img * w[..., None], w
        lv = [(c, a)]
        while c.shape[0] > 1 and c.shape[0] % 2 == 0:
            h = c.shape[0] // 2
            c = c[0::2, 0::2] + c[1::2, 0::2] + c[0::2, 1::2] + c[1::2, 1::2]
            a = a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2]
            lv.append((c, a))
        pyr[s] = lv
    tot_c = sum(lv[-1][0].reshape(-1, 3).sum(0) for lv in pyr.values())
    tot_a = sum(lv[-1][1].sum() for lv in pyr.values())
    mean = tot_c / tot_a if tot_a > 0 else np.array(default, np.float32)
    out = {}
    for s, lv in pyr.items():
        c, a = lv[-1]
        col = np.where((a > 0)[..., None], c / np.maximum(a, 1e-9)[..., None], mean)
        for c, a in reversed(lv[:-1]):
            up = _up2(col)  # each level is exactly half the one below it
            alpha = np.clip(a, 0, 1)[..., None]
            known = c / np.maximum(a, 1e-9)[..., None]
            col = np.where(alpha > 0, known * alpha + up * (1 - alpha), up)
        out[s] = col
    return out


def _sharpness(f) -> float:
    if getattr(f, "_sharp", None) is None:
        f._sharp = f.sharpness()
    return f._sharp


def _fwd(f):
    v = -f.pose[:3, 2]
    return np.array([v[0], 0.0, v[2]]) / (math.hypot(v[0], v[2]) + 1e-9)


def select_nodes(frames: list, room, spacing: float = 1.2, max_nodes: int = 8, radius: float = 0.75) -> list[dict]:
    """Standing spots: frames carrying an int `stop` id first (one node per id), then greedily the frame
    positions where the most sharp frames stand within `radius` with the widest spread of headings,
    at least `spacing` apart. Each node: position (the median of its frames), and its frame indices."""
    if not frames:
        return []
    pos = np.array([f.pos for f in frames])
    sharp = np.array([_sharpness(f) for f in frames])
    rel = np.clip(sharp / (np.median(sharp) + 1e-6), 0.2, 1.5)
    heading = np.array([math.atan2(_fwd(f)[2], _fwd(f)[0]) for f in frames])
    hbin = ((heading + math.pi) / (2 * math.pi) * 8).astype(int) % 8
    xz = pos[:, [0, 2]]
    dist = np.linalg.norm(xz[:, None] - xz[None], axis=2)
    nodes = []
    stops = {}
    for i, f in enumerate(frames):
        s = f.k.get("stop")
        if isinstance(s, (int, np.integer)) and not isinstance(s, bool):
            stops.setdefault(int(s), []).append(i)
    for s in sorted(stops)[:max_nodes]:
        idx = stops[s]
        nodes.append(dict(position=np.median(pos[idx], 0), frames=idx, stop=s))
    free = np.array([not isinstance(f.k.get("stop"), (int, np.integer)) or isinstance(f.k.get("stop"), bool) for f in frames])
    score = np.zeros(len(frames))
    for i in range(len(frames)):
        near = (dist[i] < radius) & free
        cover = len(set(hbin[near].tolist())) / 8
        score[i] = rel[near].sum() * (0.25 + cover)
    inside = room.inside(xz, margin=0.0) if room is not None else np.ones(len(frames), bool)
    cand = free & inside
    if not cand.any() and not nodes:
        cand = free.copy()
    for n in nodes:
        cand &= np.linalg.norm(xz - n["position"][[0, 2]], axis=1) >= spacing
    while cand.any() and len(nodes) < max_nodes:
        i = int(np.argmax(np.where(cand, score, -1)))
        members = np.nonzero(free & (dist[i] < spacing / 2))[0].tolist()
        if nodes and (len(members) < 3 or score[i] < 1.0):
            break
        p = np.median(pos[members], 0)
        if any(np.linalg.norm(p[[0, 2]] - n["position"][[0, 2]]) < 0.9 * spacing for n in nodes):
            p = np.array([pos[i, 0], p[1], pos[i, 2]])  # the cluster's middle drifted toward a node taken
        nodes.append(dict(position=p, frames=members, stop=None))
        cand &= np.linalg.norm(xz - p[[0, 2]], axis=1) >= spacing
    return nodes


def _wall_blocks(a, b, room) -> bool:
    """Does the segment a-b cross a RoomPlan wall away from its doors and openings?"""
    for w in room.walls:
        da, db = (a - w["c"]) @ w["z"], (b - w["c"]) @ w["z"]
        if da * db >= 0 or abs(da - db) < 1e-9:
            continue
        p = a + (b - a) * (da / (da - db))
        d = p - w["c"]
        if abs(d @ w["x"]) > w["w"] / 2 or abs(d[1]) > w["h"] / 2:
            continue
        through = False
        for h in room.holes:
            if h["kind"] == "window":
                continue
            e = p - h["c"]
            if abs(e @ h["z"]) < 0.3 and abs(e @ h["x"]) < h["w"] / 2 and abs(e[1]) < h["h"] / 2:
                through = True
        if not through:
            return True
    return False


class _View:
    """A frame prepared for fast float32 lookups: projection, z-buffer visibility, bilinear colour."""

    def __init__(self, f, zbuf, rel: float):
        self.f, self.rel = f, rel
        self.R = f.inv[:3, :3].astype(np.float32)
        self.t = f.inv[:3, 3].astype(np.float32)
        self.pos = f.pos.astype(np.float32)
        k = f.k
        self.fx, self.fy, self.cx, self.cy = (np.float32(k[q]) for q in ("fx", "fy", "cx", "cy"))
        self.W, self.H = int(k["width"]), int(k["height"])
        self.zb, self.ds, self.Wd, self.Hd = zbuf
        self.zb = self.zb.astype(np.float32)
        self.gain = np.asarray(f.gain, np.float32)
        self.u8 = None

    def colours(self):
        if self.u8 is None:
            self.u8 = np.clip(self.f.img, 0, 255).astype(np.uint8).reshape(-1, 3)
        return self.u8

    def project(self, X, depth=False):
        c = X @ self.R.T + self.t
        d = -c[:, 2]
        dd = np.maximum(d, 1e-3)
        x = self.cx + self.fx * c[:, 0] / dd
        y = self.cy - self.fy * c[:, 1] / dd
        return (x, y, d) if depth else (x, y)

    def score(self, X, nrm, D, near_node: float):
        """Per point: a score (0 where unseen) and the pixel it lands on."""
        x, y, d = self.project(X, True)
        ok = (d > 0.1) & (x > 1) & (y > 1) & (x < self.W - 2) & (y < self.H - 2)
        zi = np.clip((y / self.ds).astype(np.int32), 0, self.Hd - 1) * self.Wd + np.clip((x / self.ds).astype(np.int32), 0, self.Wd - 1)
        ok &= d <= self.zb[zi] + 0.05 + 0.03 * d
        toc = self.pos - X
        dist = np.sqrt(np.einsum("ij,ij->i", toc, toc)) + 1e-6
        facing = np.einsum("ij,ij->i", toc, nrm) / dist
        same = np.clip(-np.einsum("ij,ij->i", toc, D) / dist, 0, 1)  # 1: the frame looks along the node's ray
        sc = self.rel * (0.15 + np.clip(facing, 0, 1)) * near_node * same ** 4 / np.maximum(dist, 0.4)
        return np.where(ok & (facing > 0.08), sc, 0).astype(np.float32), x, y

    def sample(self, x, y):
        flat = self.colours()
        H, W = self.f.img.shape[:2]
        x, y = np.clip(x, 0, W - 1.001), np.clip(y, 0, H - 1.001)
        x0, y0 = x.astype(np.int32), y.astype(np.int32)
        fx, fy = (x - x0)[:, None], (y - y0)[:, None]
        i = y0 * W + x0
        top = flat[i] * (1 - fx) + flat[i + 1] * fx
        bot = flat[i + W] * (1 - fx) + flat[i + W + 1] * fx  # uint8 * float32 -> float32
        return (top * (1 - fy) + bot * fy) * self.gain


def render_node(o, cube: DepthCube, views: list, N: int, grid: int = 64, per_cell: int = 2, choice_px: int = 512):
    """Colour the six N x N faces of one node. Per coarse cell the `per_cell` best frames are kept;
    each pixel then scores those exactly and blends the best two. Returns (faces {slot: float image},
    seen {slot: mask}, frame indices used)."""
    near_node = [float(np.exp(-np.linalg.norm(v.f.pos - o) / 1.0)) for v in views]
    Nc = min(N, max(cube.n, choice_px))
    while N % Nc:
        Nc -= 1
    up = N // Nc
    g = min(grid, Nc)
    while Nc % g:
        g -= 1
    step = Nc // g

    def one(s):
        used = set()
        D, X, nrm, _ = cube.full(s, Nc)
        mid = np.arange(g) * step + step // 2
        cidx = (mid[:, None] * Nc + mid[None, :]).reshape(-1)
        Xc, nc, Dc = X[cidx], nrm[cidx], D[cidx]
        cand, S = [], []
        for vi, v in enumerate(views):
            if near_node[vi] < 0.02:
                continue
            sc, _, _ = v.score(Xc, nc, Dc, near_node[vi])
            if sc.max() > 0:
                cand.append(vi)
                S.append(sc)
        M = Nc * Nc
        s1, s2 = np.zeros(M, np.float32), np.zeros(M, np.float32)
        f1, f2 = np.full(M, -1, np.int32), np.full(M, -1, np.int32)
        if cand:
            S = np.stack(S)
            top = np.argsort(-S, axis=0)[:per_cell]
            valid = np.take_along_axis(S, top, 0) > 0
            ar = np.arange(step)
            for j, vi in enumerate(cand):
                cells = np.nonzero(((top == j) & valid).any(0))[0]
                if not len(cells):
                    continue
                cy, cx = cells // g, cells % g
                pix = ((cy[:, None] * step + ar)[:, :, None] * Nc + (cx[:, None] * step + ar)[:, None, :]).reshape(-1)
                sp, _, _ = views[vi].score(X[pix], nrm[pix], D[pix], near_node[vi])
                ok = sp > 0
                if not ok.any():
                    continue
                pix, sp = pix[ok], sp[ok]
                b1 = sp > s1[pix]
                b2 = ~b1 & (sp > s2[pix])
                p1, p2 = pix[b1], pix[b2]
                s2[p1], f2[p1] = s1[p1], f1[p1]
                s1[p1], f1[p1] = sp[b1], vi
                s2[p2], f2[p2] = sp[b2], vi
        # Blend the best two (the second only when nearly as good), sampling just those.
        # The choice was made at Nc px; colour at N px (each choice pixel covers up x up).
        w1 = s1 ** 4
        w2 = np.where(s2 >= 0.6 * s1, s2, 0) ** 4
        f2 = np.where(w2 > 0, f2, -1)
        if up > 1:
            lo = (np.arange(N) // up)
            lo = (lo[:, None] * Nc + lo[None, :]).reshape(-1)
            w1, w2, f1, f2, s1 = w1[lo], w2[lo], f1[lo], f2[lo], s1[lo]
        Xf = cube.full(s, N)[1] if up > 1 else X
        img = np.zeros((N * N, 3), np.float32)
        for fs, w in ((f1, w1), (f2, w2)):
            order = np.argsort(fs, kind="stable")
            fsorted = fs[order]
            bounds = np.searchsorted(fsorted, np.arange(len(views) + 1))
            for vi in range(len(views)):
                a, b = bounds[vi], bounds[vi + 1]
                if a == b:
                    continue
                pix = order[a:b]
                x, y = views[vi].project(Xf[pix])
                img[pix] += views[vi].sample(x, y) * w[pix, None]
                used.add(vi)
        img /= np.maximum(w1 + w2, 1e-30)[:, None]
        return img.reshape(N, N, 3), (s1 > 0).astype(np.float32).reshape(N, N), used

    res = {s: one(s) for s in SLOTS}
    faces = {s: r[0] for s, r in res.items()}
    seen = {s: r[1] for s, r in res.items()}
    used = set().union(*(r[2] for r in res.values()))
    return faces, seen, used


def build_nodes(out: Path, P, F, frames: list, room, face_px: int = 1024, depth_px: int = 256,
                max_nodes: int = 8, spacing: float = 1.2, quality: int = 82) -> tuple[list, dict]:
    """Pick the nodes, render their cube faces to out/img/nodes/<id>_<slot>.jpg. Returns the nodes for
    twin.json and a processing summary."""
    t0 = time.time()
    out = Path(out)
    folder = out / "img" / "nodes"
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("*.jpg"):
        old.unlink()
    summary = dict(count=0, face_px=face_px, convention=CONVENTION)
    if not frames or len(F) == 0:
        summary["reason"] = "no frames or no mesh"
        return [], summary
    depth_px = min(depth_px, face_px)
    while face_px % depth_px:
        depth_px //= 2
    picked = select_nodes(frames, room, spacing, max_nodes)
    sharp = np.array([_sharpness(f) for f in frames])
    rel = np.clip(sharp / (np.median(sharp) + 1e-6), 0.3, 1.5)
    # A z-buffer per frame (about 240 px wide), for visibility.
    views = []
    for fi, f in enumerate(frames):
        ds = max(1, round(f.k["width"] / 240))
        W, H = f.k["width"] // ds, f.k["height"] // ds
        zb, _ = raster(P, F, f.pos, f.pose[:3, :3], f.k["fx"] / ds, f.k["fy"] / ds, f.k["cx"] / ds, f.k["cy"] / ds, W, H)
        views.append(_View(f, (zb, ds, W, H), float(rel[fi])))
    nodes, cubes, total_bytes = [], [], 0
    for ni, nd in enumerate(picked):
        nid = f"N{ni + 1}"
        o = np.asarray(nd["position"], float)
        cube = DepthCube(o, P, F, room, depth_px)
        faces, seen, used = render_node(o, cube, views, face_px)
        cov = float(np.mean([seen[s].mean() for s in SLOTS]))
        filled = fill_holes(faces, seen)
        paths = {}
        for s in SLOTS:
            rel_path = f"img/nodes/{nid}_{s}.jpg"
            im = np.clip(filled[s], 1, 255).astype(np.uint8)  # never black
            Image.fromarray(im).save(out / rel_path, quality=quality, optimize=True)
            total_bytes += (out / rel_path).stat().st_size
            paths[s] = rel_path
        nodes.append(dict(id=nid, position=[round(float(v), 3) for v in o],
                          height_above_floor=round(float(o[1] - room.floor_y), 3), faces=paths,
                          neighbors=[], coverage=round(cov, 3), frames_used=len(used),
                          mesh_depth=round(cube.mesh_fraction, 3), **({"stop": nd["stop"]} if nd["stop"] is not None else {})))
        cubes.append(cube)
    for i, a in enumerate(nodes):
        pa = np.array(a["position"])
        for j, b in enumerate(nodes):
            if i == j:
                continue
            pb = np.array(b["position"])
            d = float(np.linalg.norm(pb - pa))
            u = (pb - pa) / max(d, 1e-9)
            vis = cubes[i].lookup(u) >= d - 0.25 and not _wall_blocks(pa, pb, room)
            a["neighbors"].append(dict(id=b["id"], distance_m=round(d, 2), visible=bool(vis)))
        a["neighbors"].sort(key=lambda q: q["distance_m"])
    summary.update(count=len(nodes), depth_px=depth_px, jpg_quality=quality, bytes=total_bytes,
                   coverage=[n["coverage"] for n in nodes], seconds=round(time.time() - t0, 1),
                   from_stops=sum(1 for n in picked if n["stop"] is not None))
    return nodes, summary

"""360 view nodes for the twin: standing spots picked from the keyframes, each with a cube panorama
re-rendered from the textured room, so the page can offer a Matterport-style photo-hop tour.

Per node:
  - a depth cube: the cleaned room mesh rasterised from the node (perspective-correct z-buffer, one
    pinhole camera per face), with RoomPlan's walls, floor and ceiling as planes behind it, so a hole
    in the mesh still gets a depth. Each depth pixel keeps the plane of what it hit, so the full-size
    face intersects every pixel's own ray with that plane (sharp, no depth stair-steps); whatever lies
    within a few cm of RoomPlan's floor or ceiling is put exactly on that plane (the mesh is noisy
    there). Each depth pixel also gets a risk (0..1) that its depth is wrong: depth steps (object
    edges, doorways), no mesh, near surfaces;
  - colour (render_node): each 3D hit projected into the frames that see it (a z-buffer per frame;
    the operator's own feet and legs are kept out), scored by sharpness x how squarely the frame
    faces the surface x closeness / distance x how nearly it looks along the node's ray x how near
    the node it stood, the last two much stronger where the depth is risky, fading to 0 at the image
    border. Per pixel the best frames are blended in two bands: low frequencies with broad, feathered
    weights (a change of frame is a gentle gradient, not an exposure step), detail with sharply
    peaked weights (essentially one frame, so a misregistered frame can't double an edge into a
    ghost); every frame's weight feathers to 0 at its visibility and image edges. A per-node,
    per-frame RGB gain (least squares on the overlaps) evens out exposure first;
  - unseen floor is filled with texture copied from seen floor (fill_texture), everything else by
    pull-push (averages pushed in from the neighbours), never black. `coverage` is the fraction of
    cube pixels coloured from a real frame.
processing.nodes.quality reports per node: seam_ratio (luminance step energy where the main source
frame changes on smooth depth, over the face average: 1 = invisible), ghost_risk (share of seen
pixels where two blended frames disagree on the local edges), blended (share with a second frame
>= 20 %), depth_risk (mean depth risk).

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
import os
import time
from concurrent.futures import ThreadPoolExecutor
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
        self.floor_y = float(room.floor_y) if room is not None else None
        self.ceiling_y = float(room.ceiling_y) if room is not None else None
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
            self.faces[s] = dict(dist=dist, nrm=nrm, k=koff, mesh=~miss, **self._risk(dist, ~miss, D))
        self.mesh_fraction = hit / (6 * n * n)

    def _risk(self, dist, mesh, D):
        """Per depth pixel, 0..1: how likely the depth is wrong enough to misplace a frame's colour
        (parallax ghosts): next to a depth step (object edges, doorways), where the mesh had nothing
        (a RoomPlan wall stands in), and on near surfaces, where a few cm of error move a lot."""
        n = self.n
        dd = dist.reshape(n, n)
        win = np.lib.stride_tricks.sliding_window_view(np.pad(dd, 2, mode="edge"), (5, 5))
        jump = (win.max((-1, -2)) - win.min((-1, -2))) / np.maximum(dd, 0.1)
        edge = np.clip((jump - 0.06) / 0.1, 0, 1)
        y = self.o[1] + D[:, 1] * dist
        flat = np.zeros(len(dist), bool)
        if self.floor_y is not None:
            flat = (np.abs(y - self.floor_y) < 0.08) | (np.abs(y - self.ceiling_y) < 0.08)
        nm = np.where(~mesh & ~flat, 0.5, 0.0).reshape(n, n)
        near = (np.clip((1.2 - dd) / 0.8, 0, 1) * 0.6) * ~flat.reshape(n, n)
        r = np.maximum(np.maximum(edge, nm), near)
        return dict(risk=np.clip(_box(r.astype(np.float32), 1, edge=True), 0, 1), flat=edge < 0.05)

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
        nrm = np.where((dn > 0)[:, None], -nrm, nrm)  # toward the node
        cls = np.zeros(len(t), np.int8)  # 0 other, 1 floor, 2 ceiling
        if self.floor_y is not None:
            # Floor and ceiling: RoomPlan's planes are flat and exact where the mesh is noisy (and
            # has holes), so whatever lies within a few cm of them is taken onto the plane.
            oy, dy = np.float32(self.o[1]), D[:, 1]
            y = oy + dy * t
            with np.errstate(divide="ignore", invalid="ignore"):
                for c, py, sgn in ((1, self.floor_y, -1), (2, self.ceiling_y, 1)):
                    tp = (np.float32(py) - oy) / dy
                    near = (y < py + 0.08) if c == 1 else (np.abs(y - py) < 0.08)
                    m = (dy * sgn > 0.05) & near & np.isfinite(tp) & (tp > 0.02)
                    t = np.where(m, tp, t)
                    nrm[m] = (0.0, -float(sgn), 0.0)
                    cls[m] = c
        X = self.o.astype(np.float32) + D * t[:, None]
        return D, X, nrm, t, cls


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
    # Stops closer than half the spacing are one spot: sitting or standing still while raising,
    # lowering or swinging the phone round at arm's length ends and restarts stops in the app.
    for s in sorted(stops):
        idx = stops[s]
        p = np.median(pos[idx], 0)
        near = [n for n in nodes if np.linalg.norm(n["position"][[0, 2]] - p[[0, 2]]) < spacing / 2]
        if near:
            n = near[0]
            n["frames"] = n["frames"] + idx
            n["position"] = np.median(pos[n["frames"]], 0)
        elif len(nodes) < max_nodes:
            nodes.append(dict(position=p, frames=idx, stop=s))
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
        self.border = np.float32(0.06 * min(self.W, self.H))
        # The person holding the phone stands behind it: a frame that looks down sees their feet and
        # legs (never in the mesh) on the floor there. Where the frame looks too steeply to tell which
        # way is behind, nothing is assumed.
        v = -f.pose[:3, 2]
        h = math.hypot(v[0], v[2])
        self.body = None
        if h > 0.25:
            self.body = (np.array([f.pos[0] - 0.32 * v[0] / h, f.pos[2] - 0.32 * v[2] / h], np.float32),
                         np.float32(f.pos[1] - 0.15))
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

    def score(self, X, nrm, D, dnode: float, risk):
        """Per point: a score (0 where unseen) and the pixel it lands on. The score prefers sharp
        frames that see the surface squarely, from close, looking along the node's own ray, taken
        near the node; where the depth is doubtful (`risk`), the last two count much more (less
        parallax, so a wrong depth misplaces less). It fades to ~0 toward the image border."""
        x, y, d = self.project(X, True)
        ok = (d > 0.1) & (x > 1) & (y > 1) & (x < self.W - 2) & (y < self.H - 2)
        zi = np.clip((y / self.ds).astype(np.int32), 0, self.Hd - 1) * self.Wd + np.clip((x / self.ds).astype(np.int32), 0, self.Wd - 1)
        ok &= d <= self.zb[zi] + 0.05 + 0.03 * d
        if self.body is not None:
            (bx, bz), top = self.body
            ok &= ~(((X[:, 0] - bx) ** 2 + (X[:, 2] - bz) ** 2 < 0.08) & (X[:, 1] < top))
        toc = self.pos - X
        dist = np.sqrt(np.einsum("ij,ij->i", toc, toc)) + 1e-6
        facing = np.einsum("ij,ij->i", toc, nrm) / dist
        same = np.clip(-np.einsum("ij,ij->i", toc, D) / dist, 1e-6, 1)  # 1: the frame looks along the node's ray
        edge = np.clip(np.minimum(np.minimum(x, self.W - x), np.minimum(y, self.H - y)) / self.border, 0, 1)
        k = 4 + 20 * risk
        sc = (self.rel * (0.15 + np.clip(facing, 0, 1)) / np.maximum(dist, 0.4)
              * np.exp(k * np.log(same) - dnode * (1 + 1.5 * risk)) * (0.002 + edge * edge * (3 - 2 * edge)))
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


def _box(a, r: int, edge: bool = False) -> np.ndarray:
    """Mean over a (2r+1) x (2r+1) window along the first two axes, zero padded (or edge padded)."""
    a = np.asarray(a, np.float32)
    if r <= 0:
        return a
    for ax in (0, 1):
        n = a.shape[ax]
        pad = [(0, 0)] * a.ndim
        pad[ax] = (r + 1, r)
        c = np.cumsum(np.pad(a, pad, mode="edge" if edge else "constant"), axis=ax, dtype=np.float64)
        c = np.moveaxis(c, ax, 0)
        a = np.moveaxis(((c[2 * r + 1:] - c[:n]) / (2 * r + 1)).astype(np.float32), 0, ax)
    return a


def _resize(a, n: int) -> np.ndarray:
    """Bilinear resize of an (h, h, ...) array to (n, n, ...), pixel centres aligned."""
    h = a.shape[0]
    if h == n:
        return a
    src = (np.arange(n) + 0.5) * h / n - 0.5
    i0 = np.floor(src)
    w = (src - i0).astype(np.float32)
    i0 = i0.astype(np.int64)
    i1, i0 = np.clip(i0 + 1, 0, h - 1), np.clip(i0, 0, h - 1)
    sh = (-1,) + (1,) * (a.ndim - 1)
    a = a[i0] * (1 - w).reshape(sh) + a[i1] * w.reshape(sh)
    sh = (1, -1) + (1,) * (a.ndim - 2)
    return a[:, i0] * (1 - w).reshape(sh) + a[:, i1] * w.reshape(sh)


def _floor_like(img: np.ndarray, floor: np.ndarray) -> np.ndarray:
    """Which floor pixels look like the floor around them, judged over a window (N/16 px) wide enough
    that a tile or plank pattern averages out: local mean colour and detail (luminance spread) near
    the seen floor's typical values. Depth alone calls anything standing on the floor and missed by
    the mesh (a table's foot, a thin pole, the scanner's own shoes) floor, and copying it into the
    holes repeats it across the face."""
    if floor.sum() < 64:
        return floor.copy()
    r = max(2, img.shape[0] // 16)
    w = _box(floor.astype(np.float32), r)
    wd = np.maximum(w, 1e-6)
    m = _box(img * floor[..., None], r) / wd[..., None]
    Y = img @ np.array([0.299, 0.587, 0.114], np.float32)
    sd = np.sqrt(np.maximum(_box(Y * Y * floor, r) / wd - (_box(Y * floor, r) / wd) ** 2, 0))
    good = floor & (w > 0.3)
    if good.sum() < 64:
        return floor.copy()
    med = np.median(m[good], 0)
    dc = np.linalg.norm(m - med, axis=-1)
    tol_c = max(3 * 1.4826 * float(np.median(dc[good])), 14.0)
    sm = float(np.median(sd[good]))
    tol_s = max(3 * 1.4826 * float(np.median(np.abs(sd[good] - sm))), 8.0)
    odd = floor & ~((dc <= tol_c) & (np.abs(sd - sm) <= tol_s))
    # Keep clear of anything odd: an object's pale parts pass the test, its dark parts don't.
    return floor & (_box(odd.astype(np.float32), r // 2) < 1e-3)


def fill_texture(img: np.ndarray, seen: np.ndarray, cls: np.ndarray, smooth: np.ndarray) -> np.ndarray:
    """Fill unseen pixels. Floor holes (the spot under the node nobody photographed, the floor behind
    furniture) get texture copied from seen floor, not a blur: block by block (N/32 px), the
    shortest shift (8 directions, lengths growing by 1.35x; a neighbouring block's shift first, so
    copies stay coherent) that lands on seen floor, with the copy's local mean swapped for the
    smooth fill's so the lighting stays continuous. Everything else takes `smooth` (pull-push):
    walls and ceilings are mostly plain, and copied edges there read as artefacts."""
    N = img.shape[0]
    out = np.where(seen[..., None], img, smooth)
    hole = ~seen & (cls == 1)
    # Sources well inside the seen floor: its rim is where frames disagree and skirting boards bleed.
    floor = seen & (cls == 1)
    src = _box(floor, max(1, N // 64)) > 0.999
    src &= _floor_like(img, floor)
    B = max(2, N // 32)
    if not hole.any() or not src.any() or N % B:
        return out
    base = _box(out, max(4, N // 32), edge=True)
    cands, L = [], float(B)
    while L < N:
        for k in range(8):
            t = (int(round(L * math.sin(k * math.pi / 4))), int(round(L * math.cos(k * math.pi / 4))))
            if t not in cands:
                cands.append(t)
        L *= 1.35
    nb = N // B
    chosen = {}
    blocks = hole.reshape(nb, B, nb, B).any((1, 3))
    for by, bx in zip(*np.nonzero(blocks)):
        ys, xs = np.nonzero(hole[by * B:(by + 1) * B, bx * B:(bx + 1) * B])
        ys, xs = ys + by * B, xs + bx * B
        sub = slice(None, None, max(1, len(ys) // 64))
        best = None
        for t in [chosen.get((by, bx - 1)), chosen.get((by - 1, bx))] + cands:
            if t is None:
                continue
            ty, tx = ys[sub] + t[0], xs[sub] + t[1]
            ok = (ty >= 0) & (ty < N) & (tx >= 0) & (tx < N)
            ok[ok] = src[ty[ok], tx[ok]]
            if ok.mean() >= 0.9:
                best = t
                break
        if best is None:
            continue
        chosen[(by, bx)] = best
        ty, tx = ys + best[0], xs + best[1]
        ok = (ty >= 0) & (ty < N) & (tx >= 0) & (tx < N)
        ok[ok] = src[ty[ok], tx[ok]]
        ys, xs, ty, tx = ys[ok], xs[ok], ty[ok], tx[ok]
        out[ys, xs] = img[ty, tx] - base[ty, tx] + base[ys, xs]
    return out


def _lookup(a, iy, ix, scale: int):
    """Bilinear lookup of an (h, w[, c]) grid at pixels (iy, ix) of a grid `scale` times finer."""
    h, w = a.shape[:2]
    fy = (iy + 0.5) / scale - 0.5
    fx = (ix + 0.5) / scale - 0.5
    y0 = np.clip(np.floor(fy), 0, h - 1).astype(np.int64)
    x0 = np.clip(np.floor(fx), 0, w - 1).astype(np.int64)
    y1, x1 = np.minimum(y0 + 1, h - 1), np.minimum(x0 + 1, w - 1)
    wy = np.clip(fy - y0, 0, 1).astype(np.float32)
    wx = np.clip(fx - x0, 0, 1).astype(np.float32)
    if a.ndim == 3:
        wy, wx = wy[:, None], wx[:, None]
    return (a[y0, x0] * (1 - wx) + a[y0, x1] * wx) * (1 - wy) + (a[y1, x0] * (1 - wx) + a[y1, x1] * wx) * wy


def _seam_stats(img, seen, label, smooth):
    """Mean squared luminance step across neighbouring pixels whose main source frame differs, and
    over all seen neighbours, both only where the depth is smooth (`smooth`; a change of frame at an
    object's edge is no seam). A visible seam makes the first much bigger than the second."""
    Y = img @ np.array([0.299, 0.587, 0.114], np.float32)
    e_seam = n_seam = e_all = n_all = 0.0
    for a, b in ((np.s_[:, 1:], np.s_[:, :-1]), (np.s_[1:, :], np.s_[:-1, :])):
        both = seen[a] & seen[b] & smooth[a] & smooth[b]
        g = (Y[a] - Y[b]) ** 2
        cut = both & (label[a] != label[b])
        e_seam += float(g[cut].sum())
        n_seam += float(cut.sum())
        e_all += float(g[both].sum())
        n_all += float(both.sum())
    return e_seam, n_seam, e_all, n_all


def render_node(o, cube: DepthCube, views: list, N: int, grid: int = 64, keep: int = 4, choice_px: int = 512,
                stats: dict | None = None, workers: int | None = None):
    """Colour the six N x N faces of one node.

    Per face, at the choice resolution Nc: each coarse cell keeps its `keep` best frames, and those
    frames are scored on every pixel near the cells (`_View.score`); the scores are smoothed within
    each frame's visible region (noisy mesh normals would make a patchwork) and turned into two
    sets of blending weights, both feathered to 0 at every border of a frame's visible region (its
    image edge, an occlusion edge):
      - detail weights, sharply peaked (score ratio to the power 10..30, steeper where the depth is
        doubtful), so fine detail comes from essentially one frame and misregistered frames can't
        double it into a ghost;
      - smooth weights (a broad feather, power 3..12), for the low frequencies, so a change of
        source frame shows as a gentle gradient, not an exposure step (two-band blending).
    The frames' exposure is matched once more for this node: a per-frame RGB gain solved in log
    space so overlapping frames agree (on top of the twin's own gains).
    Returns (faces {slot: float image}, seen {slot: mask}, classes {slot: 0/1 floor/2 ceiling},
    frame indices used)."""
    dnode = [float(np.linalg.norm(v.f.pos - o)) for v in views]
    Nc = min(N, max(cube.n, choice_px))
    while N % Nc:
        Nc -= 1
    g = min(grid, Nc)
    while Nc % g:
        g -= 1
    step = Nc // g
    up = N // Nc
    r_hi, r_lo = max(1, Nc // 128), max(2, Nc // 16)
    workers = workers or min(6, os.cpu_count() or 1)

    def pass1(s):
        """Which frames, their weights, and exposure comparisons between frames, for one face."""
        D, X, nrm, _, cls = cube.full(s, Nc)
        cls = cls.reshape(Nc, Nc)
        risk = _resize(cube.faces[s]["risk"], Nc).reshape(-1).astype(np.float32)
        mid = np.arange(g) * step + step // 2
        cidx = (mid[:, None] * Nc + mid[None, :]).reshape(-1)
        cand, S = [], []
        for vi, v in enumerate(views):
            if dnode[vi] > 3.9:
                continue
            sc = v.score(X[cidx], nrm[cidx], D[cidx], dnode[vi], risk[cidx])[0]
            if sc.max() > 0:
                cand.append(vi)
                S.append(sc)
        pick, maps = [], []
        if cand:
            S = np.stack(S)
            top = np.argsort(-S, axis=0)[:keep]
            valid = np.take_along_axis(S, top, 0) > 0
            for j, vi in enumerate(cand):
                cells = ((top == j) & valid).any(0).reshape(g, g)
                if not cells.any():
                    continue
                cells = _box(cells, 2) > 1e-3
                pix = np.nonzero(np.repeat(np.repeat(cells, step, 0), step, 1).reshape(-1))[0]
                sp = views[vi].score(X[pix], nrm[pix], D[pix], dnode[vi], risk[pix])[0]
                if not (sp > 0).any():
                    continue
                m = np.zeros(Nc * Nc, np.float32)
                m[pix] = sp
                pick.append(vi)
                maps.append(m.reshape(Nc, Nc))
        if not pick:
            return dict(pick=[], cls=cls, risk=risk), {}, {}
        k = len(pick)
        Sst = np.stack(maps, -1)  # Nc, Nc, k
        V = Sst > 0
        Vf = V.astype(np.float32)
        Sst = _box(Sst, 3) / np.maximum(_box(Vf, 3), 1e-6) * V
        lrel = np.log(np.maximum(Sst, 1e-30)) - np.log(np.maximum(Sst.max(-1, keepdims=True), 1e-30))
        r = risk.reshape(Nc, Nc, 1)
        fh = np.clip(2 * _box(Vf, r_hi, edge=True) - 1, 0, 1) * Vf
        fh = fh * fh * (3 - 2 * fh)
        fl = np.clip(2 * _box(Vf, r_lo, edge=True) - 1, 0, 1) * Vf
        fl = fl * fl * (3 - 2 * fl)
        wh = np.exp(lrel * (10 + 20 * r)) * (1e-3 + fh) * Vf
        wl = np.exp(lrel * (3 + 9 * r)) * (1e-3 + fl * (1 - r) + fh * r) * Vf
        wh /= np.maximum(wh.sum(-1, keepdims=True), 1e-30)
        wl /= np.maximum(wl.sum(-1, keepdims=True), 1e-30)
        # Slivers seen by some frame through a crack are dropped (left to the fill), so holes have
        # clean edges to continue texture from.
        sn = V.any(-1)
        r_o = max(1, Nc // 256)
        sn &= _box(_box(sn, r_o, edge=True) > 0.999, r_o, edge=True) > 1e-3
        share = {vi: float(wh[..., j].sum()) for j, vi in enumerate(pick)}
        st = dict(pick=pick, wh=wh, wl=wl, seen=sn, cls=cls, risk=risk)
        pairs = {}
        # Exposure: compare the frames on confident pixels they both see.
        ii = np.arange(Nc * Nc)
        samp = np.nonzero(((ii // Nc) % 4 == 0) & ((ii % Nc) % 4 == 0) & (V.reshape(-1, k).sum(1) >= 2) & (risk < 0.3))[0]
        if len(samp) >= 40 and k >= 2:
            Vs = V.reshape(-1, k)[samp]
            logc = np.full((len(samp), k, 3), np.nan, np.float32)
            for j, vi in enumerate(pick):
                sel = np.nonzero(Vs[:, j])[0]
                c = views[vi].sample(*views[vi].project(X[samp[sel]]))
                good = (c.max(1) < 250) & (c.min(1) > 6)
                logc[sel[good], j] = np.log(c[good])
            ok = ~np.isnan(logc[..., 0])
            for i in range(k):
                for j in range(i + 1, k):
                    both = ok[:, i] & ok[:, j]
                    n = int(both.sum())
                    if n >= 40:
                        pairs[(pick[i], pick[j])] = (np.median(logc[both, i] - logc[both, j], 0), n)
        return st, pairs, share

    with ThreadPoolExecutor(workers) as ex:
        res = dict(zip(SLOTS, ex.map(pass1, SLOTS)))
    state = {s: r[0] for s, r in res.items()}
    pairs, share = {}, {}
    for _, p, sh in res.values():
        for key, v in p.items():
            pairs.setdefault(key, []).append(v)
        for vi, v in sh.items():
            share[vi] = share.get(vi, 0.0) + v

    # Node-level exposure gains: least squares in log space, pulled gently toward no change.
    used_all = sorted({vi for st in state.values() for vi in st["pick"]})
    col = {vi: n for n, vi in enumerate(used_all)}
    gain = {vi: np.ones(3, np.float32) for vi in used_all}
    if pairs:
        rows, rhs = [], []
        for (i, j), obs in pairs.items():
            cnt = sum(c for _, c in obs)
            d = sum(dd * c for dd, c in obs) / cnt
            w = math.sqrt(min(cnt / 200, 25.0))
            row = np.zeros(len(used_all))
            row[col[i]], row[col[j]] = w, -w
            rows.append(row)
            rhs.append(-w * d)
        rows.extend(np.eye(len(used_all)) * 0.7)
        rhs.extend([np.zeros(3)] * len(used_all))
        sol = np.linalg.lstsq(np.array(rows), np.array(rhs), rcond=None)[0]
        # Anchored so the node's overall exposure stays put (weighted by how much each frame shows),
        # and lifting a frame is capped: brightening a dim frame to match a bright one blows out
        # white walls.
        wt = np.array([share.get(vi, 0.0) for vi in used_all]) + 1e-6
        sol -= (sol * wt[:, None]).sum(0) / wt.sum()
        for vi in used_all:
            gain[vi] = np.exp(np.clip(sol[col[vi]], -0.3, 0.12)).astype(np.float32)

    q = max(1, N // 128)
    while N % q:
        q -= 1
    L = N // q

    def pass2(s):
        """Colour at N, two bands: Σ smooth-weight x frame's low band + Σ detail-weight x the rest."""
        st = state[s]
        cls = st["cls"]
        cls = np.repeat(np.repeat(cls, up, 0), up, 1) if up > 1 else cls
        out = dict(cls=cls)
        if not st["pick"]:
            out.update(img=np.zeros((N, N, 3), np.float32), seen=np.zeros((N, N), bool), used=set())
            return out
        Xf = cube.full(s, N)[1]
        acc_l = np.zeros((N * N, 3), np.float32)
        acc_h = np.zeros((N * N, 3), np.float32)
        sum_l = np.zeros(N * N, np.float32)
        sum_h = np.zeros(N * N, np.float32)
        used = set()
        ar = np.arange(up)
        for j, vi in enumerate(st["pick"]):
            whj, wlj = st["wh"][..., j], st["wl"][..., j]
            supc = _box((whj > 0.004) | (wlj > 0.004), 1) > 1e-3
            cy, cx = np.nonzero(supc)
            if not len(cy):
                continue
            iy = (cy[:, None, None] * up + ar[:, None] + 0 * ar[None, :]).reshape(-1)
            ix = (cx[:, None, None] * up + 0 * ar[:, None] + ar[None, :]).reshape(-1)
            h, lw = _lookup(np.stack([whj, wlj], -1), iy, ix, up).T
            keep_ = (h > 0.002) | (lw > 0.002)
            iy, ix, h, lw = iy[keep_], ix[keep_], h[keep_], lw[keep_]
            if not len(iy):
                continue
            sup = iy * N + ix
            used.add(vi)
            c = views[vi].sample(*views[vi].project(Xf[sup])) * gain[vi]
            # This frame's low band: a normalized box blur of its colours at N/q.
            cell = (iy // q) * L + ix // q
            cnt = np.bincount(cell, minlength=L * L).astype(np.float32).reshape(L, L)
            sm = np.stack([np.bincount(cell, c[:, ch], L * L) for ch in range(3)], -1).astype(np.float32).reshape(L, L, 3)
            low = _box(_box(sm, 2), 2) / np.maximum(_box(_box(cnt, 2), 2), 1e-6)[..., None]
            lo = _lookup(low, iy, ix, q)
            acc_l[sup] += lw[:, None] * lo
            acc_h[sup] += h[:, None] * (c - lo)
            sum_l[sup] += lw
            sum_h[sup] += h
        img = acc_l / np.maximum(sum_l, 1e-9)[:, None] + acc_h / np.maximum(sum_h, 1e-9)[:, None]
        sn = st["seen"]
        sn = (np.repeat(np.repeat(sn, up, 0), up, 1) if up > 1 else sn).reshape(-1) & (sum_l > 0) & (sum_h > 0)
        out.update(img=np.where(sn[:, None], img, 0).reshape(N, N, 3), seen=sn.reshape(N, N), used=used)
        if stats is not None:
            wh = st["wh"]
            lab1 = wh.argmax(-1)
            w2m = wh.copy()
            np.put_along_axis(w2m, lab1[..., None], -1, -1)
            lab2 = w2m.argmax(-1)
            w2 = np.take_along_axis(wh, lab2[..., None], -1)[..., 0].reshape(-1)
            labN = np.repeat(np.repeat(lab1, up, 0), up, 1) if up > 1 else lab1
            flat = cube.faces[s]["flat"]
            flat = _resize(flat.astype(np.float32), N) > 0.999
            out["seam"] = _seam_stats(out["img"], out["seen"], labN, flat)
            two = (w2 >= 0.2) & st["seen"].reshape(-1)
            X = cube.full(s, Nc)[1]
            ii = np.arange(Nc * Nc)
            nbr = (ii, np.where(ii % Nc < Nc - 1, ii + 1, ii - 1), np.where(ii < Nc * (Nc - 1), ii + Nc, ii - Nc))
            cols = []
            for lab in (lab1.reshape(-1), lab2.reshape(-1)):
                ct = np.zeros((3, Nc * Nc, 3), np.float32)
                for j, vi in enumerate(st["pick"]):
                    m = np.nonzero(two & (lab == j))[0]
                    for t, nb in enumerate(nbr):
                        if len(m):
                            ct[t, m] = views[vi].sample(*views[vi].project(X[nb[m]])) * gain[vi]
                cols.append(ct)
            # A ghost is a doubled edge: the two blended frames disagree on the local gradient (an
            # exposure difference alone barely changes it).
            g1 = cols[0][1:] - cols[0][:1]
            g2 = cols[1][1:] - cols[1][:1]
            diff = np.abs(g1 - g2).mean(2).max(0)
            out["ghost"] = (int((two & (diff > 20)).sum()), int(two.sum()), int(st["seen"].sum()))
        return out

    with ThreadPoolExecutor(workers) as ex:
        res = dict(zip(SLOTS, ex.map(pass2, SLOTS)))
    faces = {s: r["img"] for s, r in res.items()}
    seen = {s: r["seen"] for s, r in res.items()}
    classes = {s: r["cls"] for s, r in res.items()}
    used = set().union(*(r["used"] for r in res.values()))
    if stats is not None:
        seam = np.sum([r.get("seam", (0, 0, 0, 0)) for r in res.values()], 0)
        gh = np.sum([r.get("ghost", (0, 0, 0)) for r in res.values()], 0)
        stats.update(seam_energy=float(seam[0] / max(seam[1], 1)), grad_energy=float(seam[2] / max(seam[3], 1)),
                     ghost_px=int(gh[0]), blend_px=int(gh[1]), seen_px=int(gh[2]), choice_px=Nc,
                     risk=float(np.mean([st["risk"].mean() for st in state.values()])),
                     node_gain=[round(float(np.exp(np.abs(np.log(gn)).max())), 3) for gn in gain.values()])
    return faces, seen, classes, used


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
    nodes, cubes, qual, total_bytes = [], [], [], 0
    for ni, nd in enumerate(picked):
        nid = f"N{ni + 1}"
        o = np.asarray(nd["position"], float)
        cube = DepthCube(o, P, F, room, depth_px)
        st: dict = {}
        faces, seen, classes, used = render_node(o, cube, views, face_px, stats=st)
        cov = float(np.mean([seen[s].mean() for s in SLOTS]))
        smooth = fill_holes(faces, {s: seen[s].astype(np.float32) for s in SLOTS})
        filled = {s: fill_texture(faces[s], seen[s], classes[s], smooth[s]) for s in SLOTS}
        qual.append(dict(id=nid, seam_ratio=round(st["seam_energy"] / max(st["grad_energy"], 1e-6), 2),
                         ghost_risk=round(st["ghost_px"] / max(st["seen_px"], 1), 4),
                         blended=round(st["blend_px"] / max(st["seen_px"], 1), 4),
                         depth_risk=round(st["risk"], 3)))
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
                   from_stops=sum(1 for n in picked if n["stop"] is not None), quality=qual)
    return nodes, summary

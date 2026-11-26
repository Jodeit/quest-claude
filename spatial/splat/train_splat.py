"""Train a Gaussian splat of a room from a RoomScan splat set (the app's More -> Share for splat
training), on one CUDA GPU: a free Kaggle or Colab T4 does a room in minutes.

    python train_splat.py Room-splat.zip --steps 7000 --out room.ply

The set is nerfstudio's transforms.json layout: camera-to-world poses as rows, camera looking down
-z with y up (ARKit's convention), per-frame intrinsics, and points.ply to start from. The poses
come from ARKit, so there's no structure-from-motion step. The output is the standard 3D Gaussian
Splatting .ply (the original paper's layout: x y z, normals, f_dc, f_rest, opacity as a logit,
log scales, rotation as w x y z), which splat viewers read; its world is RoomPlan's (metres, y up).

Only train() needs torch, gsplat and a GPU; loading, conversions and writing are plain numpy, so
they're tested on CPU (spatial/tests/test_splat.py).
"""

from __future__ import annotations

import argparse
import json
import math
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SH_C0 = 0.28209479177387814

# Flips ARKit/nerfstudio camera axes (x right, y up, looking down -z) to the OpenCV ones gsplat
# rasterizes with (x right, y down, looking down +z).
GL_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])


@dataclass
class Frame:
    path: Path
    c2w: np.ndarray  # 4x4, OpenCV axes
    K: np.ndarray  # 3x3, at the image's size as loaded
    width: int
    height: int


@dataclass
class Dataset:
    frames: list[Frame]
    points: np.ndarray  # (N, 3) float32
    colours: np.ndarray  # (N, 3) float32, 0..1
    info: dict


def open_set(path: str | Path) -> Path:
    """The folder holding transforms.json: the path itself, a folder under it, or a .zip unpacked."""
    p = Path(path)
    if p.suffix == ".zip":
        out = Path(tempfile.mkdtemp(prefix="splat-"))
        with zipfile.ZipFile(p) as z:
            z.extractall(out)
        p = out
    if (p / "transforms.json").exists():
        return p
    found = sorted(p.rglob("transforms.json"))
    if not found:
        raise FileNotFoundError(f"no transforms.json in {path}")
    return found[0].parent


def read_ply(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Points and colours (0..1) from a binary little-endian PLY of float x, y, z and uchar
    red, green, blue (what the app writes), or an ASCII one with the same properties."""
    data = path.read_bytes()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:end].decode("ascii").splitlines()
    n = next(int(line.split()[2]) for line in header if line.startswith("element vertex"))
    props = [(line.split()[1], line.split()[2]) for line in header if line.startswith("property")]
    names = [name for _, name in props]
    types = {"float": "<f4", "float32": "<f4", "double": "<f8", "uchar": "u1", "uint8": "u1"}
    if "format ascii" in header[1]:
        table = np.loadtxt(data[end:].decode("ascii").splitlines()[:n], ndmin=2)
        cols = {name: table[:, i] for i, name in enumerate(names)}
    else:
        dt = np.dtype([(name, types[t]) for t, name in props])
        rows = np.frombuffer(data, dtype=dt, count=n, offset=end)
        cols = {name: rows[name] for name in names}
    xyz = np.stack([cols["x"], cols["y"], cols["z"]], 1).astype(np.float32)
    if "red" in cols:
        rgb = np.stack([cols["red"], cols["green"], cols["blue"]], 1).astype(np.float32) / 255
    else:
        rgb = np.full_like(xyz, 0.5)
    return xyz, rgb


def load(path: str | Path, max_side: int = 1440) -> Dataset:
    """Frames scaled so no image side exceeds max_side (intrinsics scaled to match)."""
    root = open_set(path)
    t = json.loads((root / "transforms.json").read_text())
    frames = []
    for f in t["frames"]:
        w, h = int(f.get("w", t.get("w", 0))), int(f.get("h", t.get("h", 0)))
        s = min(1.0, max_side / max(w, h)) if w and h else 1.0
        fx, fy = float(f.get("fl_x", t.get("fl_x"))), float(f.get("fl_y", t.get("fl_y")))
        cx, cy = float(f.get("cx", t.get("cx"))), float(f.get("cy", t.get("cy")))
        K = np.array([[fx * s, 0, cx * s], [0, fy * s, cy * s], [0, 0, 1]], dtype=np.float32)
        c2w = np.asarray(f["transform_matrix"], dtype=np.float64) @ GL_TO_CV
        frames.append(Frame(root / f["file_path"], c2w.astype(np.float32), K, round(w * s), round(h * s)))
    if not frames:
        raise ValueError("the set has no frames")
    if t.get("ply_file_path") and (root / t["ply_file_path"]).exists():
        points, colours = read_ply(root / t["ply_file_path"])
    else:
        points = random_points(frames)
        colours = np.full_like(points, 0.5)
    return Dataset(frames, points, colours, t.get("roomscan", {}))


def random_points(frames: list[Frame], n: int = 50_000, seed: int = 0) -> np.ndarray:
    """No starting points: scatter them through the cameras' box, grown by a metre."""
    centres = np.stack([f.c2w[:3, 3] for f in frames])
    lo, hi = centres.min(0) - 1, centres.max(0) + 1
    return np.random.default_rng(seed).uniform(lo, hi, (n, 3)).astype(np.float32)


def scene_scale(frames: list[Frame]) -> float:
    """How far the cameras spread from their middle (gsplat's measure, times 1.1)."""
    centres = np.stack([f.c2w[:3, 3] for f in frames])
    return float(np.linalg.norm(centres - centres.mean(0), axis=1).max() * 1.1) or 1.0


def neighbour_scale(points: np.ndarray, k: int = 3) -> np.ndarray:
    """Mean distance to each point's k nearest others: a splat's starting size."""
    from scipy.spatial import cKDTree

    d, _ = cKDTree(points).query(points, k=k + 1)
    return np.clip(d[:, 1:].mean(1), 1e-4, None).astype(np.float32)


def write_splat_ply(path: Path, means, scales_log, quats_wxyz, opacity_logit, sh0, shN) -> None:
    """The 3D Gaussian Splatting .ply. sh0 is (N, 1, 3), shN (N, K, 3); f_rest is written channel by
    channel, as the original code stores it."""
    means = np.asarray(means, np.float32)
    n = len(means)
    f_dc = np.asarray(sh0, np.float32).reshape(n, 3)
    shN = np.asarray(shN, np.float32).reshape(n, -1, 3)
    f_rest = shN.transpose(0, 2, 1).reshape(n, -1)
    cols = [means, np.zeros((n, 3), np.float32), f_dc, f_rest,
            np.asarray(opacity_logit, np.float32).reshape(n, 1),
            np.asarray(scales_log, np.float32).reshape(n, 3), np.asarray(quats_wxyz, np.float32).reshape(n, 4)]
    names = (["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
             + [f"f_rest_{i}" for i in range(f_rest.shape[1])] + ["opacity", "scale_0", "scale_1", "scale_2"]
             + ["rot_0", "rot_1", "rot_2", "rot_3"])
    table = np.concatenate(cols, 1).astype("<f4")
    header = "ply\nformat binary_little_endian 1.0\n" + f"element vertex {n}\n"
    header += "".join(f"property float {name}\n" for name in names) + "end_header\n"
    with open(path, "wb") as fh:
        fh.write(header.encode("ascii"))
        fh.write(table.tobytes())


def _ssim(a, b):
    """SSIM over an 11-pixel Gaussian window; a, b are (1, 3, H, W) in 0..1."""
    import torch
    import torch.nn.functional as F

    g = torch.exp(-((torch.arange(11, device=a.device) - 5.0) ** 2) / (2 * 1.5**2))
    g = g / g.sum()
    win = (g[:, None] * g[None, :]).expand(3, 1, 11, 11).contiguous()

    def blur(x):
        return F.conv2d(x, win, padding=5, groups=3)

    mu_a, mu_b = blur(a), blur(b)
    var_a, var_b, cov = blur(a * a) - mu_a**2, blur(b * b) - mu_b**2, blur(a * b) - mu_a * mu_b
    c1, c2 = 0.01**2, 0.03**2
    return (((2 * mu_a * mu_b + c1) * (2 * cov + c2)) / ((mu_a**2 + mu_b**2 + c1) * (var_a + var_b + c2))).mean()


def train(data: Dataset, steps: int = 7000, sh_degree: int = 3, out: Path = Path("splat.ply"), log_every: int = 500) -> Path:
    import torch
    from gsplat import DefaultStrategy, rasterization
    from PIL import Image

    dev = "cuda"
    torch.manual_seed(0)
    # Images stay on the CPU as bytes (a few hundred frames of floats would fill a T4) and go up
    # one at a time.
    images = []
    for f in data.frames:
        im = Image.open(f.path).convert("RGB")
        if im.size != (f.width, f.height):
            im = im.resize((f.width, f.height), Image.LANCZOS)
        images.append(torch.from_numpy(np.asarray(im).copy()))
    viewmats = torch.from_numpy(np.stack([np.linalg.inv(f.c2w) for f in data.frames])).float().to(dev)
    Ks = torch.from_numpy(np.stack([f.K for f in data.frames])).float().to(dev)
    scale = scene_scale(data.frames)

    pts = torch.from_numpy(data.points).float()
    n = len(pts)
    dist = torch.from_numpy(neighbour_scale(data.points))
    k_rest = (sh_degree + 1) ** 2 - 1
    params = torch.nn.ParameterDict({
        "means": torch.nn.Parameter(pts),
        "scales": torch.nn.Parameter(torch.log(dist)[:, None].repeat(1, 3)),
        "quats": torch.nn.Parameter(torch.tensor([1.0, 0, 0, 0]).repeat(n, 1)),
        "opacities": torch.nn.Parameter(torch.logit(torch.full((n,), 0.1))),
        "sh0": torch.nn.Parameter(((torch.from_numpy(data.colours).float() - 0.5) / SH_C0)[:, None, :]),
        "shN": torch.nn.Parameter(torch.zeros(n, k_rest, 3)),
    }).to(dev)
    lrs = {"means": 1.6e-4 * scale, "scales": 5e-3, "quats": 1e-3, "opacities": 5e-2, "sh0": 2.5e-3, "shN": 2.5e-3 / 20}
    optimizers = {k: torch.optim.Adam([{"params": params[k], "lr": lr, "name": k}], eps=1e-15) for k, lr in lrs.items()}
    # The means' rate falls a hundredfold over the run, as in the original method.
    means_decay = torch.optim.lr_scheduler.ExponentialLR(optimizers["means"], gamma=0.01 ** (1 / steps))

    # Splitting and pruning for most of the run, then settle (scaled from the 30k-step schedule).
    strategy = DefaultStrategy(refine_start_iter=500, refine_stop_iter=int(steps * 0.7), reset_every=3000,
                               refine_every=100, verbose=False)
    strategy.check_sanity(params, optimizers)
    state = strategy.initialize_state(scene_scale=scale)

    order = np.random.default_rng(0).permutation(len(data.frames))
    start = time.time()
    for step in range(steps):
        i = int(order[step % len(order)])
        if step % len(order) == len(order) - 1:
            order = np.random.default_rng(step).permutation(len(data.frames))
        f = data.frames[i]
        gt = images[i].to(dev, non_blocking=True).float() / 255
        degree = min(sh_degree, step // 1000)  # one more band of view-dependent colour every 1000 steps
        colors = torch.cat([params["sh0"], params["shN"]], 1)
        render, _, info = rasterization(
            means=params["means"], quats=params["quats"], scales=torch.exp(params["scales"]),
            opacities=torch.sigmoid(params["opacities"]), colors=colors,
            viewmats=viewmats[i:i + 1], Ks=Ks[i:i + 1], width=f.width, height=f.height,
            sh_degree=degree, near_plane=0.05, far_plane=50.0, packed=False)
        img = render[0].clamp(0, 1)
        l1 = (img - gt).abs().mean()
        ssim = _ssim(img.permute(2, 0, 1)[None], gt.permute(2, 0, 1)[None])
        loss = 0.8 * l1 + 0.2 * (1 - ssim)
        strategy.step_pre_backward(params, optimizers, state, step, info)
        loss.backward()
        for opt in optimizers.values():
            opt.step()
            opt.zero_grad(set_to_none=True)
        means_decay.step()
        strategy.step_post_backward(params, optimizers, state, step, info, packed=False)
        if log_every and (step % log_every == 0 or step == steps - 1):
            psnr = -10 * math.log10(max(float(((img - gt) ** 2).mean()), 1e-10))
            print(f"step {step:5d}/{steps}  loss {float(loss):.4f}  psnr {psnr:5.2f}  "
                  f"splats {len(params['means']):,}  {time.time() - start:5.0f}s", flush=True)

    with torch.no_grad():
        write_splat_ply(Path(out), params["means"].cpu().numpy(), params["scales"].cpu().numpy(),
                        params["quats"].cpu().numpy(), params["opacities"].cpu().numpy(),
                        params["sh0"].cpu().numpy(), params["shN"].cpu().numpy())
    print(f"wrote {out}: {len(params['means']):,} splats, {Path(out).stat().st_size / 1e6:.0f} MB", flush=True)
    return Path(out)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("set", help="the app's splat .zip, or its unpacked folder")
    ap.add_argument("--steps", type=int, default=7000, help="7000 is a quick look; 15000-30000 for the best")
    ap.add_argument("--max-side", type=int, default=1440, help="downscale frames to this many pixels at most")
    ap.add_argument("--sh-degree", type=int, default=3)
    ap.add_argument("--out", default="splat.ply")
    a = ap.parse_args(argv)
    data = load(a.set, a.max_side)
    print(f"{len(data.frames)} frames, {len(data.points):,} starting points, scene scale {scene_scale(data.frames):.2f} m",
          flush=True)
    train(data, a.steps, a.sh_degree, Path(a.out))


if __name__ == "__main__":
    main()

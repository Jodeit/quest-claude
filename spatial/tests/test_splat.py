"""The splat trainer's CPU side: reading the app's splat set, the camera conversion gsplat needs,
and the .ply it writes. Training itself needs CUDA and runs in the notebook."""

import json
import struct
import sys
import zipfile
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "splat"))
import make_notebook  # noqa: E402
import train_splat as ts  # noqa: E402


def app_ply(path: Path, pts, rgb):
    """What SplatExport.writePLY writes."""
    head = (f"ply\nformat binary_little_endian 1.0\nelement vertex {len(pts)}\n"
            "property float x\nproperty float y\nproperty float z\n"
            "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").encode()
    body = b"".join(struct.pack("<fffBBB", *p, *c) for p, c in zip(pts, rgb))
    path.write_bytes(head + body)


def make_set(tmp_path: Path, with_points=True) -> Path:
    from PIL import Image

    d = tmp_path / "set"
    (d / "images").mkdir(parents=True)
    frames = []
    for i, (file, w, h) in enumerate([("F001.jpg", 960, 720), ("M001.jpg", 1920, 1440)]):
        Image.new("RGB", (w, h), (200, 100, 50)).save(d / "images" / file)
        pose = np.eye(4)
        pose[:3, 3] = [i * 0.5, 1.4, 0]
        s = w / 1920
        frames.append({"file_path": f"images/{file}", "transform_matrix": pose.tolist(), "fl_x": 1400 * s, "fl_y": 1400 * s,
                       "cx": 960 * s, "cy": 720 * s, "w": w, "h": h, "pass": "room"})
    t = {"camera_model": "OPENCV", "frames": frames, "roomscan": {"name": "Den", "floor_y": 0}}
    if with_points:
        app_ply(d / "points.ply", [(0, 1, -2), (1, 0, -3), (0.5, 2, -2.5)], [(255, 0, 0), (0, 255, 0), (0, 0, 255)])
        t["ply_file_path"] = "points.ply"
    (d / "transforms.json").write_text(json.dumps(t))
    return d


def test_loads_the_apps_set_from_a_zip(tmp_path):
    d = make_set(tmp_path)
    z = tmp_path / "Den-splat.zip"
    with zipfile.ZipFile(z, "w") as zf:  # iOS zips the folder itself, so files sit under set/
        for p in d.rglob("*"):
            zf.write(p, p.relative_to(tmp_path))
    data = ts.load(z, max_side=1440)
    assert len(data.frames) == 2 and data.info["name"] == "Den"
    np.testing.assert_allclose(data.points[0], [0, 1, -2])
    np.testing.assert_allclose(data.colours[0], [1, 0, 0])
    big = data.frames[1]
    assert (big.width, big.height) == (1440, 1080)  # 1920 scaled down, intrinsics with it
    np.testing.assert_allclose(big.K[0, 0], 1400 * 0.75)
    np.testing.assert_allclose(big.K[:2, 2], [720, 540])


def test_camera_axes_match_the_apps_projection(tmp_path):
    """A point ahead of and above an ARKit camera lands ahead (+z) and above centre (smaller y) in
    the OpenCV camera gsplat uses: the app's own projection is x = cx + fx X/d, y = cy - fy Y/d."""
    f = ts.load(make_set(tmp_path)).frames[0]
    view = np.linalg.inv(f.c2w)
    p = view @ np.array([0.0, 1.4 + 0.5, -2.0, 1])  # 2 m ahead, 0.5 m above the camera
    assert p[2] == pytest.approx(2.0)
    u, v = (f.K @ (p[:3] / p[2]))[:2]
    assert u == pytest.approx(f.K[0, 2])
    assert v == pytest.approx(f.K[1, 2] - f.K[1, 1] * 0.5 / 2)


def test_no_points_scatters_some_round_the_cameras(tmp_path):
    data = ts.load(make_set(tmp_path, with_points=False))
    assert data.points.shape == (50_000, 3) and np.all(data.colours == 0.5)
    assert ts.scene_scale(data.frames) == pytest.approx(0.25 * 1.1)


def test_splat_ply_layout(tmp_path):
    n, k = 4, 15
    out = tmp_path / "s.ply"
    shN = np.arange(n * k * 3, dtype=np.float32).reshape(n, k, 3)
    ts.write_splat_ply(out, np.ones((n, 3)), np.zeros((n, 3)), np.tile([1, 0, 0, 0], (n, 1)), np.zeros(n),
                       np.zeros((n, 1, 3)), shN)
    data = out.read_bytes()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    names = [line.split()[2] for line in data[:end].decode().splitlines() if line.startswith("property")]
    assert names[:9] == ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
    assert len(names) == 9 + 45 + 1 + 3 + 4 and names[-4:] == ["rot_0", "rot_1", "rot_2", "rot_3"]
    rows = np.frombuffer(data[end:], "<f4").reshape(n, len(names))
    # f_rest channel by channel: all red coefficients, then green, then blue.
    rest = rows[0, 9:54]
    np.testing.assert_array_equal(rest[:15], shN[0, :, 0])
    np.testing.assert_array_equal(rest[15:30], shN[0, :, 1])


def test_neighbour_scale():
    pytest.importorskip("scipy")
    pts = np.array([[0, 0, 0], [0.1, 0, 0], [0, 0.1, 0], [0, 0, 0.1], [5, 5, 5]], np.float32)
    assert ts.neighbour_scale(pts)[0] == pytest.approx(0.1)


def test_notebook_carries_the_current_trainer():
    path = Path(make_notebook.__file__).parent / "RoomScan_splat.ipynb"
    assert path.read_text() == make_notebook.text(), "run python spatial/splat/make_notebook.py"

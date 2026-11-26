"""Writes RoomScan_splat.ipynb with train_splat.py inside it, so the notebook needs nothing from
this repo (it may be private) and runs as uploaded to Kaggle or opened in Colab.

    python spatial/splat/make_notebook.py

Run it after changing train_splat.py; a test fails while they differ.
"""

import json
from pathlib import Path

HERE = Path(__file__).parent


def cell(kind: str, text: str) -> dict:
    c = {"cell_type": kind, "metadata": {}, "source": text.strip("\n").splitlines(keepends=True)}
    if kind == "code":
        c.update(execution_count=None, outputs=[])
    return c


def notebook() -> dict:
    script = (HERE / "train_splat.py").read_text()
    cells = [
        cell("markdown", """
# RoomScan: train a Gaussian splat of a room

Free GPU, about 10-20 minutes for a room on a T4.

1. On the phone: a scan's **More → Share for splat training (.zip)**, saved to Files.
2. **Colab:** Runtime → Change runtime type → **T4 GPU**, then Runtime → Run all. The upload
   cell asks for the zip; the last cell downloads `<room>.ply`.
   **Kaggle:** Settings → Accelerator → **GPU T4**, Internet **on**; add the zip as a dataset
   (Add input → Upload, keep it private); Run all. The .ply lands in Output.
3. Open the .ply in a splat viewer (for example superspl.at/editor, or the twin page once it shows
   splats). Its world is RoomPlan's: metres, y up.

`STEPS = 7000` is a quick look; 15000-30000 is sharper and takes proportionally longer.
"""),
        cell("code", """
STEPS = 7000
MAX_SIDE = 1440  # downscale frames to at most this many pixels
"""),
        cell("code", """
# gsplat builds its CUDA kernels the first time it runs (a few minutes).
!nvidia-smi --query-gpu=name,memory.total --format=csv
!pip -q install "gsplat>=1.4,<2" ninja scipy pillow
"""),
        cell("code", "%%writefile train_splat.py\n" + script),
        cell("code", """
import glob, os
try:
    from google.colab import files  # Colab: ask for the zip
    uploaded = files.upload()
    SET = next(name for name in uploaded if name.endswith(".zip"))
except ImportError:  # Kaggle: the zip, or its unpacked folder, under /kaggle/input
    found = glob.glob("/kaggle/input/**/*.zip", recursive=True) or [
        os.path.dirname(p) for p in glob.glob("/kaggle/input/**/transforms.json", recursive=True)]
    assert found, "Add the splat zip as an input dataset"
    SET = found[0]
print("training", SET)
"""),
        cell("code", """
import importlib, json, os
import train_splat
importlib.reload(train_splat)
data = train_splat.load(SET, MAX_SIDE)
name = (data.info.get("name") or "room").replace("/", "-")
out = ("/kaggle/working/" if os.path.isdir("/kaggle/working") else "") + f"{name}.ply"
print(f"{len(data.frames)} frames, {len(data.points):,} starting points")
train_splat.train(data, steps=STEPS, out=out)
"""),
        cell("code", """
try:
    from google.colab import files
    files.download(out)
except ImportError:
    print("Saved to", out, "- it's in this notebook's Output")
"""),
    ]
    return {"cells": cells, "metadata": {"accelerator": "GPU", "kernelspec": {"name": "python3", "display_name": "Python 3"},
                                         "language_info": {"name": "python"}},
            "nbformat": 4, "nbformat_minor": 5}


def text() -> str:
    return json.dumps(notebook(), indent=1, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    (HERE / "RoomScan_splat.ipynb").write_text(text())
    print("wrote", HERE / "RoomScan_splat.ipynb")

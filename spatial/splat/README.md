# Splats from a RoomScan

A Gaussian splat of a room, trained on a free cloud GPU from the frames the phone already keeps.
Splats show depth that RoomPlan's flat walls and the textured mesh smear (cabinet fronts,
furniture, the floor the 360 views make up).

1. **On the phone:** a scan's **More → Share for splat training (.zip)**, saved to Files. The more
   frames the better: do a photo-real pass first (stops with a full turn, close to shelves).
2. **Train:** open [`RoomScan_splat.ipynb`](RoomScan_splat.ipynb) in **Colab** (File → Upload
   notebook; Runtime → T4 GPU; Run all; it asks for the zip and downloads the `.ply`) or **Kaggle**
   (New notebook → File → Import; Accelerator GPU T4, Internet on; add the zip as a private
   dataset; Run all; the `.ply` is in Output). Both work from the phone's browser. The first run
   spends a few minutes building gsplat's CUDA kernels.
3. **View:** any 3D Gaussian Splatting viewer reads the `.ply` (superspl.at/editor in a browser).
   Its world is RoomPlan's (metres, y up), the same as the twin, so it can be laid over the room.

`train_splat.py` is the trainer (gsplat, the default densify-and-prune schedule shortened to the
run, L1 + SSIM, view-dependent colour added a band every 1000 steps). It runs anywhere with a CUDA
GPU: `python train_splat.py Room-splat.zip --steps 15000 --out room.ply`. The notebook carries a
copy of it, so it needs nothing from this repo; after changing the script, run
`python spatial/splat/make_notebook.py` (a test fails until you do).

Colab's and Kaggle's free tiers are Google's: the frames (photos of the room) go to them. Kaggle
datasets can be kept private; delete them after training if the room is a client's.

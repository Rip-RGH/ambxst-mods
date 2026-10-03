#!/usr/bin/env python3
"""Wallpaper Depth: build an RGBA foreground cutout of a wallpaper.

usage: depth.py <wallpaper> <out.png> <threshold 0-100> <feather px>

The depth map is cached per wallpaper, so changing threshold/feather only
redoes the cheap mask step. The cutout is written atomically.
"""
import hashlib
import os
import sys

wall, out = sys.argv[1], sys.argv[2]
threshold, feather = int(sys.argv[3]), float(sys.argv[4])

# Fast path before the heavy imports: the cutout already exists.
if os.path.exists(out):
    sys.exit(0)

import numpy as np
from PIL import Image, ImageFilter

DATA = os.path.expanduser("~/.local/share/ambxst/depth")
CACHE = os.path.expanduser("~/.cache/ambxst/depth")
MODEL = os.path.join(DATA, "model.onnx")
os.makedirs(CACHE, exist_ok=True)

key = hashlib.md5(wall.encode()).hexdigest()
dmap_path = os.path.join(CACHE, key + ".npy")

img = Image.open(wall).convert("RGB")

if os.path.exists(dmap_path):
    depth = np.load(dmap_path)
else:
    if not os.path.exists(MODEL):
        sys.stderr.write(f"depth model missing: {MODEL} (see README)\n")
        sys.exit(2)
    import onnxruntime as ort

    sess = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    x = np.asarray(img.resize((518, 518), Image.BICUBIC), np.float32) / 255.0
    x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array(
        [0.229, 0.224, 0.225], np.float32
    )
    x = x.transpose(2, 0, 1)[None].astype(np.float32)
    depth = np.squeeze(sess.run(None, {inp.name: x})[0])
    depth = (depth - depth.min()) / max(float(depth.max() - depth.min()), 1e-6)
    np.save(dmap_path, depth.astype(np.float32))  # relative depth, 1 = closest

mask = Image.fromarray(((depth * 100.0 > threshold) * 255).astype(np.uint8))
mask = mask.resize(img.size, Image.BILINEAR)
if feather > 0:
    mask = mask.filter(ImageFilter.GaussianBlur(feather))
img.putalpha(mask)

os.makedirs(os.path.dirname(out), exist_ok=True)
tmp = f"{out}.{os.getpid()}.tmp"
img.save(tmp, format="PNG")
os.replace(tmp, out)

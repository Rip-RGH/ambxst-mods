#!/usr/bin/env python3
"""Wallpaper Depth: build an RGBA foreground cutout of a wallpaper, and measure
how bright the wallpaper is behind the clock so the QML can pick text colour.

usage: depth.py <wallpaper> <out.png> <threshold 0-100> <feather px> <clock size %>

Prints one number on stdout: relative luminance (0 = black, 1 = white) of the
visible background behind the clock.

The depth map is cached per wallpaper, so changing threshold/feather only
redoes the cheap mask step. Outputs are written atomically.
"""
import hashlib
import os
import sys

wall, out = sys.argv[1], sys.argv[2]
threshold, feather, clock = int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])

lum_path = os.path.splitext(out)[0] + f"-c{clock}.lum"


def write_atomic(path, data, binary=False):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "wb" if binary else "w") as f:
        f.write(data)
    os.replace(tmp, path)


# Fast path before the heavy imports: everything is already cached.
if os.path.exists(out) and os.path.exists(lum_path):
    print(open(lum_path).read().strip())
    sys.exit(0)

import numpy as np
from PIL import Image, ImageFilter

DATA = os.path.expanduser("~/.local/share/ambxst/depth")
CACHE = os.path.expanduser("~/.cache/ambxst/depth")
MODEL = os.path.join(DATA, "model.onnx")
os.makedirs(CACHE, exist_ok=True)

img = Image.open(wall).convert("RGB")


def clock_luminance(img, alpha, clock):
    """Median linear luminance of the background pixels behind the clock."""
    W, H = img.size
    hy = max(clock * 0.6 / 100, 0.02)                      # half text height
    hx = min(max(clock * 1.4 / 100 * H / W, 0.04), 0.45)   # half text width
    box = (int(W * (0.5 - hx)), int(H * (0.5 - hy)), int(W * (0.5 + hx)), int(H * (0.5 + hy)))
    rgb = img.crop(box)
    a = alpha.crop(box)
    rgb.thumbnail((96, 96))
    a = a.resize(rgb.size)
    c = np.asarray(rgb, np.float32) / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    bg = np.asarray(a) < 128            # pixels NOT covered by the foreground cutout
    if bg.mean() >= 0.10:
        lum = lum[bg]
    return float(np.median(lum))


if os.path.exists(out):
    # Cutout cached from an earlier run; only the luminance is missing.
    alpha = Image.open(out).getchannel("A")
    if alpha.size != img.size:
        alpha = alpha.resize(img.size)
else:
    key = hashlib.md5(wall.encode()).hexdigest()
    dmap_path = os.path.join(CACHE, key + ".npy")

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

    alpha = Image.fromarray(((depth * 100.0 > threshold) * 255).astype(np.uint8))
    alpha = alpha.resize(img.size, Image.BILINEAR)
    if feather > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(feather))

    cut = img.copy()
    cut.putalpha(alpha)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = f"{out}.{os.getpid()}.tmp"
    cut.save(tmp, format="PNG")
    os.replace(tmp, out)

L = clock_luminance(img, alpha, clock)
write_atomic(lum_path, f"{L:.4f}\n")
print(f"{L:.4f}")

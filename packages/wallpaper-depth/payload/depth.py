#!/usr/bin/env python3
"""Wallpaper Depth: build an RGBA foreground cutout of a wallpaper, and measure
how bright the wallpaper is behind the clock so the QML can pick text colour.

usage: depth.py <wallpaper> <out.png> <threshold 0-100> <feather px> <clock x %> <clock y %> <clock w %> <clock h %> [depth|flat]

(clock x/y = centre of the clock, w/h = its size, all as whole percents of the screen)

Mode "flat" (depth effect switched off) skips the model and the cutout entirely
and only measures the brightness behind the clock, so no model is needed.

Prints one number on stdout: relative luminance (0 = black, 1 = white) of the
visible background behind the clock.

The depth map is cached per wallpaper, so changing threshold/feather only
redoes the cheap mask step. Outputs are written atomically.
"""
import hashlib
import os
import sys

wall, out = sys.argv[1], sys.argv[2]
threshold, feather = int(sys.argv[3]), float(sys.argv[4])
cxp, cyp, wp, hp = (int(a) for a in sys.argv[5:9])
cx, cy = cxp / 100.0, cyp / 100.0
flat = len(sys.argv) > 9 and sys.argv[9] == "flat"

if flat:
    # no cutout in this mode, so the cache name must not depend on threshold/feather
    lum_path = os.path.join(
        os.path.dirname(out),
        hashlib.md5(wall.encode()).hexdigest() + f"-flat-x{cxp}-y{cyp}-w{wp}-h{hp}.lum",
    )
else:
    lum_path = os.path.splitext(out)[0] + f"-x{cxp}-y{cyp}-w{wp}-h{hp}.lum"


def write_atomic(path, data, binary=False):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "wb" if binary else "w") as f:
        f.write(data)
    os.replace(tmp, path)


# Fast path before the heavy imports: everything is already cached.
if os.path.exists(lum_path) and (flat or os.path.exists(out)):
    print(open(lum_path).read().strip())
    sys.exit(0)

import numpy as np
from PIL import Image, ImageFilter

DATA = os.path.expanduser("~/.local/share/ambxst/depth")
CACHE = os.path.expanduser("~/.cache/ambxst/depth")
MODEL = os.path.join(DATA, "model.onnx")
os.makedirs(CACHE, exist_ok=True)

img = Image.open(wall).convert("RGB")


def clock_luminance(img, alpha, cx, cy, wp, hp):
    """Median linear luminance of the background pixels behind the clock."""
    W, H = img.size
    hx = min(max(wp / 200.0, 0.02), 0.5)    # half the clock's width, as a fraction of the screen
    hy = min(max(hp / 200.0, 0.02), 0.5)    # half its height
    x0, x1 = max(0.0, cx - hx), min(1.0, cx + hx)
    y0, y1 = max(0.0, cy - hy), min(1.0, cy + hy)
    box = (int(W * x0), int(H * y0), max(int(W * x1), int(W * x0) + 1), max(int(H * y1), int(H * y0) + 1))
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


if flat:
    # Depth effect off: nothing is hidden behind a cutout, so every pixel counts.
    os.makedirs(os.path.dirname(out), exist_ok=True)
    L = clock_luminance(img, Image.new("L", img.size, 0), cx, cy, wp, hp)
    write_atomic(lum_path, f"{L:.4f}\n")
    print(f"{L:.4f}")
    sys.exit(0)

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

L = clock_luminance(img, alpha, cx, cy, wp, hp)
write_atomic(lum_path, f"{L:.4f}\n")
print(f"{L:.4f}")

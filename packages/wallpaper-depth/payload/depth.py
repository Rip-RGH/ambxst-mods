#!/usr/bin/env python3
"""Wallpaper Depth: build an RGBA foreground cutout of a wallpaper, and measure
how bright the wallpaper is behind the clock so the QML can pick text colour.

usage: depth.py <wallpaper> <out.png> <threshold 0-100> <feather px> <clock x %> <clock y %> <clock w %> <clock h %> [depth|flat]

(clock x/y = centre of the clock, w/h = its size, all as whole percents of the screen)

Mode "flat" (depth effect switched off) skips the model and the cutout entirely
and only measures the brightness behind the clock, so no model is needed.

Prints one number on stdout: relative luminance (0 = black, 1 = white) of the
visible background behind the clock.

How the cutout is made: the model estimates depth; that depth map is refined
against the wallpaper's own edges (guided filter) so the cut follows real
outlines instead of the model's coarse, blocky edges; it is then cut at the
threshold with about one pixel of anti-aliasing, and finally feathered.

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


def model_size(inp, W, H):
    """Fixed-size models keep their size. Models with dynamic height/width get an
    aspect-preserving size (multiples of 14, long side 1036) instead of being
    squashed to a square, which gives much finer edges."""
    h, w = inp.shape[2], inp.shape[3]
    if isinstance(h, int) and isinstance(w, int):
        return w, h
    s = 1036.0 / max(W, H)
    return max(14, round(W * s / 14) * 14), max(14, round(H * s / 14) * 14)


def estimate_depth(img):
    import onnxruntime as ort

    sess = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    sizes = [model_size(inp, *img.size)]
    if sizes[0] != (518, 518):
        sizes.append((518, 518))        # if a model rejects other sizes, fall back to the classic one
    last = None
    for w, h in sizes:
        try:
            x = np.asarray(img.resize((w, h), Image.BICUBIC), np.float32) / 255.0
            x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array(
                [0.229, 0.224, 0.225], np.float32
            )
            x = x.transpose(2, 0, 1)[None].astype(np.float32)
            depth = np.squeeze(sess.run(None, {inp.name: x})[0])
            while depth.ndim > 2:
                depth = depth[0]
            depth = (depth - depth.min()) / max(float(depth.max() - depth.min()), 1e-6)
            return depth.astype(np.float32)     # relative depth, 1 = closest
        except Exception as e:                  # noqa: BLE001 - try the next size
            last = e
    raise last


def box_mean(x, r):
    """Mean over a (2r+1)x(2r+1) window with replicated edges, via cumulative sums."""
    p = np.pad(x, ((r + 1, r), (r + 1, r)), mode="edge").astype(np.float64)
    c = p.cumsum(0).cumsum(1)
    n = 2 * r + 1
    return ((c[n:, n:] - c[:-n, n:] - c[n:, :-n] + c[:-n, :-n]) / (n * n)).astype(np.float32)


def guided_filter(guide, src, r, eps):
    """Edge-aware smoothing of `src` that follows the edges of `guide` (He et al.)."""
    mg, ms = box_mean(guide, r), box_mean(src, r)
    cov = box_mean(guide * src, r) - mg * ms
    var = box_mean(guide * guide, r) - mg * mg
    a = cov / (var + eps)
    b = ms - a * mg
    return box_mean(a, r) * guide + box_mean(b, r)


def make_alpha(img, depth, threshold, feather):
    W, H = img.size
    s = min(1.0, 2048.0 / max(W, H))            # work at <= 2048 px so 4K wallpapers stay cheap
    ww, wh = max(1, round(W * s)), max(1, round(H * s))
    guide = np.asarray(img.convert("L").resize((ww, wh), Image.LANCZOS), np.float32) / 255.0
    d = np.asarray(Image.fromarray(depth).resize((ww, wh), Image.BICUBIC), np.float32)
    d = np.clip(d, 0.0, 1.0)
    r = max(3, round(8 * min(ww, wh) / 1080))
    df = guided_filter(guide, d, r, 1e-3)
    gy, gx = np.gradient(df)
    # signed distance, in work pixels, from the threshold contour (positive = foreground)
    sd = (df - threshold / 100.0) / np.maximum(np.hypot(gx, gy), 1e-5)
    # Pull the cut inward before feathering, so a soft edge fades out *inside* the
    # subject. Otherwise feathering spreads wallpaper pixels over the clock as a halo.
    sd -= 0.75 * feather * s
    a = np.clip(0.5 + sd / 2.4, 0.0, 1.0)       # ~1.2 px of anti-aliasing each side of the contour
    alpha = Image.fromarray((a * 255.0 + 0.5).astype(np.uint8))
    if (ww, wh) != (W, H):
        alpha = alpha.resize((W, H), Image.BICUBIC)
    if feather > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(feather))
    return alpha


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
    # "-v2": depth maps from before the aspect-preserving model input are not reused
    dmap_path = os.path.join(CACHE, key + "-v2.npy")

    if os.path.exists(dmap_path):
        depth = np.load(dmap_path)
    else:
        if not os.path.exists(MODEL):
            sys.stderr.write(f"depth model missing: {MODEL} (see README)\n")
            sys.exit(2)
        depth = estimate_depth(img)
        np.save(dmap_path, depth)

    alpha = make_alpha(img, depth, threshold, feather)

    cut = img.copy()
    cut.putalpha(alpha)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = f"{out}.{os.getpid()}.tmp"
    cut.save(tmp, format="PNG")
    os.replace(tmp, out)

L = clock_luminance(img, alpha, cx, cy, wp, hp)
write_atomic(lum_path, f"{L:.4f}\n")
print(f"{L:.4f}")
